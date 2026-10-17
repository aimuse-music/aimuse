-- =====================================================================
-- AIMUSE 段階0-2：関数の「相違（中身）」の原因を切り分ける確認（読み取り専用。何も変更しません）
-- ・この SQL は1つの SELECT 文だけです。作成・変更・削除・データの追加は一切含みません
-- ・関数の本文そのものは出力しません（文字数・行数・指紋（md5）が一致するかの判定だけ）
-- ・期待値は GitHub main の構築SQL（aimuse_schema.sql v1.5）を、そのままの文字で実行したときの値です
-- ・判定の意味（上から順に判定）
--     一致 …………………………………… 構築SQLと1文字も違わない
--     改行コードだけ違う ……………… 改行が CRLF になっているだけ（処理は同じ）
--     空白・字下げだけ違う ………… スペース・タブ・改行の数だけが違う（処理は同じ）
--     コメントと空白だけ違う ……… 「--」で始まる説明書きと空白だけが違う（処理は同じ）
--     処理の中身が違う（要確認）… 上のどれでもない。構築SQLと別の内容です
-- =====================================================================
with
exp(name, raw_md5, ws_md5, nocmt_md5, lang, secdef, lines, chars, config, args, result) as (values
    ('admin_check_request_headers', '4f64dfc96f091379e2695ef53d1fc02e', '007da57dbf7fcba36f9b1ac30fb098ba', '007da57dbf7fcba36f9b1ac30fb098ba', 'plpgsql', true, 20, 665, 'search_path=""', '', 'json'),
    ('admin_list_deleted_tracks', 'dd04d1426106bb0b3f10e4b3a63337e3', '5069ebb35f68178207c9967eee4b9294', '5069ebb35f68178207c9967eee4b9294', 'plpgsql', true, 14, 599, 'search_path=""', '', 'TABLE(deletion_id uuid, track_id uuid, title text, artist text, status_before text, review_count integer, report_count integer, deleted_at timestamp with time zone, audio_file_exists boolean, restored_at timestamp with time zone)'),
    ('admin_list_members', '09ad6c5ecbf2567b80bfd1035762103d', '58bcecea211a2d299e02dae1d19d75b7', '58bcecea211a2d299e02dae1d19d75b7', 'plpgsql', true, 15, 510, 'search_path=""', 'p_limit integer, p_offset integer', 'TABLE(id uuid, email text, display_name text, is_admin boolean, is_banned boolean, email_confirmed boolean, created_at timestamp with time zone, track_count bigint)'),
    ('admin_orphan_files', '20e2023ac894a2511874215f88b1f352', '48e8514bd56f3e3620cb70e66771afdb', 'c3d1cdf638cb8a151d82f16cfb118275', 'plpgsql', true, 26, 940, 'search_path=""', 'p_min_age_hours integer', 'TABLE(bucket_id text, name text, created_at timestamp with time zone)'),
    ('admin_restore_track', '2f1d116127d904f93221823a3d8d1b3c', '55426cebbab4dad160351587fcf9d5dd', '55426cebbab4dad160351587fcf9d5dd', 'plpgsql', true, 40, 1656, 'search_path=""', 'p_deletion_id uuid', 'uuid'),
    ('admin_set_member_ban', 'e5e43c0c8c6352e9c96559b66691dcb4', 'a3462a5e67e70de8ea3d3f2fd73a03c2', 'a3462a5e67e70de8ea3d3f2fd73a03c2', 'plpgsql', true, 19, 533, 'search_path=""', 'p_user uuid, p_banned boolean', 'void'),
    ('admin_stats', '43bf55ad334a1755f7f90c3c1962441a', '7bc3d222d4c3c8adca21bee9ea2a5367', '7bc3d222d4c3c8adca21bee9ea2a5367', 'plpgsql', true, 20, 1028, 'search_path=""', '', 'json'),
    ('artist_follower_count', '9c44e9a308e7917425ff5eeb567f8a00', 'e91f37ac8a5dfb36e9afd00eaf994fbc', 'e91f37ac8a5dfb36e9afd00eaf994fbc', 'sql', true, 2, 75, 'search_path=""', 'aid uuid', 'integer'),
    ('can_read_media', '286b81b1cfa5d804f742aa9bf3a3c99c', '3f3d5ad3ca1fd2490ba8c41175a50499', '3f3d5ad3ca1fd2490ba8c41175a50499', 'sql', true, 10, 338, 'search_path=""', 'bucket text, object_name text', 'boolean'),
    ('handle_new_user', '8aedc947b1d3d03c6a7b54ff13054036', '30bb2fde5cfda100b9ca07a9c3d8873e', '30bb2fde5cfda100b9ca07a9c3d8873e', 'plpgsql', true, 13, 384, 'search_path=""', '', 'trigger'),
    ('increment_plays', 'c1cfe5e0ece2151082a8fe376516be8e', 'b5ca28b5e77d9faca0b14aaa675af703', '92fa1b42d94c7e33504ad5e23b90ec9a', 'plpgsql', true, 31, 896, 'search_path=""', 'tid uuid', 'void'),
    ('is_active_member', '3d72ba2c229a7a6a4076f6172c06aebf', '1721ea9088a169d2cb4451faf133ac2f', '1721ea9088a169d2cb4451faf133ac2f', 'sql', true, 5, 254, 'search_path=""', '', 'boolean'),
    ('is_admin', 'af565933219366fb8c1866de13bc2da8', '065dbcd2c17f6a4da4ba7cc6b24dad9e', '065dbcd2c17f6a4da4ba7cc6b24dad9e', 'sql', true, 2, 95, 'search_path=""', '', 'boolean'),
    ('is_reserved_name', 'cad9354ad0e87f02b831fc08b3d5463f', 'd82d99f9cab19f0af1ba666e0a624300', 'd82d99f9cab19f0af1ba666e0a624300', 'sql', false, 2, 94, 'search_path=""', 'n text', 'boolean'),
    ('media_path_in_use', '391905046775ba9470ed12ec3eafc15e', 'a1cb160dc793a104003d5a9b9a4b0c9b', 'a1cb160dc793a104003d5a9b9a4b0c9b', 'sql', true, 13, 476, 'search_path=""', 'bucket text, object_name text', 'boolean'),
    ('media_track_id_taken', '99aa28eb8c56ebf2c75af1b734c11182', '107fcaedf5a6b6fe497c68904e3b7853', '107fcaedf5a6b6fe497c68904e3b7853', 'sql', true, 11, 367, 'search_path=""', 'object_name text', 'boolean'),
    ('protect_profile_flags', '15372fe9d197b7c77cc1c9779fa72c69', 'fa40e1325abb252e0ed071bcdc6a5106', 'fa40e1325abb252e0ed071bcdc6a5106', 'plpgsql', false, 20, 729, 'search_path=""', '', 'trigger'),
    ('reports_before_insert', '788bbccc79d117ab9309de3d13dc1cbd', 'fee64887b6e09a9bbd32e5acd4206e32', 'fee64887b6e09a9bbd32e5acd4206e32', 'plpgsql', true, 23, 853, 'search_path=""', '', 'trigger'),
    ('request_viewer_key', 'fece3f368259d9c5bcead5c27446b98f', 'd883e07909f64d01f6d0234cb7b8920c', 'd883e07909f64d01f6d0234cb7b8920c', 'plpgsql', true, 32, 953, 'search_path=""', '', 'text'),
    ('reviews_touch', '6b7a27b594510284b8179a1f824b3c6d', '749b77b1f134b2d2aff8bf755cb04583', '749b77b1f134b2d2aff8bf755cb04583', 'plpgsql', false, 8, 204, 'search_path=""', '', 'trigger'),
    ('set_duration_if_missing', '36f6a61bb181781cde47c8ddc70eaa41', '6aeb32c3479a4de608fa085c95c2a7e3', '6aeb32c3479a4de608fa085c95c2a7e3', 'sql', true, 7, 232, 'search_path=""', 'tid uuid, d integer', 'void'),
    ('storage_can_delete', '43649020f8317321ef834a74318ccf83', 'fdb2f6651d236012fd53a7c5b7993ddc', 'fdb2f6651d236012fd53a7c5b7993ddc', 'sql', true, 5, 189, 'search_path=""', 'bucket text, object_name text', 'boolean'),
    ('storage_can_upload', '00b2af579083a03ec0c1adddd61324a4', '1723dafffba0efaefec35cbf7320414d', '1723dafffba0efaefec35cbf7320414d', 'sql', true, 7, 319, 'search_path=""', 'bucket text, object_name text', 'boolean'),
    ('track_rating_summary', '217f556114006b2ed5a9402791450f9b', '70b79ff8bcc32921bfd8449bae041a83', '70b79ff8bcc32921bfd8449bae041a83', 'sql', true, 6, 267, 'search_path=""', 'tid uuid', 'TABLE(average numeric, total integer)'),
    ('track_reviews', '137f2e2bedc8c331ef95814e0b92800e', 'ff65ce825f1a45913720c7e06173c0ac', 'ff65ce825f1a45913720c7e06173c0ac', 'sql', true, 12, 470, 'search_path=""', 'tid uuid', 'TABLE(id uuid, rating smallint, comment text, created_at timestamp with time zone, updated_at timestamp with time zone, reviewer_name text, is_mine boolean)'),
    ('tracks_before_delete', '9b4828527940e4de0e5a49acda59cf1b', 'ce5e5d8232a004d04bd0dc6e03306b7d', 'ce5e5d8232a004d04bd0dc6e03306b7d', 'plpgsql', true, 16, 578, 'search_path=""', '', 'trigger'),
    ('tracks_before_insert', '3fd4252b9ed5c9f369f56af72cf2b3cc', '1f5ed15529c86f4423fe247636bcca42', 'd9bead6981e166c0250b117089d8b755', 'plpgsql', true, 36, 1223, 'search_path=""', '', 'trigger'),
    ('tracks_before_update', '48ac2df9c0cd0a063be91c7c9082a88c', '8c579e332c7564aa36a6c2ede6528cec', '8c579e332c7564aa36a6c2ede6528cec', 'plpgsql', false, 11, 357, 'search_path=""', '', 'trigger')
),
re as (select '[[:space:]' || chr(160) || chr(12288) || chr(8203) || chr(65279) || ']+' as ws,
              '--[^' || chr(10) || chr(13) || ']*' as cmt),
