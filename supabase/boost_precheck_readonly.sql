-- =====================================================================
-- AIMUSE 本番の読み取り専用チェック v3（BOOST の追加SQLを実行する前に使う）
--
-- ・このSQLは何も変更しません。
--   - 全体が「1つの文（DOブロック）」で、最初に読み取り専用の取引に切り替えます。
--     書き込もうとしてもデータベースが拒否します
--   - 最後は必ず「結果を載せたエラー」で終わるため、取引は自動的にすべて取り消されます
--     （ロールの切り替えなども含め、何も残りません）
-- ・結果はエラーメッセージとして表示されます。これは不具合ではありません。
--   1つの文の中で確認と表示を完結させるため、接続が途中で変わっても結果が失われません
-- ・確認できなかった項目（途中のエラーなど）は、必ず NG として表示します
-- ・1行目が「総合判定：OK」なら問題ありません
-- =====================================================================

do $chk$
declare
  v_rows jsonb := '[]'::jsonb;   -- 結果の行：{k, 区分, 項目, 結果, 期待, 必須}
  v_required text[] := array['ro', 'member', 'def_body', 'def_attr', 'protect_body', 'protect_trg', 'rls',
                             'priv_anon', 'priv_authenticated', 'priv_public',
                             'act_anon', 'act_random', 'act_all', 'admin_count', 'fn_scan'];
  v_body text;
  v_ids uuid[];
  v_flags boolean[];
  v_i integer;
  v_got boolean;
  v_bad text;
  v_role text;
  v_r jsonb;
  v_ng integer := 0;
  v_ok integer := 0;
  v_lines text := '';
  v_k text;
