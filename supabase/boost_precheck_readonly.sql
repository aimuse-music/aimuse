-- =====================================================================
-- AIMUSE 本番の読み取り専用チェック v4（BOOST の追加SQLを実行する前に使う）
--
-- ・SELECT 文1つだけです。データを読むだけで、何も変更しません
--   （INSERT・UPDATE・DELETE・CREATE・ALTER・GRANT などは含みません）
-- ・結果は通常の表で表示されます。1行目が「総合判定」、その下に NG の行が先に並びます
-- ・確認できなかった項目は、必ず NG と表示します
-- ・AIMUSE の is_admin() は、定義がAIMUSE構築SQLと一致した場合だけ呼び出します
--   （定義が違う関数は、中身が分からないため実行しません）
-- ・動作確認では、ログイン情報（request.jwt.*）を一時的に設定して is_admin() を呼びます。
--   この設定はこの文の取引の中だけで有効で、データベースには保存されません
-- =====================================================================

with
-- AIMUSE の構築SQLと同じ定義か（空白の違いだけ許容）。一致した場合だけ is_admin() を呼ぶ
def as (
  select
    to_regclass('public.profiles') is not null as has_profiles,
    (select count(*) from pg_roles where rolname in ('anon', 'authenticated')) = 2 as has_roles,
    (select btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) from pg_proc p where p.oid = to_regprocedure('public.is_admin()')) as body,
    coalesce((select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) = '065dbcd2c17f6a4da4ba7cc6b24dad9e'
                     and p.prosecdef and 'search_path=""' = any(p.proconfig)
                     and p.prorettype = 'boolean'::regtype
                     and (select l.lanname from pg_language l where l.oid = p.prolang) = 'sql'
              from pg_proc p where p.oid = to_regprocedure('public.is_admin()')), false) as is_admin_ok
),
-- 動作確認1：ログインしていない状態
act_anon as (
  select case when d.is_admin_ok and s.ready then public.is_admin() end as got
  from def d,
       lateral (select set_config('request.jwt.claims', '{"role":"anon"}', true) is not null
                   and set_config('request.jwt.claim.sub', '', true) is not null as ready
                offset 0) s
),
-- 動作確認2：存在しない会員
act_random as (
  select case when d.is_admin_ok and s.ready then public.is_admin() end as got
  from def d,
       lateral (select gen_random_uuid() as id offset 0) r,
       lateral (select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', r.id)::text, true) is not null
                   and set_config('request.jwt.claim.sub', r.id::text, true) is not null as ready
                offset 0) s
),
-- 動作確認3：登録済みの全会員（最大5000人）。is_admin() の結果が profiles.is_admin と同じか
act_all as (
  select count(*) as total,
         count(*) filter (where x.got is distinct from x.flag) as mismatch,
         string_agg(left(x.id::text, 8), ' ') filter (where x.got is distinct from x.flag) as bad
  from (
    select p.id, p.is_admin as flag,
           case when d.is_admin_ok and s.ready then public.is_admin() end as got
    from def d,
         lateral (select id, is_admin from public.profiles where d.has_profiles order by id limit 5000) p,
         lateral (select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', p.id)::text, true) is not null
                     and set_config('request.jwt.claim.sub', p.id::text, true) is not null as ready
                  offset 0) s
  ) x
),
checks(ord, 必須, 区分, 項目, 結果, 期待) as (
  select 1, true, '定義', 'is_admin() の本体・属性が AIMUSE 構築SQLと一致',
         case when d.is_admin_ok then '一致' when d.body is null then '関数なし' else '不一致' end, '一致'
  from def d
  union all
  select 2, true, '定義', '管理者フラグ保護関数の本体が構築SQLと一致',
         case when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) from pg_proc p
                    where p.oid = to_regprocedure('public.protect_profile_flags()')) = 'fa40e1325abb252e0ed071bcdc6a5106'
              then '一致' else '不一致または関数なし' end, '一致'
  union all
  select 3, true, '定義', '保護トリガー（更新前・行ごと・有効）',
         case when exists (select 1 from pg_trigger g where g.tgrelid = to_regclass('public.profiles') and not g.tgisinternal
                             and g.tgfoid = to_regproc('public.protect_profile_flags') and g.tgenabled <> 'D'
                             and (g.tgtype & 19) = 19) then '有効' else '無効または無し' end, '有効'
  union all
  select 4, true, '定義', 'profiles の RLS',
         coalesce((select case when c.relrowsecurity then '有効' else '無効' end from pg_class c where c.oid = to_regclass('public.profiles')),
                  'テーブルなし'), '有効'
  union all
  select 5, true, '権限', r.role || ' が profiles.is_admin を変更・追加できるか',
         case when not d.has_profiles then '確認できず（テーブルなし）'
              when r.role <> 'public' and not exists (select 1 from pg_roles where rolname = r.role) then '確認できず（ロールなし）'
              when has_column_privilege(r.role, 'public.profiles', 'is_admin', 'UPDATE')
                or has_column_privilege(r.role, 'public.profiles', 'is_admin', 'INSERT') then 'できる'
              else 'できない' end, 'できない'
  from def d, (values ('anon'), ('authenticated'), ('public')) r(role)
  union all
  select 6, true, '権限', '未ログイン・ログイン会員が is_admin() を実行できるか',
         case when not d.has_roles or to_regprocedure('public.is_admin()') is null then '確認できず'
              when has_function_privilege('anon', to_regprocedure('public.is_admin()'), 'EXECUTE')
               and has_function_privilege('authenticated', to_regprocedure('public.is_admin()'), 'EXECUTE') then 'できる'
              else 'できない' end, 'できる'
  from def d
  union all
  select 7, true, '動作', '未ログインで is_admin()',
         case when not d.is_admin_ok then '確認できず（定義不一致のため実行せず）' else coalesce(a.got::text, 'null') end, 'false'
  from def d, act_anon a
  union all
  select 8, true, '動作', '存在しない会員で is_admin()',
         case when not d.is_admin_ok then '確認できず（定義不一致のため実行せず）' else coalesce(a.got::text, 'null') end, 'false'
  from def d, act_random a
  union all
  select 9, true, '動作', '全会員（' || a.total || '人）で is_admin() が profiles と一致',
         case when not d.is_admin_ok then '確認できず（定義不一致のため実行せず）'
              when a.total = 0 then '確認できず（会員なし）'
              when a.mismatch = 0 then '全員一致'
              else '不一致：' || a.bad end, '全員一致'
  from def d, act_all a
  union all
  select 10, true, '管理者', '管理者が1人以上いるか',
         case when not d.has_profiles then '確認できず（テーブルなし）'
              when (select count(*) from public.profiles where is_admin) >= 1 then 'はい' else 'いいえ' end, 'はい'
  from def d
  union all
  select 11, true, '補足', '会員・未ログインが実行でき、is_admin を書き換えそうな関数',
         case when not d.has_roles then '確認できず（ロールなし）'
              else coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'public'
                               and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                               and p.prosrc ~* '(set\s+is_admin|is_admin\s*:?=\s*(true|new\.|p_|\$))'), 'なし') end, 'なし'
  from def d
  -- 参考表示（判定には使わない）
  union all
  select 90, false, '参考', '実行日時・実行者・PostgreSQL',
         to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS') || ' ／ ' || session_user || ' ／ ' || current_setting('server_version'), null
  union all
  select 91, false, '参考', 'is_admin() の本体', coalesce(d.body, '関数なし'), null
  from def d
  union all
  select 92, false, '参考', '管理者の表示名',
         case when not d.has_profiles then 'テーブルなし'
              else coalesce((select string_agg(display_name, '、' order by display_name) from public.profiles where is_admin), 'なし') end, null
  from def d
  union all
  select 93, false, '参考', 'ログイン会員が更新できる profiles の列',
         case when not d.has_profiles or not d.has_roles then '確認できず'
              else coalesce((select string_agg(column_name, ', ' order by column_name) from information_schema.columns
                             where table_schema = 'public' and table_name = 'profiles'
                               and has_column_privilege('authenticated', 'public.profiles', column_name, 'UPDATE')), 'なし') end, null
  from def d
),
judged as (
  select ord, 区分, 項目, 結果, 期待,
         case when not 必須 then '参考' when 結果 = 期待 then 'OK' else 'NG' end as 判定
  from checks
)
select 判定, 区分, 項目, 結果, 期待
from (
  select 0 as grp, 0 as ord,
         case when count(*) filter (where 判定 = 'NG') = 0 and count(*) filter (where 判定 = 'OK') = 13 then 'OK' else 'NG' end as 判定,
         '総合判定' as 区分,
         '必須13項目中 OK ' || count(*) filter (where 判定 = 'OK') || '・NG ' || count(*) filter (where 判定 = 'NG') as 項目,
         null as 結果, null as 期待
  from judged
  union all
  select case 判定 when 'NG' then 1 when 'OK' then 2 else 3 end, ord, 判定, 区分, 項目, 結果, 期待
  from judged
) t
order by grp, ord;
