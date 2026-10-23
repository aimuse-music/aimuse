-- AIMUSE v1.14 を元に戻す（歌詞の同期の表と関数を外す。楽曲・歌詞は変更しません。保存した同期の時刻は消えます）
begin;
drop function if exists public.lyrics_sync_save(uuid, jsonb);
drop function if exists public.lyrics_sync_get(uuid);
drop function if exists public.lyrics_is_heading(text);
drop function if exists public.lyrics_hash(text[]);
drop table if exists public.track_lyrics_sync;
commit;
