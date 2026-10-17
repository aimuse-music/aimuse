-- AIMUSE v1.11（プレイリスト）を元に戻す（プレイリストの表と関数を削除。作られたプレイリストも消えます）
-- 他の表・関数・データには触れません
begin;
drop function if exists public.playlist_remove_track(uuid, uuid);
drop function if exists public.playlist_add_track(uuid, uuid);
drop function if exists public.delete_playlist(uuid);
drop function if exists public.update_playlist(uuid, text, boolean);
drop function if exists public.create_playlist(text, boolean);
drop function if exists public.public_playlists(integer);
drop function if exists public.my_playlists();
drop function if exists aimuse_private.playlist_owned(uuid);
drop function if exists aimuse_private.playlist_name(text);
drop table if exists public.playlist_tracks;
drop table if exists public.playlists;
notify pgrst, 'reload schema';
commit;
