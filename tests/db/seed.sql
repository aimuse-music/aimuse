insert into auth.users (id,email,email_confirmed_at,raw_user_meta_data) values
 ('11111111-1111-4111-8111-111111111111','ryo@example.com',now(),'{"display_name":"NOCTERA Ryo"}'),
 ('22222222-2222-4222-8222-222222222222','hamu@example.com',now(),'{"display_name":"ハムハム"}');
update public.profiles set is_admin=true where id='11111111-1111-4111-8111-111111111111';
-- tracks inserted as SQL editor (postgres) → trigger keeps given status
insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path,status) values
 ('aaaaaaaa-0000-4000-8000-000000000001','11111111-1111-4111-8111-111111111111','おぼろ月','NOCTERA','J-POP','Suno','Suno','11111111-1111-4111-8111-111111111111/aaaaaaaa-0000-4000-8000-000000000001.mp3','public'),
 ('aaaaaaaa-0000-4000-8000-000000000002','11111111-1111-4111-8111-111111111111','審査待ちの曲','NOCTERA','J-POP','Suno','Suno','11111111-1111-4111-8111-111111111111/aaaaaaaa-0000-4000-8000-000000000002.mp3','pending'),
 ('aaaaaaaa-0000-4000-8000-000000000003','11111111-1111-4111-8111-111111111111','非公開の曲','NOCTERA','J-POP','Suno','Suno','11111111-1111-4111-8111-111111111111/aaaaaaaa-0000-4000-8000-000000000003.mp3','hidden'),
 ('aaaaaaaa-0000-4000-8000-000000000004','22222222-2222-4222-8222-222222222222','ハムの曲','ハムハム','J-POP','Suno','Suno','22222222-2222-4222-8222-222222222222/aaaaaaaa-0000-4000-8000-000000000004.mp3','pending');
insert into storage.objects (bucket_id,name) values
 ('audio','11111111-1111-4111-8111-111111111111/aaaaaaaa-0000-4000-8000-000000000001.mp3'),
 ('audio','11111111-1111-4111-8111-111111111111/aaaaaaaa-0000-4000-8000-000000000002.mp3'),
 ('audio','11111111-1111-4111-8111-111111111111/aaaaaaaa-0000-4000-8000-000000000003.mp3'),
 ('audio','22222222-2222-4222-8222-222222222222/aaaaaaaa-0000-4000-8000-000000000004.mp3');
insert into public.reports (id,song_id,reason,reporter_id) values
 ('bbbbbbbb-0000-4000-8000-000000000001','aaaaaaaa-0000-4000-8000-000000000001','不適切な歌詞','22222222-2222-4222-8222-222222222222');
