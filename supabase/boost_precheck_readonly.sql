-- =====================================================================
-- AIMUSE 本番の読み取り専用チェック（BOOST の追加SQLを実行する前に使う）
--
-- ・このSQLは何も変更しません。最初に「読み取り専用の取引」に切り替えるため、
--   万一書き込もうとしてもデータベースが拒否します
-- ・AIMUSE の管理者判定 public.is_admin() と、会員が自分を管理者にできないことを、
--   定義・権限・実際の動作の3つの面から確認します
-- ・結果は1つの表で表示されます。「判定」がすべて OK（または 参考）なら問題ありません
-- =====================================================================

do $chk$
declare
  v_rows jsonb := '[]'::jsonb;
  v_body text;
  v_ids uuid[];
  v_flags boolean[];
  v_i integer;
  v_got boolean;
  v_bad text := '';
  v_checked integer := 0;
  v_role text;
begin
  -- この取引を読み取り専用にする（以降、書き込みはすべて拒否される）
  set transaction read only;
  v_rows := v_rows || jsonb_build_object('区分', '安全', '項目', 'このチェックは読み取り専用か',
             '結果', current_setting('transaction_read_only'), '期待', 'on');

  -- ---- 1. 定義 --------------------------------------------------------
  select btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) into v_body from pg_proc p where p.oid = to_regprocedure('public.is_admin()');
  v_rows := v_rows || jsonb_build_object('区分', '定義', '項目', 'is_admin() の本体（参考表示）', '結果', coalesce(v_body, '関数なし'), '期待', coalesce(v_body, '関数なし'));
  v_rows := v_rows || jsonb_build_object('区分', '定義', '項目', 'is_admin() の本体が AIMUSE 構築SQLと一致',
             '結果', case when md5(coalesce(v_body, '')) = '065dbcd2c17f6a4da4ba7cc6b24dad9e' then '一致' else '不一致' end, '期待', '一致');
  v_rows := v_rows || jsonb_build_object('区分', '定義', '項目', 'is_admin()：戻り値boolean・SQL・特権実行・search_path固定',
             '結果', case when exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang
                                       where p.oid = to_regprocedure('public.is_admin()') and p.prorettype = 'boolean'::regtype
                                         and l.lanname = 'sql' and p.prosecdef and 'search_path=""' = any(p.proconfig)) then 'はい' else 'いいえ' end,
             '期待', 'はい');
  v_rows := v_rows || jsonb_build_object('区分', '定義', '項目', '管理者フラグ保護関数 protect_profile_flags の本体が構築SQLと一致',
             '結果', case when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) from pg_proc p
                                where p.oid = to_regprocedure('public.protect_profile_flags()')) = 'fa40e1325abb252e0ed071bcdc6a5106' then '一致' else '不一致' end,
             '期待', '一致');
  v_rows := v_rows || jsonb_build_object('区分', '定義', '項目', '保護トリガー profiles_protect_flags（更新前・行ごと・有効）',
             '結果', case when exists (select 1 from pg_trigger g where g.tgrelid = 'public.profiles'::regclass and not g.tgisinternal
                                         and g.tgfoid = to_regproc('public.protect_profile_flags') and g.tgenabled <> 'D'
                                         and (g.tgtype & 19) = 19) then '有効' else '無効または無し' end,
             '期待', '有効');
  v_rows := v_rows || jsonb_build_object('区分', '定義', '項目', 'profiles の RLS',
             '結果', (select case when c.relrowsecurity then '有効' else '無効' end from pg_class c where c.oid = 'public.profiles'::regclass),
             '期待', '有効');

  -- ---- 2. 権限（データベースの権限情報。これが「なし」なら、どんな方法でも書き換えられない）
  foreach v_role in array array['anon', 'authenticated', 'public'] loop
    v_rows := v_rows || jsonb_build_object('区分', '権限', '項目', v_role || ' が profiles.is_admin を変更・追加できる',
               '結果', case when has_column_privilege(v_role, 'public.profiles', 'is_admin', 'UPDATE')
                              or has_column_privilege(v_role, 'public.profiles', 'is_admin', 'INSERT') then 'できる' else 'できない' end,
               '期待', 'できない');
  end loop;
  v_rows := v_rows || jsonb_build_object('区分', '権限', '項目', 'ログイン会員が更新できる profiles の列（参考表示）',
             '結果', coalesce((select string_agg(column_name, ', ' order by column_name) from information_schema.columns
                               where table_schema = 'public' and table_name = 'profiles'
                                 and has_column_privilege('authenticated', 'public.profiles', column_name, 'UPDATE')), 'なし'),
             '期待', coalesce((select string_agg(column_name, ', ' order by column_name) from information_schema.columns
                               where table_schema = 'public' and table_name = 'profiles'
                                 and has_column_privilege('authenticated', 'public.profiles', column_name, 'UPDATE')), 'なし'));

  -- ---- 3. 実際の動作（会員の立場に切り替えて is_admin() を呼ぶ。読むだけ）
  select coalesce(array_agg(p.id order by p.id), '{}'), coalesce(array_agg(p.is_admin order by p.id), '{}')
    into v_ids, v_flags from (select id, is_admin from public.profiles order by id limit 5000) p;
  begin
    execute 'set local role anon';
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('request.jwt.claim.sub', '', true);
    v_rows := v_rows || jsonb_build_object('区分', '動作', '項目', '未ログインで is_admin()', '結果', public.is_admin()::text, '期待', 'false');
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid())::text, true);
    perform set_config('request.jwt.claim.sub', current_setting('request.jwt.claims')::json ->> 'sub', true);
    v_rows := v_rows || jsonb_build_object('区分', '動作', '項目', '存在しない会員で is_admin()', '結果', public.is_admin()::text, '期待', 'false');
    for v_i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_ids[v_i])::text, true);
      perform set_config('request.jwt.claim.sub', v_ids[v_i]::text, true);
      v_got := public.is_admin();
      v_checked := v_checked + 1;
      if v_got is distinct from v_flags[v_i] then v_bad := v_bad || v_ids[v_i]::text || ' '; end if;
    end loop;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
    v_rows := v_rows || jsonb_build_object('区分', '動作', '項目', '全会員（' || v_checked || '人）で is_admin() が profiles と一致',
               '結果', case when v_bad = '' then '全員一致' else '不一致：' || v_bad end, '期待', '全員一致');
  exception when insufficient_privilege then
    v_rows := v_rows || jsonb_build_object('区分', '動作', '項目', '会員の立場への切り替え', '結果', '不可：' || sqlerrm, '期待', '可');
  end;

  -- ---- 4. 管理者（参考表示）
  v_rows := v_rows || jsonb_build_object('区分', '管理者', '項目', '管理者の人数',
             '結果', (select count(*) from public.profiles where is_admin)::text || '人', '期待', '1人以上');
  v_rows := v_rows || jsonb_build_object('区分', '管理者', '項目', '管理者の表示名（参考表示）',
             '結果', coalesce((select string_agg(display_name, '、' order by display_name) from public.profiles where is_admin), 'なし'),
             '期待', coalesce((select string_agg(display_name, '、' order by display_name) from public.profiles where is_admin), 'なし'));

  -- ---- 5. 補足（関数の本文を文字で調べる参考確認。これだけを安全の根拠にはしない）
  v_rows := v_rows || jsonb_build_object('区分', '補足', '項目', '会員・未ログインが実行でき、is_admin を書き換えそうな関数',
             '結果', coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname = 'public'
                                 and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                                 and p.prosrc ~* '(set\s+is_admin|is_admin\s*:?=\s*(true|new\.|p_|\$))'), 'なし'),
             '期待', 'なし');

  perform set_config('boost.precheck', v_rows::text, false);
end
$chk$;

select x.区分, x.項目, x.結果, x.期待,
       case when x.項目 like '%（参考表示）' then '参考'
            when x.期待 = '1人以上' then case when x.結果 <> '0人' then 'OK' else 'NG' end
            when x.結果 = x.期待 then 'OK' else 'NG' end as 判定
from json_to_recordset(current_setting('boost.precheck')::json) as x(区分 text, 項目 text, 結果 text, 期待 text);
