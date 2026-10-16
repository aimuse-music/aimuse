-- =====================================================================
-- AIMUSE v1.7 フォロワー・フォロー中一覧（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：構築SQL（v1.5）と プロフィール編集SQL（v1.6）を実行済みであること。満たさなければ中止します
--   ・新しいテーブルは作りません（既存の follows をそのまま使います）
--   ・既存のデータは削除・変更しません。何度実行しても壊れません
--   ・変更する既存関数は artist_follower_count の1つだけ（利用停止中の会員を人数から除く。引数・戻り値・権限は同じ）
--   ・AIMUSE BOOST が使う is_admin()・profiles.is_admin・protect_profile_flags・tracks・covers・admin_stats は変更しません
--
-- 公開の方針
--   ・一覧に名前・アイコンを出すのは「公開中の曲があるアーティスト」だけ
--   ・聴くだけの会員（リスナー）は人数だけを返し、会員ID・表示名・アイコンは一切返しません
--   ・利用停止中の会員は、一覧にも人数にも含めません（退会した会員は既存の仕組みでフォローごと削除されます）
--   ・公開されていないアーティストの一覧は返しません（中身を探られないように）
-- =====================================================================

-- ---------- 0. 前提の確認 ----------
do $$
begin
  if to_regclass('public.follows') is null or to_regclass('public.artists') is null or to_regclass('public.profiles') is null then
    raise exception 'AIMUSE の構築SQL（v1.5）が未実行です。中止しました。';
  end if;
  if to_regprocedure('public.public_artist_profiles(uuid[])') is null
     or not exists (select 1 from information_schema.columns
                    where table_schema = 'public' and table_name = 'profiles' and column_name = 'avatar_path') then
    raise exception 'プロフィール編集SQL（v1.6）が未実行です。先に v1.6 を実行してください。中止しました。';
  end if;
end $$;


-- ---------- 1. 一覧を速く取り出すための索引（大人数のフォロワーでもページ単位で取り出せる） ----------
create index if not exists follows_artist_created_idx on public.follows (artist_id, created_at desc, user_id desc);
create index if not exists follows_user_created_idx   on public.follows (user_id, created_at desc, artist_id desc);


-- ---------- 2. 判定用の関数（内部用。アプリからは直接呼べません） ----------

-- 公開画面に出してよい会員か（利用停止中でない）
-- ※ 第5段階（退会）で「退会手続き中」もここで除外する予定。判定をこの1か所にまとめています
create or replace function public.is_visible_member(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles p where p.id = p_user and not p.is_banned);
$$;

-- 公開アーティストか（公開中の曲があり、持ち主が公開画面に出してよい会員）
create or replace function public.is_public_artist(p_artist uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.artists a
    where a.id = p_artist
      and public.is_visible_member(a.user_id)
      and exists (select 1 from public.tracks t where t.artist_id = a.id and t.status = 'public'));
$$;

