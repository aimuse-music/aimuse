-- =====================================================================
-- AIMUSE 本番の会員ごとの動作確認（読み取り専用）v1
-- 読み取り専用チェック v5 の「次の手順」です。v5 で OK になってから使います。
--
-- 何をするか
-- ・AIMUSE の通常の会員・未ログインの立場に切り替えて public.is_admin() を実際に呼び、
--   結果が profiles.is_admin と一致するか（管理者だけ true になるか）を確かめます
-- ・ログイン情報（auth.uid()）がどの形式で読み取られるかも確かめます（参考）
--
-- 安全のための仕組み
-- ・最初に「この取引は読み取り専用」に切り替えます。以降、データの追加・変更・削除は
--   データベース自身が拒否します（AIMUSE の関数がもし書き込もうとしてもエラーになり、何も変わりません）
-- ・立場の切り替え（SET LOCAL ROLE）とログイン情報の設定（set_config）は、すべてこの取引の中だけで有効です。
--   取引が終わると自動で元に戻ります
-- ・確認は DO ブロックの中で1つずつ順番に行います（1つの SELECT の中で評価順に頼ることはしません）
-- ・結果は最後の SELECT で通常の表として表示します。DO ブロックが同じ取引で実行されなかった場合や、
--   途中で想定外のエラーが起きた場合は、必ず「NG」と表示します（OK と誤表示しません）
-- ・会員の個人情報は表示しません（不一致があった場合だけ、その会員IDを表示します）
-- =====================================================================

do $chk$
declare
  v_res jsonb := '[]'::jsonb;
  v_ids uuid[];
  v_flags boolean[];
  v_total bigint;
  v_i integer;
  v_got boolean;
  v_bad text[] := '{}';
  v_uid uuid;
  v_txt text;
