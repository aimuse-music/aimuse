-- 本番に近いデータ（v1.5 の状態）：会員300人・曲1200曲（全状態）・お気に入り・フォロー・レビュー・通報・再生記録・ファイル・削除記録
insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
select ('10000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, 'user' || i || '@example.com',
       case when i % 17 = 0 then null else now() - (i || ' hours')::interval end,
       jsonb_build_object('display_name', '会員' || i)
from generate_series(1, 300) i;
update public.profiles set is_admin = true where id = '10000000-0000-4000-8000-000000000001';
update public.profiles set is_banned = true where id in (select ('10000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid from generate_series(50, 300, 50) i);
insert into public.tracks (id, user_id, title, artist, genre, tool, tool_name, audio_path, image_path, status, plays, created_at)
select t.id, t.uid, '曲' || t.i, 'アーティスト' || (t.i % 120), 'J-POP', 'Suno', 'Suno',
       t.uid::text || '/' || t.id || '.mp3', case when t.i % 3 = 0 then t.uid::text || '/' || t.id || '.jpg' end,
       (array['public','public','public','pending','hidden','rejected'])[1 + t.i % 6], t.i * 7, now() - (t.i || ' minutes')::interval
from (select i, ('20000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as id,
             ('10000000-0000-4000-8000-' || lpad((1 + i % 120)::text, 12, '0'))::uuid as uid
      from generate_series(1, 1200) i) t;
insert into storage.objects (bucket_id, name, owner_id)
select 'audio', audio_path, user_id::text from public.tracks
union all select 'covers', image_path, user_id::text from public.tracks where image_path is not null;
insert into public.favorites (user_id, track_id)
select ('10000000-0000-4000-8000-' || lpad((1 + (i * 7) % 300)::text, 12, '0'))::uuid, t.id
from generate_series(1, 3000) i join lateral (select id from public.tracks where status = 'public' order by id offset (i * 13) % 600 limit 1) t on true
on conflict do nothing;
insert into public.follows (user_id, artist_id, created_at)
select ('10000000-0000-4000-8000-' || lpad((1 + (i * 11) % 300)::text, 12, '0'))::uuid, a.id, now() - (i || ' minutes')::interval
from generate_series(1, 2000) i join lateral (select id from public.artists order by id offset (i * 5) % 120 limit 1) a on true
on conflict do nothing;
insert into public.reviews (track_id, user_id, rating, comment)
select t.id, ('10000000-0000-4000-8000-' || lpad((1 + (i * 3) % 300)::text, 12, '0'))::uuid, 1 + i % 5, 'レビュー' || i
from generate_series(1, 800) i join lateral (select id from public.tracks where status = 'public' order by id offset (i * 17) % 600 limit 1) t on true
on conflict do nothing;
insert into public.reports (song_id, reason, reporter_id)
select t.id, '理由' || i, ('10000000-0000-4000-8000-' || lpad((1 + (i * 19) % 300)::text, 12, '0'))::uuid
from generate_series(1, 120) i join lateral (select id from public.tracks order by id offset (i * 29) % 1200 limit 1) t on true;
insert into public.play_events (track_id, viewer_key, window_start)
select t.id, 'u:' || i, date_trunc('hour', now())
from generate_series(1, 500) i join lateral (select id from public.tracks where status = 'public' order by id offset i % 600 limit 1) t on true
on conflict do nothing;
-- 運営が削除した曲（30日の復元記録）
delete from public.tracks where id in (select id from public.tracks where status = 'hidden' order by id limit 10);