begin
  -- この取引を読み取り専用にする（この文が取引の最初の処理。以降の書き込みはすべて拒否される）
  set transaction read only;

  -- ---- 0. 安全 ------------------------------------------------------------
  v_rows := v_rows || jsonb_build_object('k', 'ro', '区分', '安全', '項目', 'この確認は読み取り専用の取引か',
             '結果', current_setting('transaction_read_only'), '期待', 'on', '必須', true);
  v_rows := v_rows || jsonb_build_object('k', 'info_run', '区分', '参考', '項目', '実行日時・実行者・PostgreSQL',
             '結果', to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS') || ' ／ ' || session_user || ' ／ ' || current_setting('server_version'),
             '必須', false);
  begin
    v_rows := v_rows || jsonb_build_object('k', 'member', '区分', '安全', '項目', '実行者が anon・authenticated に切り替え可能か（所属）',
               '結果', case when (select count(*) from pg_roles where rolname in ('anon', 'authenticated')) = 2
                                and pg_has_role(session_user, 'anon', 'MEMBER') and pg_has_role(session_user, 'authenticated', 'MEMBER')
                           then '可能' else '不可' end,
               '期待', '可能', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'member', '区分', '安全', '項目', '実行者が anon・authenticated に切り替え可能か（所属）',
               '結果', '確認できず：' || sqlerrm, '期待', '可能', '必須', true);
  end;

  -- ---- 1. 定義 ------------------------------------------------------------
  begin
    select btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g')) into v_body from pg_proc p where p.oid = to_regprocedure('public.is_admin()');
    v_rows := v_rows || jsonb_build_object('k', 'info_body', '区分', '参考', '項目', 'is_admin() の本体', '結果', coalesce(v_body, '関数なし'), '必須', false);
    v_rows := v_rows || jsonb_build_object('k', 'def_body', '区分', '定義', '項目', 'is_admin() の本体が AIMUSE 構築SQLと一致',
               '結果', case when md5(coalesce(v_body, '')) = '065dbcd2c17f6a4da4ba7cc6b24dad9e' then '一致' else '不一致' end,
               '期待', '一致', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'def_body', '区分', '定義', '項目', 'is_admin() の本体が AIMUSE 構築SQLと一致',
               '結果', '確認できず：' || sqlerrm, '期待', '一致', '必須', true);
  end;
  begin
    v_rows := v_rows || jsonb_build_object('k', 'def_attr', '区分', '定義', '項目', 'is_admin()：戻り値boolean・SQL・特権実行・search_path固定',
               '結果', case when exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang
                                         where p.oid = to_regprocedure('public.is_admin()') and p.prorettype = 'boolean'::regtype
                                           and l.lanname = 'sql' and p.prosecdef and 'search_path=""' = any(p.proconfig)) then 'はい' else 'いいえ' end,
               '期待', 'はい', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'def_attr', '区分', '定義', '項目', 'is_admin()：戻り値boolean・SQL・特権実行・search_path固定',
               '結果', '確認できず：' || sqlerrm, '期待', 'はい', '必須', true);
  end;
  begin
    v_rows := v_rows || jsonb_build_object('k', 'protect_body', '区分', '定義', '項目', '管理者フラグ保護関数の本体が構築SQLと一致',
               '結果', case when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) from pg_proc p
                                  where p.oid = to_regprocedure('public.protect_profile_flags()')) = 'fa40e1325abb252e0ed071bcdc6a5106'
                           then '一致' else '不一致' end,
               '期待', '一致', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'protect_body', '区分', '定義', '項目', '管理者フラグ保護関数の本体が構築SQLと一致',
               '結果', '確認できず：' || sqlerrm, '期待', '一致', '必須', true);
  end;
  begin
    v_rows := v_rows || jsonb_build_object('k', 'protect_trg', '区分', '定義', '項目', '保護トリガー（更新前・行ごと・有効）',
               '結果', case when exists (select 1 from pg_trigger g where g.tgrelid = 'public.profiles'::regclass and not g.tgisinternal
                                           and g.tgfoid = to_regproc('public.protect_profile_flags') and g.tgenabled <> 'D'
                                           and (g.tgtype & 19) = 19) then '有効' else '無効または無し' end,
               '期待', '有効', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'protect_trg', '区分', '定義', '項目', '保護トリガー（更新前・行ごと・有効）',
               '結果', '確認できず：' || sqlerrm, '期待', '有効', '必須', true);
  end;
  begin
    v_rows := v_rows || jsonb_build_object('k', 'rls', '区分', '定義', '項目', 'profiles の RLS',
               '結果', (select case when c.relrowsecurity then '有効' else '無効' end from pg_class c where c.oid = 'public.profiles'::regclass),
               '期待', '有効', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'rls', '区分', '定義', '項目', 'profiles の RLS',
               '結果', '確認できず：' || sqlerrm, '期待', '有効', '必須', true);
  end;

  -- ---- 2. 権限（データベースの権限情報。これが「できない」なら、どんな方法でも書き換えられない）
  foreach v_role in array array['anon', 'authenticated', 'public'] loop
    begin
      v_rows := v_rows || jsonb_build_object('k', 'priv_' || v_role, '区分', '権限', '項目', v_role || ' が profiles.is_admin を変更・追加できるか',
                 '結果', case when has_column_privilege(v_role, 'public.profiles', 'is_admin', 'UPDATE')
                                or has_column_privilege(v_role, 'public.profiles', 'is_admin', 'INSERT') then 'できる' else 'できない' end,
                 '期待', 'できない', '必須', true);
    exception when others then
      v_rows := v_rows || jsonb_build_object('k', 'priv_' || v_role, '区分', '権限', '項目', v_role || ' が profiles.is_admin を変更・追加できるか',
                 '結果', '確認できず：' || sqlerrm, '期待', 'できない', '必須', true);
    end;
  end loop;
  begin
    v_rows := v_rows || jsonb_build_object('k', 'info_cols', '区分', '参考', '項目', 'ログイン会員が更新できる profiles の列',
               '結果', coalesce((select string_agg(column_name, ', ' order by column_name) from information_schema.columns
                                 where table_schema = 'public' and table_name = 'profiles'
                                   and has_column_privilege('authenticated', 'public.profiles', column_name, 'UPDATE')), 'なし'),
               '必須', false);
  exception when others then null;
  end;

  -- ---- 3. 実際の動作（会員の立場に切り替えて is_admin() を呼ぶ。読むだけ）
  --     ・切り替えは SET LOCAL ROLE（この取引の中だけ有効）。1つ確認するたびに RESET ROLE で元に戻す
  --     ・ログイン情報（request.jwt.*）も、取引の中だけ有効な値として設定し、確認後に空に戻す
  begin
    execute 'set local role anon';
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('request.jwt.claim.sub', '', true);
    v_got := public.is_admin();
    execute 'reset role';
    v_rows := v_rows || jsonb_build_object('k', 'act_anon', '区分', '動作', '項目', '未ログインで is_admin()',
               '結果', coalesce(v_got::text, 'null'), '期待', 'false', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'act_anon', '区分', '動作', '項目', '未ログインで is_admin()',
               '結果', '確認できず：' || sqlerrm, '期待', 'false', '必須', true);
  end;
  begin
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid())::text, true);
    perform set_config('request.jwt.claim.sub', current_setting('request.jwt.claims')::json ->> 'sub', true);
    v_got := public.is_admin();
    execute 'reset role';
    v_rows := v_rows || jsonb_build_object('k', 'act_random', '区分', '動作', '項目', '存在しない会員で is_admin()',
               '結果', coalesce(v_got::text, 'null'), '期待', 'false', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'act_random', '区分', '動作', '項目', '存在しない会員で is_admin()',
               '結果', '確認できず：' || sqlerrm, '期待', 'false', '必須', true);
  end;
  begin
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
    select coalesce(array_agg(p.id order by p.id), '{}'), coalesce(array_agg(p.is_admin order by p.id), '{}')
      into v_ids, v_flags from (select id, is_admin from public.profiles order by id limit 5000) p;
    v_bad := '';
    execute 'set local role authenticated';
    for v_i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_ids[v_i])::text, true);
      perform set_config('request.jwt.claim.sub', v_ids[v_i]::text, true);
      v_got := public.is_admin();
      if v_got is distinct from v_flags[v_i] then v_bad := v_bad || left(v_ids[v_i]::text, 8) || '… '; end if;
    end loop;
    execute 'reset role';
    v_rows := v_rows || jsonb_build_object('k', 'act_all', '区分', '動作',
               '項目', '全会員（' || coalesce(array_length(v_ids, 1), 0) || '人）で is_admin() が profiles と一致',
               '結果', case when coalesce(array_length(v_ids, 1), 0) = 0 then '会員なし'
                            when v_bad = '' then '全員一致' else '不一致：' || v_bad end,
               '期待', '全員一致', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'act_all', '区分', '動作', '項目', '全会員で is_admin() が profiles と一致',
               '結果', '確認できず：' || sqlerrm, '期待', '全員一致', '必須', true);
  end;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);

  -- ---- 4. 管理者 ----------------------------------------------------------
  begin
    v_rows := v_rows || jsonb_build_object('k', 'admin_count', '区分', '管理者',
               '項目', '管理者の人数（' || (select count(*) from public.profiles where is_admin) || '人）',
               '結果', case when (select count(*) from public.profiles where is_admin) >= 1 then '1人以上' else '0人' end,
               '期待', '1人以上', '必須', true);
    v_rows := v_rows || jsonb_build_object('k', 'info_admins', '区分', '参考', '項目', '管理者の表示名',
               '結果', coalesce((select string_agg(display_name, '、' order by display_name) from public.profiles where is_admin), 'なし'),
               '必須', false);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'admin_count', '区分', '管理者', '項目', '管理者の人数',
               '結果', '確認できず：' || sqlerrm, '期待', '1人以上', '必須', true);
  end;

  -- ---- 5. 補足（関数の本文を文字で調べる参考確認。これだけを安全の根拠にはしない）
  begin
    v_rows := v_rows || jsonb_build_object('k', 'fn_scan', '区分', '補足', '項目', '会員・未ログインが実行でき、is_admin を書き換えそうな関数',
               '結果', coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                 where n.nspname = 'public'
                                   and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                                   and p.prosrc ~* '(set\s+is_admin|is_admin\s*:?=\s*(true|new\.|p_|\$))'), 'なし'),
               '期待', 'なし', '必須', true);
  exception when others then
    v_rows := v_rows || jsonb_build_object('k', 'fn_scan', '区分', '補足', '項目', '会員・未ログインが実行でき、is_admin を書き換えそうな関数',
               '結果', '確認できず：' || sqlerrm, '期待', 'なし', '必須', true);
  end;

  -- ---- 6. 確認できなかった必須項目は NG として追加 ------------------------------
  foreach v_k in array v_required loop
    if not exists (select 1 from jsonb_array_elements(v_rows) e where e ->> 'k' = v_k) then
      v_rows := v_rows || jsonb_build_object('k', v_k, '区分', '未確認', '項目', v_k, '結果', '確認できず', '期待', '確認済み', '必須', true);
    end if;
  end loop;

  -- ---- 7. 結果の表示 ---------------------------------------------------------
  for v_r in select e from jsonb_array_elements(v_rows) e loop
    if (v_r ->> '必須')::boolean then
      if v_r ->> '結果' = v_r ->> '期待' then
        v_ok := v_ok + 1;
        v_lines := v_lines || E'\n' || 'OK ｜' || (v_r ->> '区分') || '｜' || (v_r ->> '項目') || '：' || (v_r ->> '結果');
      else
        v_ng := v_ng + 1;
        v_lines := v_lines || E'\n' || 'NG ｜' || (v_r ->> '区分') || '｜' || (v_r ->> '項目') || '：' || (v_r ->> '結果') || '（期待：' || (v_r ->> '期待') || '）';
      end if;
    else
      v_lines := v_lines || E'\n' || '参考｜' || (v_r ->> '項目') || '：' || (v_r ->> '結果');
    end if;
  end loop;

  -- 結果を載せて終了する（エラーとして終わることで、取引は自動的にすべて取り消される）
  raise exception using
    errcode = 'BST99',
    message = '総合判定：' || case when v_ng = 0 and v_ok = array_length(v_required, 1) then 'OK' else 'NG' end
              || '（必須 ' || array_length(v_required, 1) || ' 項目中 OK ' || v_ok || '・NG ' || v_ng || '）'
              || E'\n※これはエラーではありません。確認結果を表示し、何も残さずに終えるため、この形で終了しています。'
              || v_lines;
end
$chk$;