begin
  -- 0. ここから先は読み取り専用（この取引の中で書き込みは一切できない）
  perform set_config('transaction_read_only', 'on', true);
  v_res := v_res || jsonb_build_object('ord', 1, 'item', 'この確認が読み取り専用で実行されている',
             'result', case when current_setting('transaction_read_only') = 'on' then 'はい' else 'いいえ' end, 'expect', 'はい');

  if to_regclass('public.profiles') is null or to_regprocedure('public.is_admin()') is null then
    v_res := v_res || jsonb_build_object('ord', 2, 'item', 'AIMUSE の profiles と is_admin() がある', 'result', 'ない', 'expect', 'ある');
  else
    select count(*) into v_total from public.profiles;
    select coalesce(array_agg(p.id order by p.id), '{}'), coalesce(array_agg(p.is_admin order by p.id), '{}')
      into v_ids, v_flags
    from (select id, is_admin from public.profiles order by id limit 5000) p;

    -- 1. 未ログイン（anon）
    begin
      execute 'set local role anon';
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      perform set_config('request.jwt.claim.sub', '', true);
      v_got := public.is_admin();
      v_res := v_res || jsonb_build_object('ord', 3, 'item', '未ログインで is_admin()',
                 'result', coalesce(v_got::text, 'null'), 'expect', 'false');
      execute 'reset role';
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 3, 'item', '未ログインで is_admin()', 'result', 'エラー：' || sqlerrm, 'expect', 'false');
    end;

    -- 2. 存在しない会員（ログインはしているが profiles にいない）
    begin
      execute 'set local role authenticated';
      v_uid := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_uid)::text, true);
      perform set_config('request.jwt.claim.sub', v_uid::text, true);
      v_got := public.is_admin();
      v_res := v_res || jsonb_build_object('ord', 4, 'item', '存在しない会員で is_admin()',
                 'result', coalesce(v_got::text, 'null'), 'expect', 'false');
      execute 'reset role';
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 4, 'item', '存在しない会員で is_admin()', 'result', 'エラー：' || sqlerrm, 'expect', 'false');
    end;

    -- 3. 登録済みの全会員（最大5000人）：is_admin() が profiles.is_admin と一致するか
    begin
      execute 'set local role authenticated';
      for v_i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
        perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_ids[v_i])::text, true);
        perform set_config('request.jwt.claim.sub', v_ids[v_i]::text, true);
        v_got := public.is_admin();
        if v_got is distinct from v_flags[v_i] then
          v_bad := v_bad || (v_ids[v_i]::text || '=' || coalesce(v_got::text, 'null'));
        end if;
      end loop;
      execute 'reset role';
      v_res := v_res || jsonb_build_object('ord', 5, 'item', '登録会員 ' || coalesce(array_length(v_ids, 1), 0) || '人の is_admin() が profiles と一致',
                 'result', case when cardinality(v_bad) = 0 then '全員一致'
                                else '不一致 ' || cardinality(v_bad) || '人：' || array_to_string(v_bad[1:10], ', ') end,
                 'expect', '全員一致');
      v_res := v_res || jsonb_build_object('ord', 6, 'item', '管理者として呼ぶと true になる会員が1人以上いる',
                 'result', case when true = any(v_flags) and cardinality(v_bad) = 0 then 'はい' else 'いいえ' end, 'expect', 'はい');
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 5, 'item', '登録会員の is_admin() が profiles と一致', 'result', 'エラー：' || sqlerrm, 'expect', '全員一致');
    end;

    -- 4. BOOST 追加SQL（r9）の事前確認と同じ形（未ログイン → 元に戻さずにログイン会員へ切り替え）が使えるか
    begin
      execute 'set local role anon';
      execute 'set local role authenticated';
      v_res := v_res || jsonb_build_object('ord', 7, 'item', '追加SQL r9 と同じ立場の切り替え（anon → authenticated）',
                 'result', case when current_user = 'authenticated' then 'できる' else 'できない' end, 'expect', 'できる');
      execute 'reset role';
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 7, 'item', '追加SQL r9 と同じ立場の切り替え（anon → authenticated）', 'result', 'エラー：' || sqlerrm, 'expect', 'できる');
    end;

    -- 参考：ログイン情報（auth.uid()）がどの形式から読み取られるか（判定には使わない）
    begin
      v_uid := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_uid)::text, true);
      perform set_config('request.jwt.claim.sub', '', true);
      v_txt := case when auth.uid() = v_uid then '読める' else '読めない' end;
      perform set_config('request.jwt.claims', '', true);
      perform set_config('request.jwt.claim.sub', v_uid::text, true);
      v_txt := '新形式（request.jwt.claims）：' || v_txt || ' ／ 旧形式（request.jwt.claim.sub）：'
               || case when auth.uid() = v_uid then '読める' else '読めない' end;
      v_res := v_res || jsonb_build_object('ord', 90, 'item', 'auth.uid() の読み取り元', 'result', v_txt, 'expect', null);
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 90, 'item', 'auth.uid() の読み取り元', 'result', 'エラー：' || sqlerrm, 'expect', null);
    end;
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
    v_res := v_res || jsonb_build_object('ord', 91, 'item', '会員数（確認したのは最大5000人）', 'result', v_total || '人', 'expect', null);
  end if;

  v_res := v_res || jsonb_build_object('ord', 92, 'item', '実行日時・実行者・PostgreSQL',
             'result', to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS') || ' ／ ' || session_user || ' ／ ' || current_setting('server_version'),
             'expect', null);
  -- 結果は、この取引の中だけで有効な設定に入れて、下の SELECT で表示する
  perform set_config('boost.member_check', v_res::text, true);
end
$chk$;

-- 結果の表示（読み取りのみ）。上の DO ブロックが同じ取引で最後まで実行されていなければ、必ず NG になります
with
raw as (select nullif(current_setting('boost.member_check', true), '')::jsonb as j),
items as (
  select (e ->> 'ord')::int as ord, e ->> 'item' as 項目, e ->> 'result' as 結果, e ->> 'expect' as 期待
  from raw, jsonb_array_elements(coalesce(raw.j, '[]'::jsonb)) e
),
judged as (
  select ord, 項目, 結果, 期待,
         case when 期待 is null then '参考' when 結果 = 期待 then 'OK' else 'NG' end as 判定
  from items
)
select 判定, 項目, 結果, 期待
from (
  select 0 as grp, 0 as ord,
         case when (select j from raw) is null then 'NG'
              when count(*) filter (where 判定 = 'NG') = 0 and count(*) filter (where 判定 = 'OK') = 6 then 'OK'
              else 'NG' end as 判定,
         case when (select j from raw) is null then '総合判定：確認結果が見つかりません（全文を1回で実行してください）'
              else '総合判定：必須6項目中 OK ' || count(*) filter (where 判定 = 'OK') || '・NG ' || count(*) filter (where 判定 = 'NG') end as 項目,
         null as 結果, null as 期待
  from judged
  union all
  select case 判定 when 'NG' then 1 when 'OK' then 2 else 3 end, ord, 判定, 項目, 結果, 期待
  from judged
) t
order by grp, ord;
