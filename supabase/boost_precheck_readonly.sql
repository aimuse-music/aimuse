-- =====================================================================
-- AIMUSE 本番の読み取り専用チェック v5（BOOST の追加SQLを実行する前に使う）
--
-- ・SELECT 文1つだけです。データベースの情報を読むだけで、何も変更しません
-- ・ログイン情報の設定（set_config）も、AIMUSE の関数の呼び出しも一切しません
--   （is_admin() は「定義の中身」を読むだけで、実行はしません）
-- ・結果は通常の表で表示されます。1行目が「総合判定」、その下に NG の行が先に並びます
-- ・会員ごとの動作確認は、このSQLでは行いません（別の手順で行います）
-- =====================================================================

with
info as (
  select
    to_regclass('public.profiles') as profiles,
    to_regprocedure('public.is_admin()') as is_admin_fn,
    to_regprocedure('public.protect_profile_flags()') as protect_fn,
    (select count(*) from pg_roles where rolname in ('anon', 'authenticated')) = 2 as has_roles
),
checks(ord, 必須, 区分, 項目, 結果, 期待) as (
  -- 1. is_admin() の定義
  select 1, true, '定義', 'is_admin() の本体が AIMUSE 構築SQLと一致',
         case when i.is_admin_fn is null then '関数なし'
              when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) from pg_proc p where p.oid = i.is_admin_fn)
                   = '065dbcd2c17f6a4da4ba7cc6b24dad9e' then '一致'
              else '不一致' end, '一致'
  from info i
  union all
  select 2, true, '定義', 'is_admin()：戻り値boolean・SQL・特権実行・search_path固定',
         case when i.is_admin_fn is null then '関数なし'
              when exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang
                           where p.oid = i.is_admin_fn and p.prorettype = 'boolean'::regtype and l.lanname = 'sql'
                             and p.prosecdef and 'search_path=""' = any(p.proconfig)) then 'はい'
              else 'いいえ' end, 'はい'
  from info i
  union all
  -- 2. 管理者フラグの保護
  select 3, true, '定義', '管理者フラグ保護関数の本体が構築SQLと一致',
         case when i.protect_fn is null then '関数なし'
              when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) from pg_proc p where p.oid = i.protect_fn)
                   = 'fa40e1325abb252e0ed071bcdc6a5106' then '一致'
              else '不一致' end, '一致'
  from info i
  union all
  select 4, true, '定義', '保護トリガー（profiles・更新前・行ごと・有効）',
         case when exists (select 1 from pg_trigger g
                           where g.tgrelid = i.profiles and not g.tgisinternal and g.tgfoid = i.protect_fn
                             and g.tgenabled <> 'D' and (g.tgtype & 19) = 19) then '有効'
              else '無効または無し' end, '有効'
  from info i
  union all
  select 5, true, '定義', 'profiles の RLS',
         coalesce((select case when c.relrowsecurity then '有効' else '無効' end from pg_class c where c.oid = i.profiles), 'テーブルなし'), '有効'
  from info i
  union all
  -- 3. 権限（これが「できない」なら、どんな方法でも profiles.is_admin は書き換えられない）
  select 6, true, '権限', r.role || ' が profiles.is_admin を変更・追加できるか',
         case when i.profiles is null then '確認できず（テーブルなし）'
              when r.role <> 'public' and not exists (select 1 from pg_roles where rolname = r.role) then '確認できず（ロールなし）'
              when has_column_privilege(r.role, i.profiles, 'is_admin', 'UPDATE')
                or has_column_privilege(r.role, i.profiles, 'is_admin', 'INSERT') then 'できる'
              else 'できない' end, 'できない'
  from info i, (values ('anon'), ('authenticated'), ('public')) r(role)
  union all
  select 7, true, '権限', '未ログイン・ログイン会員が is_admin() を実行できるか',
         case when not i.has_roles or i.is_admin_fn is null then '確認できず'
              when has_function_privilege('anon', i.is_admin_fn, 'EXECUTE')
               and has_function_privilege('authenticated', i.is_admin_fn, 'EXECUTE') then 'できる'
              else 'できない' end, 'できる'
  from info i
  union all
  -- 4. 管理者の人数
  select 8, true, '管理者', '管理者が1人以上いるか',
         case when i.profiles is null then '確認できず（テーブルなし）'
              when (select count(*) from public.profiles where is_admin) >= 1 then 'はい'
              else 'いいえ' end, 'はい'
  from info i
  union all
  -- 5. 補足（関数の本文を文字で調べる参考確認。これだけを安全の根拠にはしない）
  select 9, true, '補足', '会員・未ログインが実行でき、is_admin を書き換えそうな関数',
         case when not i.has_roles then '確認できず（ロールなし）'
              else coalesce((select string_agg(p.oid::regprocedure::text, ', ')
                             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'public'
                               and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                               and p.prosrc ~* '(set\s+is_admin|is_admin\s*:?=\s*(true|new\.|p_|\$))'), 'なし') end, 'なし'
  from info i
  -- 参考表示（判定には使わない）
  union all
  select 90, false, '参考', '実行日時・実行者・PostgreSQL',
         to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS') || ' ／ ' || session_user || ' ／ ' || current_setting('server_version'), null
  union all
  select 91, false, '参考', 'is_admin() の本体',
         coalesce((select btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) from pg_proc p where p.oid = i.is_admin_fn), '関数なし'), null
  from info i
  union all
  select 92, false, '参考', '管理者の人数と表示名',
         case when i.profiles is null then 'テーブルなし'
              else (select count(*) || '人：' || coalesce(string_agg(display_name, '、' order by display_name), 'なし')
                    from public.profiles where is_admin) end, null
  from info i
  union all
  select 93, false, '参考', 'ログイン会員が更新できる profiles の列',
         case when i.profiles is null or not i.has_roles then '確認できず'
              else coalesce((select string_agg(a.attname, ', ' order by a.attname) from pg_attribute a
                             where a.attrelid = i.profiles and a.attnum > 0 and not a.attisdropped
                               and has_column_privilege('authenticated', i.profiles, a.attnum, 'UPDATE')), 'なし') end, null
  from info i
),
judged as (
  select ord, 区分, 項目, 結果, 期待,
         case when not 必須 then '参考' when 結果 = 期待 then 'OK' else 'NG' end as 判定
  from checks
)
select 判定, 区分, 項目, 結果, 期待
from (
  select 0 as grp, 0 as ord,
         case when count(*) filter (where 判定 = 'NG') = 0 and count(*) filter (where 判定 = 'OK') = 11 then 'OK' else 'NG' end as 判定,
         '総合判定' as 区分,
         '必須11項目中 OK ' || count(*) filter (where 判定 = 'OK') || '・NG ' || count(*) filter (where 判定 = 'NG') as 項目,
         null as 結果, null as 期待
  from judged
  union all
  select case 判定 when 'NG' then 1 when 'OK' then 2 else 3 end, ord, 判定, 区分, 項目, 結果, 期待
  from judged
) t
order by grp, ord;
