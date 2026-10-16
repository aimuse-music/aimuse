-- =====================================================================
-- AIMUSE 本番の会員ごとの動作確認（読み取り専用）v3
-- 読み取り専用チェック v5 の「次の手順」です。v5 で OK になってから使います。
-- SQL Editor の「Role」は postgres のまま、全文を貼り付けて Run を1回押してください（一部だけ選んで実行しない）。
--
-- 何をするか
-- ・AIMUSE の通常の会員・未ログインの立場に切り替えて public.is_admin() を実際に呼び、
--   結果が profiles.is_admin と一致するか（管理者だけ true になるか）を確かめます
-- ・ログイン情報（auth.uid()）がどの形式で読み取られるか、APIの事前処理の設定があるかも表示します（参考）
--
-- 安全のための仕組み（読み取り専用を二重にかけます）
-- ・1行目の SET TRANSACTION READ ONLY で、この取引を最初から読み取り専用にします
-- ・DO ブロックの最初でも、もう一度読み取り専用にします（1行目が効かない送り方でも、ここで必ずかかる）
-- ・一度読み取り専用になった取引は、データベースの仕様で途中から書き込み可能に戻せません。
--   データの追加・変更・削除、テーブル・関数・権限の変更は、データベース自身が拒否します
-- ・立場の切り替え（SET LOCAL ROLE）とログイン情報の設定（set_config）は、この取引の中だけで有効です。
--   例外が起きた部分の切り替えはデータベースが自動で取り消し、各確認の後でも実行前の状態に明示的に戻します
-- ・最後の SELECT は「DO ブロックと同じ取引・同じ接続で表示していること」を自分で確かめます。
--   確かめられない・途中でエラーが起きた・確認できない項目がある場合は、必ず総合判定が NG になります
-- ・会員の個人情報は表示しません（不一致があった場合だけ、その会員IDを表示します）
-- =====================================================================

set transaction read only;

do $chk$
declare
  v_res jsonb := '[]'::jsonb;
  v_start_ro text := current_setting('transaction_read_only');  -- 1行目が効いているか（DO開始時点）
  v_role text := current_user;                                    -- 実行前の立場（最後にここへ戻す）
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_sub text := coalesce(current_setting('request.jwt.claim.sub', true), '');
  v_ids uuid[];
  v_flags boolean[];
  v_total bigint;
  v_admins bigint;
  v_n integer;
  v_i integer;
  v_got boolean;
  v_bad text[] := '{}';
  v_uid uuid;
  v_txt text;