act as (
  select p.proname::text as name, p.prosrc as s, l.lanname::text as lang, p.prosecdef as secdef,
         coalesce(array_to_string(p.proconfig, ','), '') as config,
         pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_language l on l.oid = p.prolang
  where n.nspname = 'public'),
cmp as (
  select e.name, a.name is not null as found,
         md5(a.s) = e.raw_md5 as raw_ok,
         md5(replace(a.s, chr(13), '')) = e.raw_md5 as crlf_ok,
         md5(btrim(regexp_replace(a.s, re.ws, ' ', 'g'))) = e.ws_md5 as ws_ok,
         md5(btrim(regexp_replace(regexp_replace(a.s, re.cmt, '', 'g'), re.ws, ' ', 'g'))) = e.nocmt_md5 as nocmt_ok,
         e.lines as exp_lines, length(a.s) - length(replace(a.s, chr(10), '')) as act_lines,
         e.chars as exp_chars, length(a.s) as act_chars,
         length(a.s) - length(replace(a.s, chr(13), '')) as cr,
         length(a.s) - length(replace(a.s, chr(9), '')) as tabs,
         length(a.s) - length(translate(a.s, chr(160) || chr(12288) || chr(8203) || chr(65279), '')) as odd_spaces,
         left(a.s, 1) = chr(10) as lead_nl, right(replace(a.s, chr(13), ''), 1) = chr(10) as trail_nl,
         a.lang = e.lang as lang_ok, a.secdef = e.secdef as secdef_ok, a.config = e.config as config_ok,
         a.args = e.args as args_ok, a.result = e.result as result_ok
  from exp e cross join re left join act a on a.name = e.name),
