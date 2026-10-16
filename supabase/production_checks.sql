-- =====================================================================
-- AIMUSE 本番環境チェック r5（読み取り専用。何も変更しません）
-- 構築SQL（v1.5）・プロフィール編集SQL（v1.6）・フォロー一覧SQL（v1.7）を実行した後に、SQL Editor で実行してください。
-- 結果は23行。「結果」列がすべて OK なら正常です。
-- r5：v1.7（フォロワー・フォロー中一覧）の関数7個・索引2個（確認23）を追加
-- r4：v1.6（プロフィール編集）の関数10個・avatars のルール4件・確認3項目（20〜22）を追加
-- r3：チェック7・8は AIMUSE の28関数だけを対象にしました
--     （Supabase標準の rls_auto_enable などは対象外。19番に参考表示します）
-- =====================================================================
with aimuse_fn(name) as (
  values ('is_reserved_name'),('is_admin'),('is_active_member'),('handle_new_user'),
         ('protect_profile_flags'),('tracks_before_insert'),('tracks_before_update'),
         ('tracks_before_delete'),('artist_follower_count'),('reviews_touch'),
         ('track_reviews'),('track_rating_summary'),('reports_before_insert'),
         ('request_viewer_key'),('increment_plays'),('set_duration_if_missing'),
         ('admin_stats'),('admin_list_members'),('admin_set_member_ban'),
         ('admin_orphan_files'),('admin_list_deleted_tracks'),('admin_restore_track'),
         ('admin_check_request_headers'),('can_read_media'),('media_path_in_use'),
         ('media_track_id_taken'),('storage_can_upload'),('storage_can_delete'),
         -- v1.6 プロフィール編集
         ('artist_name_key'),('artist_name_clean'),('set_my_profile_image'),('rename_my_artist'),
         ('public_artist_profiles'),('admin_reset_profile_image'),('admin_set_artist_name'),
         ('admin_artist_name_history'),('avatar_can_upload'),('avatar_can_delete'),
         -- v1.7 フォロワー・フォロー中一覧
         ('is_visible_member'),('is_public_artist'),('public_artist_of_user'),('public_artist_follow_summary'),
         ('public_artist_followers'),('public_artist_following'),('my_following')
),
pubfn as (
  select p.oid, p.proname::text as name, p.prosecdef, p.proconfig
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
),
checks(no, item, ok, detail) as (
  select 1, '音源・画像バケットが非公開',
    (select count(*) from storage.buckets where id in ('audio','covers') and public = false) = 2,
    (select string_agg(id || '=' || case when public then '公開' else '非公開' end, ', ') from storage.buckets where id in ('audio','covers'))
  union all
  select 2, 'バケットのサイズ上限（音源50MB・画像15MB）',
    (select count(*) from storage.buckets where (id = 'audio' and file_size_limit = 52428800) or (id = 'covers' and file_size_limit = 15728640)) = 2,
    null
  union all
  select 3, 'AIMUSEの全テーブルでRLSが有効',
    not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
                  and c.relname in ('profiles','artists','tracks','favorites','follows','reviews','reports','play_events')),
    (select count(*)::text || '/8' from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and c.relname in ('profiles','artists','tracks','favorites','follows','reviews','reports','play_events'))
  union all
  select 4, 'テーブルのアクセスルール数（23件）',
    (select count(*) from pg_policies where schemaname = 'public'
       and tablename in ('profiles','artists','tracks','favorites','follows','reviews','reports')) = 23,
    (select count(*)::text from pg_policies where schemaname = 'public'
       and tablename in ('profiles','artists','tracks','favorites','follows','reviews','reports'))
  union all
  select 5, 'Storageのアクセスルール（8件）',
    (select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects'
       and policyname in ('aimuse upload own folder','aimuse read media','aimuse delete own or admin','aimuse internal read',
                          'aimuse avatars upload own','aimuse avatars select own','aimuse avatars delete own',
                          'aimuse avatars internal read')) = 8,
    (select string_agg(policyname, ', ') from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'aimuse%')
  union all
  select 6, 'Storageに上書き用・旧ルールが残っていない',
    not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                and policyname in ('aimuse select own or admin','aimuse update own')),
    null
  union all
  select 7, 'AIMUSEの関数45個がそろい、権限の強い関数は search_path 固定',
    (select count(*) from pubfn where name in (select name from aimuse_fn)) = 45
    and not exists (select 1 from pubfn
                    where name in (select name from aimuse_fn) and prosecdef
                      and not coalesce(proconfig @> array['search_path=""'], false)),
    (select count(*)::text || '/45個' from pubfn where name in (select name from aimuse_fn))
      || coalesce(' 要確認:' || (select string_agg(name, ', ') from pubfn
                                 where name in (select name from aimuse_fn) and prosecdef
                                   and not coalesce(proconfig @> array['search_path=""'], false)), '')
  union all
  select 8, 'AIMUSEの関数のうち未ログインで実行できるのは11個だけ',
    (select array_agg(name order by name) from pubfn
     where name in (select name from aimuse_fn) and has_function_privilege('anon', oid, 'execute'))
    = array['artist_follower_count','can_read_media','increment_plays','is_active_member','is_admin',
            'public_artist_follow_summary','public_artist_followers','public_artist_following',
            'public_artist_profiles','track_rating_summary','track_reviews'],
    (select count(*)::text || '個' from pubfn
     where name in (select name from aimuse_fn) and has_function_privilege('anon', oid, 'execute'))
  union all
  select 9, '会員が管理者・利用停止フラグ・画像の保存場所を直接書き換えられない',
    not has_column_privilege('authenticated', 'public.profiles', 'is_admin', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.profiles', 'is_banned', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.profiles', 'avatar_path', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.profiles', 'header_path', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
    null
  union all
  select 10, '未ログインでは書き込み権限なし',
    not has_table_privilege('anon', 'public.tracks', 'INSERT')
    and not has_table_privilege('anon', 'public.tracks', 'UPDATE')
    and not has_table_privilege('anon', 'public.reports', 'INSERT')
    and not has_table_privilege('anon', 'public.reviews', 'INSERT'),
    null
  union all
  select 11, '再生記録・非公開設定にアプリから触れない',
    not has_table_privilege('anon', 'public.play_events', 'SELECT')
    and not has_table_privilege('authenticated', 'public.play_events', 'SELECT')
    and not has_schema_privilege('anon', 'aimuse_private', 'USAGE')
    and not has_schema_privilege('authenticated', 'aimuse_private', 'USAGE'),
    null
  union all
  select 12, '新規登録時のプロフィール自動作成が有効',
    exists (select 1 from pg_trigger where tgname = 'on_auth_user_created' and not tgisinternal),
    null
  union all
  select 13, '全会員にプロフィールがある',
    not exists (select 1 from auth.users u left join public.profiles p on p.id = u.id where p.id is null),
    (select count(*)::text || '人' from auth.users)
  union all
  select 14, '管理者の人数（最初は0人、設定後は1人）',
    (select count(*) from public.profiles where is_admin) <= 1,
    (select count(*)::text || '人' from public.profiles where is_admin)
  union all
  select 16, 'アプリ（未ログイン・会員）がAPI経由でデータを読める状態',
    has_schema_privilege('anon', 'public', 'USAGE') and has_schema_privilege('authenticated', 'public', 'USAGE')
    and has_table_privilege('anon', 'public.tracks', 'SELECT'),
    null
  union all
  select 17, '公開中の曲は削除できない保護・削除記録が有効',
    exists (select 1 from pg_trigger where tgname = 'tracks_before_delete' and not tgisinternal)
    and to_regclass('aimuse_private.track_deletions') is not null,
    null
  union all
  select 18, 'r2：削除後30日間は投稿者が音源・画像を消せない保護が有効',
    to_regprocedure('public.media_track_id_taken(text)') is not null
    and not has_function_privilege('anon', 'public.media_track_id_taken(text)', 'execute')
    and not has_function_privilege('authenticated', 'public.media_track_id_taken(text)', 'execute'),
    null
  union all
  select 19, '（参考）AIMUSE以外の関数（Supabase標準など・判定対象外）',
    true,
    coalesce((select string_agg(name || case when pg_get_function_result(oid) = 'event_trigger'
                                             then '（イベントトリガー用）' else '' end, ', ' order by name)
              from pubfn where name not in (select name from aimuse_fn)), 'なし')
  union all
  select 20, 'v1.6：アイコン用の保存場所 avatars（公開・2MB・JPEG/PNG/WebPのみ）',
    exists (select 1 from storage.buckets where id = 'avatars' and public = true and file_size_limit = 2097152
            and allowed_mime_types @> array['image/jpeg','image/png','image/webp']
            and array_length(allowed_mime_types, 1) = 3),
    (select case when public then '公開' else '非公開' end || ' / ' || coalesce(file_size_limit::text, '上限なし') || 'バイト'
     from storage.buckets where id = 'avatars')
  union all
  select 21, 'v1.6：画像の保存場所は本人のフォルダのみ（形式チェックが有効）',
    (select count(*) from pg_constraint where conrelid = 'public.profiles'::regclass
       and conname in ('profiles_avatar_path_chk','profiles_header_path_chk')) = 2,
    null
  union all
  select 22, 'v1.6：アーティスト名の変更履歴がアプリから直接見えない場所にある',
    to_regclass('aimuse_private.artist_name_history') is not null
    and not has_schema_privilege('anon', 'aimuse_private', 'USAGE')
    and not has_schema_privilege('authenticated', 'aimuse_private', 'USAGE'),
    (select count(*)::text || '件' from aimuse_private.artist_name_history)
  union all
  select 23, 'v1.7：フォロー一覧用の索引（大人数のページ分割用）',
    to_regclass('public.follows_artist_created_idx') is not null and to_regclass('public.follows_user_created_idx') is not null,
    null
  union all
  select 15, '（参考）現在のデータ件数',
    true,
    '楽曲 ' || (select count(*) from public.tracks) || '曲 / レビュー ' || (select count(*) from public.reviews) || '件'
)
select no as "番号", item as "確認項目", case when ok then 'OK' else '要確認' end as "結果", coalesce(detail, '') as "詳細"
from checks
order by no;
