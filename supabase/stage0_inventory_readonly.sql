-- =====================================================================
-- AIMUSE 段階0：本番の構造・関数・権限・RLS の確認（読み取り専用。何も変更しません）
-- ・この SQL は1つの SELECT 文だけです。表の作成・変更・削除、データの追加・変更・削除は一切含みません
-- ・使うのは PostgreSQL 標準の確認用の関数（to_regclass・has_table_privilege・md5 など）だけです
-- ・メールアドレス・表示名・会員ID・キーなどの個人情報や秘密の値は出力しません（件数と名前・判定だけ）
-- ・「期待」は GitHub の構築SQL（v1.5）から計算した値です。「相違」があれば、本番が構築SQLと違う状態です
-- 結果の「判定」列が「一致」「OK」以外の行は、スクリーンショットを送ってください
-- =====================================================================
with
exp_fn(name, src_md5, secdef, config) as (values
    ('admin_check_request_headers','4f64dfc96f091379e2695ef53d1fc02e',true,'search_path=""'),
    ('admin_list_deleted_tracks','dd04d1426106bb0b3f10e4b3a63337e3',true,'search_path=""'),
    ('admin_list_members','09ad6c5ecbf2567b80bfd1035762103d',true,'search_path=""'),
    ('admin_orphan_files','20e2023ac894a2511874215f88b1f352',true,'search_path=""'),
    ('admin_restore_track','2f1d116127d904f93221823a3d8d1b3c',true,'search_path=""'),
    ('admin_set_member_ban','e5e43c0c8c6352e9c96559b66691dcb4',true,'search_path=""'),
    ('admin_stats','43bf55ad334a1755f7f90c3c1962441a',true,'search_path=""'),
    ('artist_follower_count','9c44e9a308e7917425ff5eeb567f8a00',true,'search_path=""'),
    ('can_read_media','286b81b1cfa5d804f742aa9bf3a3c99c',true,'search_path=""'),
    ('handle_new_user','8aedc947b1d3d03c6a7b54ff13054036',true,'search_path=""'),
    ('increment_plays','c1cfe5e0ece2151082a8fe376516be8e',true,'search_path=""'),
    ('is_active_member','3d72ba2c229a7a6a4076f6172c06aebf',true,'search_path=""'),
    ('is_admin','af565933219366fb8c1866de13bc2da8',true,'search_path=""'),
    ('is_reserved_name','cad9354ad0e87f02b831fc08b3d5463f',false,'search_path=""'),
    ('media_path_in_use','391905046775ba9470ed12ec3eafc15e',true,'search_path=""'),
    ('media_track_id_taken','99aa28eb8c56ebf2c75af1b734c11182',true,'search_path=""'),
    ('protect_profile_flags','15372fe9d197b7c77cc1c9779fa72c69',false,'search_path=""'),
    ('reports_before_insert','788bbccc79d117ab9309de3d13dc1cbd',true,'search_path=""'),
    ('request_viewer_key','fece3f368259d9c5bcead5c27446b98f',true,'search_path=""'),
    ('reviews_touch','6b7a27b594510284b8179a1f824b3c6d',false,'search_path=""'),
    ('set_duration_if_missing','36f6a61bb181781cde47c8ddc70eaa41',true,'search_path=""'),
    ('storage_can_delete','43649020f8317321ef834a74318ccf83',true,'search_path=""'),
    ('storage_can_upload','00b2af579083a03ec0c1adddd61324a4',true,'search_path=""'),
    ('track_rating_summary','217f556114006b2ed5a9402791450f9b',true,'search_path=""'),
    ('track_reviews','137f2e2bedc8c331ef95814e0b92800e',true,'search_path=""'),
    ('tracks_before_delete','9b4828527940e4de0e5a49acda59cf1b',true,'search_path=""'),
    ('tracks_before_insert','3fd4252b9ed5c9f369f56af72cf2b3cc',true,'search_path=""'),
    ('tracks_before_update','48ac2df9c0cd0a063be91c7c9082a88c',false,'search_path=""')),
