-- =====================================================================
-- AIMUSE 公開前の事前確認（読み取り専用。何も変更しません）
-- 本番の SQL Editor で、v1.6 を実行する「前」に1回、各段階の SQL の「後」にも実行して結果を比べます。
-- 「結果」列に「要確認」があれば、SQL を実行せずに止めて、運営者が確認してください。
-- 「件数」の行（番号20〜）は、各段階の前後で変わらないことを確認するための記録です（スクリーンショットで保存）。
-- =====================================================================
with newfn(name) as (values ('artist_name_key'),('artist_name_clean'),('set_my_profile_image'),('rename_my_artist'),('public_artist_profiles'),('admin_reset_profile_image'),('admin_set_artist_name'),('admin_artist_name_history'),('avatar_can_upload'),('avatar_can_delete'),('is_visible_member'),('is_public_artist'),('public_artist_of_user'),('public_artist_follow_summary'),('public_artist_followers'),('public_artist_following'),('my_following'),('set_my_theme'),('delete_my_track'),('account_request_deletion'),('account_reauth_allowed'),('account_reauth_failed'),('cancel_my_account_deletion'),('my_account_deletion'),('account_purge_claim'),('account_purge_pending_files'),('account_purge_mark_files'),('account_purge_db'),('account_purge_finish'),('account_purge_fail')),
checks(no, item, ok, detail) as (
  select 1, '構築SQL（v1.5）の表と関数がある',
    to_regclass('public.tracks') is not null and to_regclass('aimuse_private.track_deletions') is not null
    and to_regprocedure('public.is_admin()') is not null and to_regprocedure('public.is_active_member()') is not null,
    null
  union all
  select 2, '保存場所の表に owner_id 列がある（v1.6 の画像ルールで使用）',
    exists (select 1 from information_schema.columns where table_schema = 'storage' and table_name = 'objects' and column_name = 'owner_id'),
    null
  union all
  select 3, '追加する関数と同じ名前の関数が、まだ無い（初回のみ OK。2回目以降は「適用済み」と表示）',
    true,
    coalesce((select '適用済み/既存: ' || string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')', ', ' order by p.proname)
              from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname in (select name from newfn)), 'なし（未適用）')
  union all
  select 4, '保存場所 avatars がまだ無い、または v1.6 と同じ設定（公開・2MB）',
    not exists (select 1 from storage.buckets where id = 'avatars')
    or exists (select 1 from storage.buckets where id = 'avatars' and public and file_size_limit = 2097152),
    coalesce((select '既存: ' || case when public then '公開' else '非公開' end || ' / ' || coalesce(file_size_limit::text, '上限なし')
              from storage.buckets where id = 'avatars'), 'なし（v1.6 で作成）')
  union all
  select 5, '音源・ジャケットの保存場所は非公開',
    (select count(*) from storage.buckets where id in ('audio', 'covers') and not public) = 2, null
  union all
  select 6, '非公開の設定置き場（aimuse_private）がアプリから見えない',
    not has_schema_privilege('anon', 'aimuse_private', 'USAGE') and not has_schema_privilege('authenticated', 'aimuse_private', 'USAGE'), null
  union all
  select 7, '全会員にプロフィールがある',
    not exists (select 1 from auth.users u left join public.profiles p on p.id = u.id where p.id is null), null
  union all
  select 8, '管理者は1人',
    (select count(*) from public.profiles where is_admin) = 1,
    (select count(*)::text || '人' from public.profiles where is_admin)
  union all
  select 9, '（参考）定期実行・外部呼び出しの拡張機能（第6段階以降の Cron で使用。無くても今は問題なし）',
    true,
    coalesce((select string_agg(extname, ', ') from pg_extension where extname in ('pg_cron', 'pg_net')), '未有効')
  union all
  select 20, '件数：会員 / プロフィール / 管理者 / 利用停止', true,
    (select count(*) from auth.users) || ' / ' || (select count(*) from public.profiles) || ' / ' ||
    (select count(*) from public.profiles where is_admin) || ' / ' || (select count(*) from public.profiles where is_banned)
  union all
  select 21, '件数：曲（公開 / 審査待ち / 非公開 / 却下）', true,
    (select count(*) from public.tracks where status = 'public') || ' / ' || (select count(*) from public.tracks where status = 'pending') || ' / ' ||
    (select count(*) from public.tracks where status = 'hidden') || ' / ' || (select count(*) from public.tracks where status = 'rejected')
  union all
  select 22, '件数：アーティスト / お気に入り / フォロー / レビュー / 通報', true,
    (select count(*) from public.artists) || ' / ' || (select count(*) from public.favorites) || ' / ' || (select count(*) from public.follows) || ' / ' ||
    (select count(*) from public.reviews) || ' / ' || (select count(*) from public.reports)
  union all
  select 23, '件数：ファイル（音源 / ジャケット / アイコン・背景）・削除記録', true,
    (select count(*) from storage.objects where bucket_id = 'audio') || ' / ' || (select count(*) from storage.objects where bucket_id = 'covers') || ' / ' ||
    (select count(*) from storage.objects where bucket_id = 'avatars') || ' ・ ' || (select count(*) from aimuse_private.track_deletions)
  union all
  select 24, '件数：再生数の合計', true, (select coalesce(sum(plays), 0)::text from public.tracks)
)
select no as "番号", item as "確認項目", case when ok then 'OK' else '要確認' end as "結果", coalesce(detail, '') as "詳細"
from checks order by no;