begin
  -- 0. 二重目の読み取り専用（これ以降、この取引では書き込みが一切できない）
  perform set_config('transaction_read_only', 'on', true);

  v_res := v_res || jsonb_build_object('ord', 1, 'item', '取引の最初から読み取り専用（1行目が有効）',
             'result', case when v_start_ro = 'on' then 'はい' else 'いいえ' end, 'expect', 'はい');
  v_res := v_res || jsonb_build_object('ord', 2, 'item', 'DOブロック内でも読み取り専用',
             'result', case when current_setting('transaction_read_only') = 'on' then 'はい' else 'いいえ' end, 'expect', 'はい');
  v_res := v_res || jsonb_build_object('ord', 3, 'item', '実行者の立場が postgres（SQL Editor の Role 設定）',
             'result', v_role, 'expect', 'postgres');
  v_res := v_res || jsonb_build_object('ord', 4, 'item', 'is_admin() の本体が v5 で確認したもの（AIMUSE構築SQL）と同じ',
             'result', coalesce((select case when md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) = '065dbcd2c17f6a4da4ba7cc6b24dad9e'
                                            then '同じ' else '異なる' end
                                 from pg_proc p where p.oid = to_regprocedure('public.is_admin()')), '関数なし'),
             'expect', '同じ');

  if v_role = 'postgres' and to_regclass('public.profiles') is not null and to_regprocedure('public.is_admin()') is not null then
    -- 確認する会員：管理者は全員＋それ以外の会員を最大5000人
    select count(*), count(*) filter (where is_admin) into v_total, v_admins from public.profiles;
    select coalesce(array_agg(p.id order by p.id), '{}'), coalesce(array_agg(p.is_admin order by p.id), '{}')
      into v_ids, v_flags
    from (select id, is_admin from public.profiles where is_admin
          union all
          (select id, is_admin from public.profiles where is_admin is not true order by id limit 5000)) p;
    v_n := coalesce(array_length(v_ids, 1), 0);

    -- 1. 未ログイン（anon）
    begin
      execute 'set local role anon';
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      perform set_config('request.jwt.claim.sub', '', true);
      v_got := public.is_admin();
      execute format('set local role %I', v_role);
      v_res := v_res || jsonb_build_object('ord', 5, 'item', '未ログインで is_admin()', 'result', coalesce(v_got::text, 'null'), 'expect', 'false');
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 5, 'item', '未ログインで is_admin()', 'result', 'エラー：' || sqlerrm, 'expect', 'false');
    end;

    -- 2. 存在しない会員（ログインはしているが profiles にいない）
    begin
      execute 'set local role authenticated';
      v_uid := gen_random_uuid();
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_uid)::text, true);
      perform set_config('request.jwt.claim.sub', v_uid::text, true);
      v_got := public.is_admin();
      execute format('set local role %I', v_role);
      v_res := v_res || jsonb_build_object('ord', 6, 'item', '存在しない会員で is_admin()', 'result', coalesce(v_got::text, 'null'), 'expect', 'false');
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 6, 'item', '存在しない会員で is_admin()', 'result', 'エラー：' || sqlerrm, 'expect', 'false');
    end;

    -- 3. 登録会員：is_admin() が profiles.is_admin と一致するか（会員が0人なら「確認できず」で NG）
    begin
      execute 'set local role authenticated';
      for v_i in 1 .. v_n loop
        perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_ids[v_i])::text, true);
        perform set_config('request.jwt.claim.sub', v_ids[v_i]::text, true);
        v_got := public.is_admin();
        if v_got is distinct from coalesce(v_flags[v_i], false) then
          v_bad := v_bad || (v_ids[v_i]::text || '=' || coalesce(v_got::text, 'null'));
        end if;
      end loop;
      execute format('set local role %I', v_role);
      v_res := v_res || jsonb_build_object('ord', 7, 'item', '登録会員の is_admin() が profiles と一致（確認 ' || v_n || '人）',
                 'result', case when v_n = 0 then '会員0人（確認できず）'
                                when cardinality(v_bad) = 0 then '全員一致'
                                else '不一致 ' || cardinality(v_bad) || '人：' || array_to_string(v_bad[1:10], ', ') end,
                 'expect', '全員一致');
      v_res := v_res || jsonb_build_object('ord', 8, 'item', '管理者全員（' || v_admins || '人）が確認対象に含まれ、true になる',
                 'result', case when v_admins >= 1 and cardinality(v_bad) = 0
                                 and (select count(*) from unnest(v_flags) f where f) = v_admins then 'はい' else 'いいえ' end,
                 'expect', 'はい');
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 7, 'item', '登録会員の is_admin() が profiles と一致', 'result', 'エラー：' || sqlerrm, 'expect', '全員一致');
    end;

    -- 4. BOOST 追加SQL（r9）の事前確認と同じ形（未ログイン → 元に戻さずにログイン会員へ切り替え）が使えるか
    begin
      execute 'set local role anon';
      execute 'set local role authenticated';
      v_txt := current_user;
      execute format('set local role %I', v_role);
      v_res := v_res || jsonb_build_object('ord', 9, 'item', '追加SQL r9 と同じ立場の切り替え（anon → authenticated）',
                 'result', case when v_txt = 'authenticated' then 'できる' else 'できない' end, 'expect', 'できる');
    exception when others then
      v_res := v_res || jsonb_build_object('ord', 9, 'item', '追加SQL r9 と同じ立場の切り替え（anon → authenticated）', 'result', 'エラー：' || sqlerrm, 'expect', 'できる');
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
    v_res := v_res || jsonb_build_object('ord', 91, 'item', '会員数・管理者数（会員は最大5000人＋管理者全員を確認）',
               'result', v_total || '人・管理者 ' || v_admins || '人', 'expect', null);
  else
    v_res := v_res || jsonb_build_object('ord', 5, 'item', '会員ごとの確認', 'result',
               case when v_role <> 'postgres' then '実行者が postgres でないため行わず' else 'profiles または is_admin() がないため行わず' end, 'expect', '実施');
  end if;

  -- 参考：APIの入口（PostgREST）が使う役割に、事前処理などの特別な設定があるか（判定には使わない）
  begin
    v_txt := coalesce((select string_agg(r.rolname || '：' || array_to_string(s.setconfig, ', '), ' ／ ' order by r.rolname)
                       from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
                       where r.rolname in ('authenticator', 'anon', 'authenticated')), 'なし');
  exception when others then
    v_txt := '読み取れず：' || sqlerrm;
  end;
  v_res := v_res || jsonb_build_object('ord', 92, 'item', 'API用の役割（authenticator・anon・authenticated）の個別設定', 'result', v_txt, 'expect', null);
  v_res := v_res || jsonb_build_object('ord', 93, 'item', '実行日時・接続ユーザー・PostgreSQL',
             'result', to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI:SS') || ' ／ ' || session_user || ' ／ ' || current_setting('server_version'),
             'expect', null);

  -- 実行前の立場・ログイン情報に戻す（例外で途中終了した部分は、データベースが自動で戻している）
  execute format('set local role %I', v_role);
  perform set_config('request.jwt.claims', v_claims, true);
  perform set_config('request.jwt.claim.sub', v_sub, true);
  -- 結果は、この取引の中だけで有効な設定に入れて、下の SELECT で表示する。
  -- 同じ取引・同じ接続で表示したかを確かめるため、取引の開始時刻・接続番号・実行前の状態も入れる
  perform set_config('boost.member_check', jsonb_build_object(
    'items', v_res,
    'xact', extract(epoch from transaction_timestamp())::text,
    'pid', pg_backend_pid(),
    'role', v_role, 'claims', v_claims, 'sub', v_sub)::text, true);