exp_pol(tbl, name, cmd, roles) as (values
    ('artists','artists_delete_admin','DELETE','authenticated'),
    ('artists','artists_select','SELECT','anon,authenticated'),
    ('artists','artists_update_own','UPDATE','authenticated'),
    ('favorites','favorites_delete_own','DELETE','authenticated'),
    ('favorites','favorites_insert_own','INSERT','authenticated'),
    ('favorites','favorites_select_own','SELECT','authenticated'),
    ('follows','follows_delete_own','DELETE','authenticated'),
    ('follows','follows_insert_own','INSERT','authenticated'),
    ('follows','follows_select_own','SELECT','authenticated'),
    ('objects','aimuse delete own or admin','DELETE','authenticated'),
    ('objects','aimuse internal read','SELECT','postgres'),
    ('objects','aimuse read media','SELECT','anon,authenticated'),
    ('objects','aimuse upload own folder','INSERT','authenticated'),
    ('profiles','profiles_select','SELECT','authenticated'),
    ('profiles','profiles_update_own','UPDATE','authenticated'),
    ('reports','reports_admin_delete','DELETE','authenticated'),
    ('reports','reports_admin_select','SELECT','authenticated'),
    ('reports','reports_admin_update','UPDATE','authenticated'),
    ('reports','reports_insert','INSERT','authenticated'),
    ('reviews','reviews_delete','DELETE','authenticated'),
    ('reviews','reviews_insert_own','INSERT','authenticated'),
    ('reviews','reviews_select','SELECT','anon,authenticated'),
    ('reviews','reviews_update_own','UPDATE','authenticated'),
    ('tracks','tracks_delete','DELETE','authenticated'),
    ('tracks','tracks_insert','INSERT','authenticated'),
    ('tracks','tracks_select','SELECT','anon,authenticated'),
    ('tracks','tracks_update_admin','UPDATE','authenticated')),
exp_trg(tbl, name) as (values
    ('profiles','profiles_protect_flags'),
    ('reports','reports_before_insert'),
    ('reviews','reviews_touch'),
    ('tracks','tracks_before_delete'),
    ('tracks','tracks_before_insert'),
    ('tracks','tracks_before_update'),
    ('users','on_auth_user_created')),
exp_grant(tbl, role, privs) as (values
    ('artists','anon','SELECT'),
    ('artists','authenticated','DELETE,SELECT'),
    ('favorites','authenticated','DELETE,INSERT,SELECT'),
    ('follows','authenticated','DELETE,INSERT,SELECT'),
    ('profiles','authenticated','SELECT'),
    ('reports','authenticated','DELETE,INSERT,SELECT,UPDATE'),
    ('reviews','anon','SELECT'),
    ('reviews','authenticated','DELETE,INSERT,SELECT'),
    ('tracks','anon','SELECT'),
    ('tracks','authenticated','DELETE,INSERT,SELECT,UPDATE')),