judged as (
  select *, case when not found then '関数が無い'
                 when raw_ok then '一致'
                 when crlf_ok then '改行コードだけ違う'
                 when ws_ok then '空白・字下げだけ違う'
                 when nocmt_ok then 'コメントと空白だけ違う'
                 else '処理の中身が違う（要確認）' end as verdict
  from cmp),
rows(sec, no, item, verdict, detail, setting) as (
  -- 1. まとめ（判定ごとの件数）
  select '1 まとめ', 1, verdict, count(*)::text || ' 件', '', ''
  from judged group by verdict
  union all
  select '1 まとめ', 2, '権限の強さ・search_path・引数・戻り値・言語のどれかが違う関数',
         case when count(*) filter (where found and not (lang_ok and secdef_ok and config_ok and args_ok and result_ok)) = 0 then 'OK' else '要確認' end,
         count(*) filter (where found and not (lang_ok and secdef_ok and config_ok and args_ok and result_ok))::text || ' 件', ''
  from judged
  union all
  select '1 まとめ', 3, '同じ名前の関数が2つ以上ある（重複）',
         case when count(*) = 0 then 'OK' else '要確認' end,
         coalesce(string_agg(name || '×' || c, ', '), 'なし'), ''
  from (select name, count(*) c from act where name in (select name from exp) group by name having count(*) > 1) d
  -- 2. 関数ごとの判定（本文は出しません）
  union all
  select '2 関数', 4, name, verdict,
         case when not found then '' else
           '行 ' || exp_lines || '/' || act_lines || ' ・ 文字 ' || exp_chars || '/' || act_chars ||
           ' ・ CR ' || cr || ' ・ タブ ' || tabs || ' ・ 特殊な空白 ' || odd_spaces ||
           ' ・ 先頭改行 ' || case when lead_nl then '有' else '無' end || ' ・ 末尾改行 ' || case when trail_nl then '有' else '無' end end,
         case when not found then '' else
           'SECURITY DEFINER ' || case when secdef_ok then '一致' else '相違' end ||
           ' ・ search_path ' || case when config_ok then '一致' else '相違' end ||
           ' ・ 引数 ' || case when args_ok then '一致' else '相違' end ||
           ' ・ 戻り値 ' || case when result_ok then '一致' else '相違' end ||
           ' ・ 言語 ' || case when lang_ok then '一致' else '相違' end end
  from judged
)
select sec as "区分", item as "項目", verdict as "判定", detail as "詳細（期待/実際）", setting as "設定"
from rows order by no, item;