-- その会員を一覧で代表させる公開アーティスト（最初に作られたもの）。公開アーティストがなければ null（＝リスナー）
create or replace function public.public_artist_of_user(p_user uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select a.id from public.artists a
  where a.user_id = p_user and public.is_public_artist(a.id)
  order by a.created_at, a.id
  limit 1;
$$;


-- ---------- 3. 既存のフォロワー数：利用停止中の会員を除く（引数・戻り値・権限は従来どおり） ----------
create or replace function public.artist_follower_count(aid uuid)
returns integer
language sql stable security definer set search_path = ''
as $$
  select count(*)::integer from public.follows f
  where f.artist_id = aid and public.is_visible_member(f.user_id);
$$;


-- ---------- 4. 公開用の一覧（未ログインでも利用可） ----------

-- 人数のまとめ：フォロワー総数・うち公開アーティスト・うちリスナー・持ち主のフォロー中（公開アーティストのみ）
create or replace function public.public_artist_follow_summary(p_artist uuid)
returns table (followers integer, public_followers integer, listeners integer, following integer)
language sql stable security definer set search_path = ''
as $$
  with s as (
    select public.public_artist_of_user(f.user_id) is not null as pub
    from public.follows f
    where f.artist_id = p_artist and public.is_visible_member(f.user_id)
  )
  select (select count(*) from s)::integer,
         (select count(*) from s where pub)::integer,
         (select count(*) from s where not pub)::integer,
         (select count(*) from public.artists o
            join public.follows g on g.user_id = o.user_id
          where o.id = p_artist and public.is_public_artist(g.artist_id))::integer
  where public.is_public_artist(p_artist);
$$;

-- フォロワー一覧（公開アーティストだけ。新しい順・30件ずつ）
--   次のページは、前のページの最後の行の followed_at と cursor を渡します
--   cursor はフォローした会員のID（公開アーティストの持ち主のIDのみ。リスナーの行は返しません）
create or replace function public.public_artist_followers(
  p_artist uuid, p_before_at timestamptz default null, p_before uuid default null, p_limit integer default 30)
returns table (artist_id uuid, name text, avatar_path text, followed_at timestamptz, cursor uuid)
language sql stable security definer set search_path = ''
as $$
  select pa.id, pa.name, p.avatar_path, f.created_at, f.user_id
  from public.follows f
  cross join lateral (select public.public_artist_of_user(f.user_id) as aid) x
  join public.artists pa on pa.id = x.aid
  join public.profiles p on p.id = f.user_id
  where f.artist_id = p_artist
    and public.is_public_artist(p_artist)
    and (p_before_at is null or p_before is null or (f.created_at, f.user_id) < (p_before_at, p_before))
  order by f.created_at desc, f.user_id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- フォロー中一覧（そのアーティストの持ち主がフォローしている公開アーティスト。新しい順・30件ずつ）
create or replace function public.public_artist_following(
  p_artist uuid, p_before_at timestamptz default null, p_before uuid default null, p_limit integer default 30)
returns table (artist_id uuid, name text, avatar_path text, followed_at timestamptz, cursor uuid)
language sql stable security definer set search_path = ''
as $$
  select a.id, a.name, p.avatar_path, g.created_at, g.artist_id
  from public.artists o
  join public.follows g on g.user_id = o.user_id
  join public.artists a on a.id = g.artist_id
  join public.profiles p on p.id = a.user_id
  where o.id = p_artist
    and public.is_public_artist(p_artist)
    and public.is_public_artist(a.id)
    and (p_before_at is null or p_before is null or (g.created_at, g.artist_id) < (p_before_at, p_before))
  order by g.created_at desc, g.artist_id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- 自分のフォロー中一覧（本人のみ。いま公開されていないアーティストは名前・アイコンを返さず is_public=false）
create or replace function public.my_following(
  p_before_at timestamptz default null, p_before uuid default null, p_limit integer default 30)
returns table (artist_id uuid, name text, avatar_path text, followed_at timestamptz, cursor uuid, is_public boolean)
language sql stable security definer set search_path = ''
as $$
  select g.artist_id,
         case when pub.v then a.name end,
         case when pub.v then p.avatar_path end,
         g.created_at, g.artist_id, pub.v
  from public.follows g
  join public.artists a on a.id = g.artist_id
  join public.profiles p on p.id = a.user_id
  cross join lateral (select public.is_public_artist(g.artist_id) as v) pub
  where auth.uid() is not null
    and g.user_id = auth.uid()
    and (p_before_at is null or p_before is null or (g.created_at, g.artist_id) < (p_before_at, p_before))
  order by g.created_at desc, g.artist_id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;


-- ---------- 5. 実行権限 ----------
revoke all on function public.is_visible_member(uuid) from public, anon, authenticated;
revoke all on function public.is_public_artist(uuid) from public, anon, authenticated;
revoke all on function public.public_artist_of_user(uuid) from public, anon, authenticated;
revoke all on function public.public_artist_follow_summary(uuid) from public, anon, authenticated;
revoke all on function public.public_artist_followers(uuid, timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.public_artist_following(uuid, timestamptz, uuid, integer) from public, anon, authenticated;
revoke all on function public.my_following(timestamptz, uuid, integer) from public, anon, authenticated;
grant execute on function public.public_artist_follow_summary(uuid) to anon, authenticated;
grant execute on function public.public_artist_followers(uuid, timestamptz, uuid, integer) to anon, authenticated;
grant execute on function public.public_artist_following(uuid, timestamptz, uuid, integer) to anon, authenticated;
grant execute on function public.my_following(timestamptz, uuid, integer) to authenticated;
-- artist_follower_count の権限は従来どおり（create or replace では変わりません）。念のため再設定
revoke all on function public.artist_follower_count(uuid) from public, anon, authenticated;
grant execute on function public.artist_follower_count(uuid) to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- 完了
-- =====================================================================