act_fn as (
  select p.proname::text as name, md5(p.prosrc) as src_md5, p.prosecdef as secdef, coalesce(array_to_string(p.proconfig, ','), '') as config,
         has_function_privilege('anon', p.oid, 'execute') as anon_exec
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
act_pol as (select tablename::text as tbl, policyname::text as name, cmd::text as cmd, array_to_string(roles, ',') as roles
            from pg_policies where (schemaname = 'public' and tablename in ('profiles','artists','tracks','favorites','follows','reviews','reports','play_events'))
               or (schemaname = 'storage' and tablename = 'objects' and policyname like 'aimuse%')),
act_trg as (select c.relname::text as tbl, t.tgname::text as name from pg_trigger t join pg_class c on c.oid = t.tgrelid
            join pg_namespace n on n.oid = c.relnamespace where not t.tgisinternal and n.nspname in ('public', 'auth')
              and c.relname in ('profiles','artists','tracks','favorites','follows','reviews','reports','users')),
act_grant as (select t, r, string_agg(p, ',' order by p) as privs
              from unnest(array['profiles','artists','tracks','favorites','follows','reviews','reports','play_events']) t,
                   unnest(array['anon','authenticated']) r, unnest(array['SELECT','INSERT','UPDATE','DELETE']) p
              where to_regclass('public.' || t) is not null and has_table_privilege(r, 'public.' || t, p) group by t, r),
rows(sec, no, item, verdict, detail) as (
  -- A. 関数（v1.5 の28個）：中身・権限の強さ・search_path の固定
  select 'A 関数', 1, e.name,
         case when a.name is null then '不足' when a.src_md5 <> e.src_md5 then '相違（中身）' when a.secdef <> e.secdef or a.config <> e.config then '相違（設定）' else '一致' end,
         case when a.name is null then 'この関数がありません' when a.src_md5 <> e.src_md5 then '構築SQLと中身が違います' else '' end
  from exp_fn e left join act_fn a on a.name = e.name
  union all
  select 'A 関数', 2, '（参考）構築SQLに無い public の関数', '参考',
         coalesce((select string_agg(a.name, ', ' order by a.name) from act_fn a where a.name not in (select name from exp_fn)), 'なし')
  -- B. RLS（行レベルセキュリティ）が有効か
  union all
  select 'B RLS', 3, t, case when c.relrowsecurity then 'OK' else '要確認' end, case when c.oid is null then '表がありません' else '' end
  from unnest(array['profiles','artists','tracks','favorites','follows','reviews','reports','play_events']) t
  left join pg_class c on c.oid = to_regclass('public.' || t)
  -- C. アクセスルール（名前・操作・対象）
  union all
  select 'C ルール', 4, e.tbl || ' / ' || e.name,
         case when a.name is null then '不足' when a.cmd <> e.cmd or a.roles <> e.roles then '相違' else '一致' end, ''
  from exp_pol e left join act_pol a on a.tbl = e.tbl and a.name = e.name
  union all
  select 'C ルール', 5, '（参考）構築SQLに無いルール', '参考',
         coalesce((select string_agg(a.tbl || '/' || a.name, ', ') from act_pol a where not exists (select 1 from exp_pol e where e.tbl = a.tbl and e.name = a.name)), 'なし')
  -- D. トリガー
  union all
  select 'D トリガー', 6, e.tbl || ' / ' || e.name, case when a.name is null then '不足' else '一致' end, ''
  from exp_trg e left join act_trg a on a.tbl = e.tbl and a.name = e.name
  union all
  select 'D トリガー', 7, '（参考）構築SQLに無いトリガー（BOOST などを含む）', '参考',
         coalesce((select string_agg(a.tbl || '/' || a.name, ', ') from act_trg a where not exists (select 1 from exp_trg e where e.tbl = a.tbl and e.name = a.name)), 'なし')
  -- E. 表の権限（未ログイン・会員）
  union all
  select 'E 権限', 8, coalesce(e.tbl, a.t) || ' / ' || coalesce(e.role, a.r),
         case when coalesce(e.privs, '') = coalesce(a.privs, '') then '一致' else '相違' end,
         '期待: ' || coalesce(e.privs, 'なし') || ' / 実際: ' || coalesce(a.privs, 'なし')
  from exp_grant e full join act_grant a on a.t = e.tbl and a.r = e.role
  union all
  select 'E 権限', 9, '未ログインで実行できる AIMUSE の関数', '参考',
         coalesce((select string_agg(name, ', ' order by name) from act_fn where anon_exec and name in (select name from exp_fn)), 'なし')
  -- F. 保存場所・非公開の場所・拡張機能
  union all
  select 'F 保存場所', 10, '音源・ジャケット（非公開・50MB/15MB）',
         case when (select count(*) from storage.buckets where (id = 'audio' and not public and file_size_limit = 52428800) or (id = 'covers' and not public and file_size_limit = 15728640)) = 2 then 'OK' else '要確認' end,
         coalesce((select string_agg(id || '=' || case when public then '公開' else '非公開' end, ', ' order by id) from storage.buckets), '')
  union all
  select 'F 保存場所', 11, 'aimuse_private（非公開の設定置き場）がアプリから見えない',
         case when not has_schema_privilege('anon', 'aimuse_private', 'USAGE') and not has_schema_privilege('authenticated', 'aimuse_private', 'USAGE') then 'OK' else '要確認' end, ''
  union all
  select 'F 保存場所', 12, '（参考）拡張機能・PostgreSQL の版', '参考',
         coalesce((select string_agg(extname || ' ' || extversion, ', ' order by extname) from pg_extension where extname in ('pg_cron', 'pg_net', 'supabase_vault')), 'なし') || ' / ' || current_setting('server_version')
  -- G. AIMUSE BOOST（存在の確認だけ。中身は読まない）
  union all
  select 'G BOOST', 13, 'BOOST の表', '参考',
         coalesce((select string_agg(c.relname, ', ' order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'boost%'), 'なし（BOOST の構築SQLは未実行）')
  union all
  select 'G BOOST', 14, 'BOOST の表から AIMUSE の表・会員への外部キー（あると削除処理が止まる）',
         case when exists (select 1 from pg_constraint k join pg_class c on c.oid = k.conrelid where k.contype = 'f' and c.relname like 'boost%'
                            and k.confrelid in (to_regclass('public.tracks'), to_regclass('public.profiles'), to_regclass('public.artists'), 'auth.users'::regclass)) then '要確認' else 'OK' end, ''
  -- H. 件数（個人情報は出さない）
  union all
  select 'H 件数', 15, '会員 / 管理者 / 利用停止', '参考',
         (select count(*) from auth.users) || ' / ' || (select count(*) from public.profiles where is_admin) || ' / ' || (select count(*) from public.profiles where is_banned)
  union all
  select 'H 件数', 16, '曲（公開 / 審査待ち / 非公開 / 却下）・ファイル', '参考',
         (select count(*) from public.tracks where status = 'public') || ' / ' || (select count(*) from public.tracks where status = 'pending') || ' / ' ||
         (select count(*) from public.tracks where status = 'hidden') || ' / ' || (select count(*) from public.tracks where status = 'rejected') || ' ・ ファイル ' ||
         (select count(*) from storage.objects where bucket_id in ('audio', 'covers'))
)
select sec as "区分", item as "項目", verdict as "判定", detail as "詳細" from rows order by no, item;
