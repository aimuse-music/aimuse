-- テスト用：NOCTERA(Ryo) をフォローする会員
--  公開アーティスト40人 / リスナー75人 / 審査待ちの曲しかないアーティスト5人 / 利用停止中の公開アーティスト3人 / ハムハム(審査待ちのみ)
do $$
declare i int; u uuid; t uuid; ryo_a uuid;
begin
  select id into ryo_a from public.artists where user_id='11111111-1111-4111-8111-111111111111';
  for i in 1..123 loop
    u := ('00000000-0000-4000-8000-' || lpad(i::text,12,'0'))::uuid;
    insert into auth.users(id,email,email_confirmed_at) values (u, 'u'||i||'@ex.com', now());
    if i <= 40 or i > 120 then          -- 公開アーティスト（121〜123 は後で利用停止）
      t := gen_random_uuid();
      insert into public.tracks(id,user_id,title,artist,genre,tool,tool_name,audio_path,status)
        values (t,u,'曲'||i,'アーティスト'||i,'J-POP','Suno','Suno',u||'/'||t||'.mp3','public');
    elsif i > 115 then                  -- 116〜120：審査待ちの曲だけ
      t := gen_random_uuid();
      insert into public.tracks(id,user_id,title,artist,genre,tool,tool_name,audio_path,status)
        values (t,u,'曲'||i,'審査待ち'||i,'J-POP','Suno','Suno',u||'/'||t||'.mp3','pending');
    end if;
    insert into public.follows(user_id,artist_id,created_at) values (u, ryo_a, now() - (i||' minutes')::interval);
  end loop;
  update public.profiles set is_banned=true where id in ('00000000-0000-4000-8000-000000000121','00000000-0000-4000-8000-000000000122','00000000-0000-4000-8000-000000000123');
  update public.profiles set avatar_path = 'avatar-aaaaaaaa-1111-4111-8111-000000000001.jpg' where id='00000000-0000-4000-8000-000000000001';
  insert into public.follows(user_id,artist_id) values ('22222222-2222-4222-8222-222222222222', ryo_a);
  -- Ryo のフォロー中：公開アーティスト35人＋審査待ちのアーティスト1人＋利用停止中の公開アーティスト1人
  insert into public.follows(user_id,artist_id,created_at)
    select '11111111-1111-4111-8111-111111111111', a.id, now() - (row_number() over (order by a.name) || ' seconds')::interval
    from public.artists a join auth.users x on x.id=a.user_id
    where x.email in (select 'u'||g||'@ex.com' from generate_series(1,35) g) or x.email in ('u116@ex.com','u121@ex.com');
end $$;
