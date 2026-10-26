-- =====================================================================
-- 本番データの書き出し（読み取り専用。何も変更しません）
--   SQL Editor で実行 → 結果の右上「Export」→「Download CSV」で iPhone の「ファイル」に保存します
--   1行が1つの表です（表の名前・件数・中身（JSON））。結果をチャットに貼り付けないでください（個人情報を含みます）
--   含まないもの：パスワード（認証サービスが管理）、秘密の値（再生数・解析用の salt）、音源・画像ファイル本体（Storage）
-- =====================================================================
select 'auth.users（会員のログイン情報：パスワードを除く）' as "表", count(*) as "件数",
       coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'email', u.email, 'created_at', u.created_at,
         'email_confirmed_at', u.email_confirmed_at, 'last_sign_in_at', u.last_sign_in_at,
         'raw_user_meta_data', u.raw_user_meta_data) order by u.created_at), '[]'::jsonb)::text as "中身"
from auth.users u
union all select 'public.profiles（会員プロフィール）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.profiles x
union all select 'public.artists（アーティスト）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.artists x
union all select 'public.tracks（楽曲）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.tracks x
union all select 'public.track_lyrics_sync（歌詞の同期）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.track_lyrics_sync x
union all select 'public.favorites（お気に入り）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.favorites x
union all select 'public.follows（フォロー）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.follows x
union all select 'public.playlists（プレイリスト）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.playlists x
union all select 'public.playlist_tracks（プレイリストの曲）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.playlist_tracks x
union all select 'public.reviews（レビュー）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.reviews x
union all select 'public.reports（通報）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.reports x
union all select 'public.play_events（再生記録・2日分）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from public.play_events x
union all select 'aimuse_private.artist_name_history（名義変更の履歴）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from aimuse_private.artist_name_history x
union all select 'aimuse_private.track_deletions（削除した曲・30日間復元用）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from aimuse_private.track_deletions x
union all select 'aimuse_private.account_deletions（退会の手続き）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from aimuse_private.account_deletions x
union all select 'aimuse_private.lyrics_align_jobs（歌詞の自動同期の状況）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from aimuse_private.lyrics_align_jobs x
union all select 'aimuse_private.lyrics_align_settings（歌詞の自動同期の設定）', count(*), coalesce(jsonb_agg(to_jsonb(x)), '[]')::text from aimuse_private.lyrics_align_settings x
union all select 'aimuse_private.settings（設定：秘密の値は伏せる）', count(*),
       coalesce(jsonb_agg(jsonb_build_object('key', x.key, 'value', case when x.key like '%salt%' then '（伏せています）' else x.value end, 'updated_at', x.updated_at)), '[]')::text
from aimuse_private.settings x
union all select 'storage.objects（音源・画像ファイルの一覧。ファイル本体は含まない）', count(*),
       coalesce(jsonb_agg(jsonb_build_object('bucket_id', x.bucket_id, 'name', x.name, 'created_at', x.created_at)), '[]')::text
from storage.objects x;