end
$chk$;

-- 結果の表示（読み取りのみ）
-- 総合判定が OK になるのは「必須の12項目がそれぞれちょうど1回ずつ OK で、NG が0件」のときだけです
with
raw as (select nullif(current_setting('boost.member_check', true), '')::jsonb as j),
items as (
  select (e ->> 'ord')::int as ord, e ->> 'item' as 項目, e ->> 'result' as 結果, e ->> 'expect' as 期待
  from raw, jsonb_array_elements(coalesce(raw.j -> 'items', '[]'::jsonb)) e
  union all
  -- 表示する側（この SELECT）での確認
  select 10, 'DOブロックと表示が同じ取引・同じ接続',
         case when j is null then '確認結果なし'
              when j ->> 'xact' = extract(epoch from transaction_timestamp())::text and (j ->> 'pid')::int = pg_backend_pid() then 'はい'
              else 'いいえ' end, 'はい'
  from raw
  union all
  select 11, '確認の後、実行者の立場とログイン情報が実行前と同じに戻っている',
         case when j is null then '確認結果なし'
              when current_user = j ->> 'role'
               and coalesce(current_setting('request.jwt.claims', true), '') = j ->> 'claims'
               and coalesce(current_setting('request.jwt.claim.sub', true), '') = j ->> 'sub' then 'はい'
              else 'いいえ（現在：' || current_user || '）' end, 'はい'
  from raw
  union all
  select 12, '表示の時点でも読み取り専用', case when current_setting('transaction_read_only') = 'on' then 'はい' else 'いいえ' end, 'はい'
),
judged as (
  select ord, 項目, 結果, 期待,
         case when 期待 is null then '参考' when 結果 = 期待 then 'OK' else 'NG' end as 判定
  from items
),
total as (
  select (select j from raw) is not null
         and count(*) filter (where 判定 = 'NG') = 0
         and count(*) filter (where 判定 = 'OK') = 12
         and coalesce(array_agg(ord order by ord) filter (where 判定 = 'OK'), '{}') = array[1,2,3,4,5,6,7,8,9,10,11,12] as ok,
         count(*) filter (where 判定 = 'OK') as n_ok,
         count(*) filter (where 判定 = 'NG') as n_ng
  from judged
)
select 判定, 項目, 結果, 期待
from (
  select 0 as grp, 0 as ord,
         case when t.ok then 'OK' else 'NG' end as 判定,
         case when (select j from raw) is null then '総合判定：確認結果が見つかりません（全文を1回で実行してください）'
              else '総合判定：必須12項目中 OK ' || t.n_ok || '・NG ' || t.n_ng
                   || case when not t.ok and t.n_ng = 0 then '（確認できなかった項目あり）' else '' end end as 項目,
         null as 結果, null as 期待
  from total t
  union all
  select case 判定 when 'NG' then 1 when 'OK' then 2 else 3 end, ord, 判定, 項目, 結果, 期待
  from judged
) t
order by grp, ord;
