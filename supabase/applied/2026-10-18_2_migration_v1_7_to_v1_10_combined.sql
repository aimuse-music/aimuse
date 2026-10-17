-- =====================================================================
-- AIMUSE v1.7〜v1.10 本番適用（1回の実行で4本をまとめて適用・最終確認つき）
-- Supabase の SQL Editor に全文を貼り付けて、1回だけ「Run」してください。
--
-- ・前提：v1.6 を適用済みであること（満たさなければ何もせずに中止）
-- ・中身：migration_v1_7 → v1_8 → v1_9 → v1_10 を、GitHub release-fixes（50d98e5）と同じ内容のまま順番に並べたもの
-- ・全体を BEGIN〜COMMIT で囲んでいます。途中でエラーが出たら、それまでの変更もすべて取り消されます
-- ・COMMIT の直前に、本番確認（production_checks r10 の29項目。29番は今回の公開用に「受付 off・完全削除 off」だけを OK に変更）と、
--   データ件数が実行前と同じかを確認します。
--   1つでも異常があれば、エラーを出して全体を取り消します（COMMIT されません）
-- ・成功すると、最後に29項目の確認結果の表が表示されます（読み取りのみ）
-- ・エラーが出たときは、画面の内容を消して「rollback;」だけを1回実行し、エラーの文面を報告してください
-- ・既存のデータは変更しません。AIMUSE BOOST の表・関数には触れません
-- ・退会の受付・完全削除は「off」のまま（誰も申請できず、削除処理も動きません）
-- =====================================================================

begin;

-- ---------- 前提の確認と、実行前のデータ件数の記録 ----------
do $aimuse_pre$
begin
  if to_regprocedure('public.set_my_profile_image(text, text)') is null
     or to_regclass('aimuse_private.artist_name_history') is null
     or not exists (select 1 from storage.buckets where id = 'avatars') then
    raise exception 'v1.6 が未適用です。何も変更せずに中止しました。';
  end if;
  perform set_config('aimuse.counts_before', (select count(*) from auth.users) || '/' || (select count(*) from public.profiles) || '/' ||
    (select count(*) from public.profiles where is_admin) || '/' || (select count(*) from public.profiles where is_banned) || '/' ||
    (select count(*) from public.artists) || '/' || (select count(*) from public.tracks where status = 'public') || '/' ||
    (select count(*) from public.tracks where status = 'pending') || '/' || (select count(*) from public.tracks where status = 'hidden') || '/' ||
    (select count(*) from public.tracks where status = 'rejected') || '/' || (select count(*) from public.favorites) || '/' ||
    (select count(*) from public.follows) || '/' || (select count(*) from public.reviews) || '/' || (select count(*) from public.reports) || '/' ||
    (select count(*) from public.play_events) || '/' || (select coalesce(sum(plays), 0) from public.tracks) || '/' ||
    (select count(*) from storage.objects) || '/' || (select count(*) from aimuse_private.track_deletions), true);
end $aimuse_pre$;

-- #####################################################################
-- ##### ここから migration_v1_7_follow_lists.sql（GitHub release-fixes 50d98e5 と同じ内容）
-- #####################################################################

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
--   ・公開アーティストについても会員IDは返しません（アーティストID・名前・アイコンの場所だけ）
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
--   次のページは、前のページの最後の行の followed_at と cursor（＝その行のアーティストID）を渡します
--   会員IDは返しません（ページ分割も公開用のアーティストIDだけで行います）
create or replace function public.public_artist_followers(
  p_artist uuid, p_before_at timestamptz default null, p_before uuid default null, p_limit integer default 30)
returns table (artist_id uuid, name text, avatar_path text, followed_at timestamptz, cursor uuid)
language sql stable security definer set search_path = ''
as $$
  select pa.id, pa.name, p.avatar_path, f.created_at, pa.id
  from public.follows f
  cross join lateral (select public.public_artist_of_user(f.user_id) as aid) x
  join public.artists pa on pa.id = x.aid
  join public.profiles p on p.id = f.user_id
  where f.artist_id = p_artist
    and public.is_public_artist(p_artist)
    and (p_before_at is null or p_before is null or (f.created_at, pa.id) < (p_before_at, p_before))
  order by f.created_at desc, pa.id desc
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

-- #####################################################################
-- ##### ここから migration_v1_8_theme.sql（GitHub release-fixes 50d98e5 と同じ内容）
-- #####################################################################

-- =====================================================================
-- AIMUSE v1.8 カラーテーマの保存（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：v1.5（構築）・v1.6（プロフィール）・v1.7（フォロー一覧）を実行済みであること。満たさなければ中止します
--   ・profiles に theme（テーマ設定）の列を1つ追加するだけ。既存のデータは削除・変更しません。何度実行しても壊れません
--   ・theme は本人と管理者だけが読める（profiles の既存のルールのまま）。公開用の関数では返しません
--   ・アプリから直接は書き換えられず、確認つきの関数 set_my_theme だけで変更できます
--   ・AIMUSE BOOST が使う is_admin()・profiles.is_admin・protect_profile_flags・tracks・covers・admin_stats は変更しません
-- =====================================================================

-- ---------- 0. 前提の確認 ----------
do $$
begin
  if to_regclass('public.profiles') is null then
    raise exception 'AIMUSE の構築SQL（v1.5）が未実行です。中止しました。';
  end if;
  if to_regprocedure('public.my_following(timestamptz,uuid,integer)') is null then
    raise exception 'フォロー一覧SQL（v1.7）が未実行です。先に v1.6・v1.7 を実行してください。中止しました。';
  end if;
end $$;

-- ---------- 1. テーマ設定の列 ----------
-- 形式：{"v":1, "preset":"standard|ocean|rose|emerald|gold|mono|custom", "accent":"#rrggbb", "bg":"#rrggbb", "button":"#rrggbb"}
-- これ以外の形（余分な項目・色以外の値・長い文字列など）は保存できません
alter table public.profiles add column if not exists theme jsonb;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_theme_chk' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_theme_chk check (
      theme is null or (
        jsonb_typeof(theme) = 'object'
        and theme ?& array['v', 'preset', 'accent', 'bg', 'button']
        and (theme - array['v', 'preset', 'accent', 'bg', 'button']) = '{}'::jsonb
        and jsonb_typeof(theme -> 'v') = 'number' and theme ->> 'v' = '1'
        and jsonb_typeof(theme -> 'preset') = 'string'
        and theme ->> 'preset' in ('standard', 'ocean', 'rose', 'emerald', 'gold', 'mono', 'custom')
        and jsonb_typeof(theme -> 'accent') = 'string' and theme ->> 'accent' ~ '^#[0-9a-fA-F]{6}$'
        and jsonb_typeof(theme -> 'bg') = 'string'     and theme ->> 'bg'     ~ '^#[0-9a-fA-F]{6}$'
        and jsonb_typeof(theme -> 'button') = 'string' and theme ->> 'button' ~ '^#[0-9a-fA-F]{6}$'
      ));
  end if;
end $$;

-- アプリ（会員・未ログイン）に theme 列を直接書き換える権限を与えない（profiles の更新権限は従来どおり display_name だけ）
revoke update (theme) on public.profiles from anon, authenticated;

-- ---------- 2. 本人のテーマを保存する関数（null で未設定＝端末のテーマに戻す） ----------
create or replace function public.set_my_theme(p_theme jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'ログインしてください';
  end if;
  begin
    update public.profiles set theme = p_theme where id = v_uid;
  exception when check_violation then
    raise exception 'テーマの形式が正しくありません';
  end;
  if not found then
    raise exception 'プロフィールが見つかりません';
  end if;
end;
$$;

revoke all on function public.set_my_theme(jsonb) from public, anon, authenticated;
grant execute on function public.set_my_theme(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- 完了
-- =====================================================================

-- #####################################################################
-- ##### ここから migration_v1_9_delete.sql（GitHub release-fixes 50d98e5 と同じ内容）
-- #####################################################################

-- =====================================================================
-- AIMUSE v1.9 r4 楽曲の削除（投稿者本人）とアカウントの退会（30日間の取り消し期間つき）
-- r4：パスワード照合の回数制限を、同時に送られても5回を超えない方式に変更（account_reauth_begin・account_reauth_end）。
--     完全削除のときに、その会員のパスワード照合の記録も消す
-- r3：退会の受付と完全削除に「データベース側のスイッチ」と「テスト用アカウントの許可リスト」を追加。
--     初期状態は「誰も申請できない・完全削除は動かない」。運営者が SQL で切り替えるまで何も起きません
-- r2：退会の申請は、サーバー側の処理（Edge Function「account-delete-request」）がパスワードを
--     Supabase の正式なログイン機能で照合してから行う方式に変更（ログイン時刻だけに頼らない）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：v1.5〜v1.8 を実行済みであること。満たさなければ何も変更せずに中止します
--   ・追加のみ：既存のデータは削除・変更しません。何度実行しても壊れません
--   ・既存の関数のうち、次の4つは「引数・戻り値・権限はそのまま」で判定に「退会手続き中」を加えます
--       is_active_member（書き込みできる会員か） / is_visible_member（公開画面に出してよい会員か）
--       track_reviews・track_rating_summary（退会手続き中の会員のレビューを表示しない）
--   ・完全削除（30日後）は、サーバー側の処理（Edge Function「account-purge」）だけが行います。
--     そのための関数は service_role（管理用の秘密キー）でしか実行できず、アプリ・管理者画面からは呼べません
--   ・AIMUSE BOOST が使う is_admin()・profiles.is_admin・protect_profile_flags・tracks・covers・admin_stats は変更しません
-- =====================================================================

-- ---------- 0. 前提の確認 ----------
do $$
begin
  if to_regprocedure('public.set_my_theme(jsonb)') is null then
    raise exception 'カラーテーマSQL（v1.8）が未実行です。先に v1.6・v1.7・v1.8 を実行してください。中止しました。';
  end if;
  if to_regclass('aimuse_private.track_deletions') is null then
    raise exception 'AIMUSE の構築SQL（v1.5）の削除記録の表が見つかりません。中止しました。';
  end if;
end $$;


-- ---------- 1. 記録用の表（アプリからは一切見えない場所） ----------

-- 楽曲の削除記録に「誰が・どの理由で削除したか」と「削除時点の通報内容」を追加（既存の行は変更しません）
alter table aimuse_private.track_deletions add column if not exists reason text;
alter table aimuse_private.track_deletions add column if not exists reports jsonb not null default '[]'::jsonb;

-- 退会の申請と進行状況
--   status：pending=取り消し期間中 / canceled=取り消し済み / processing=完全削除の処理中 / done=削除完了 / failed=失敗が続き運営の確認待ち
create table if not exists aimuse_private.account_deletions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  status text not null default 'pending'
    check (status in ('pending', 'canceled', 'processing', 'done', 'failed')),
  requested_at timestamptz not null default now(),
  purge_after timestamptz not null,               -- この日時を過ぎると完全削除を開始（取り消しはこの前まで）
  canceled_at timestamptz,
  started_at timestamptz,
  files_done_at timestamptz,
  db_done_at timestamptz,
  finished_at timestamptz,
  attempts integer not null default 0,
  lock_token uuid,                                 -- 二重実行を防ぐための処理番号
  locked_until timestamptz,
  last_error text check (last_error is null or char_length(last_error) <= 500),
  hidden_tracks jsonb not null default '[]'::jsonb -- 申請時に非公開にした曲と元の状態（取り消し時の復元用）
);
-- 1人につき、進行中の退会申請は1件だけ（同時に申請しても2件にならない）
create unique index if not exists account_deletions_active_key
  on aimuse_private.account_deletions(user_id) where status in ('pending', 'processing', 'failed');
create index if not exists account_deletions_due_idx on aimuse_private.account_deletions(status, purge_after);

-- 削除するファイルの一覧（申請時に記録し、完全削除の直前にも追加の確認をする）
create table if not exists aimuse_private.account_deletion_files (
  request_id uuid not null references aimuse_private.account_deletions(id) on delete cascade,
  bucket_id text not null,
  name text not null,
  deleted_at timestamptz,
  primary key (request_id, bucket_id, name)
);

alter table aimuse_private.account_deletions enable row level security;
alter table aimuse_private.account_deletion_files enable row level security;
revoke all on aimuse_private.account_deletions from public;
revoke all on aimuse_private.account_deletion_files from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on aimuse_private.account_deletions from anon, authenticated';
    execute 'revoke all on aimuse_private.account_deletion_files from anon, authenticated';
  end if;
end $$;


-- ---------- 2. 判定用の関数 ----------

-- 退会手続き中か（取り消し期間中・削除処理中・失敗して確認待ち）
create or replace function aimuse_private.is_withdrawing(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_user is not null and exists (
    select 1 from aimuse_private.account_deletions d
    where d.user_id = p_user and d.status in ('pending', 'processing', 'failed'));
$$;

-- 書き込みできる会員か：従来の条件（ログイン済み・メール認証済み・利用停止でない）に「退会手続き中でない」を追加
--   投稿・お気に入り・フォロー・レビュー・通報・プロフィール画像・アーティスト名・ファイルの保存はすべてこの判定を通ります
--   ログインし直しても、別の端末の古いログイン状態でも、データベース側で毎回確認するため操作できません
create or replace function public.is_active_member()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null
     and exists (select 1 from auth.users u
                 where u.id = auth.uid() and u.email_confirmed_at is not null)
     and not coalesce((select p.is_banned from public.profiles p where p.id = auth.uid()), true)
     and not exists (select 1 from aimuse_private.account_deletions d   -- 退会手続き中でない（is_withdrawing と同じ判定）
                     where d.user_id = auth.uid() and d.status in ('pending', 'processing', 'failed'));
$$;

-- 公開画面に出してよい会員か：利用停止中・退会手続き中は出さない（フォロワー数・一覧から除外）
create or replace function public.is_visible_member(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles p where p.id = p_user and not p.is_banned)
     and not exists (select 1 from aimuse_private.account_deletions d   -- is_withdrawing と同じ判定（一覧の速度のため直接記述）
                     where d.user_id = p_user and d.status in ('pending', 'processing', 'failed'));
$$;

-- 公開中の曲のレビュー一覧：退会手続き中の会員のレビューも表示しない（それ以外は従来どおり）
create or replace function public.track_reviews(tid uuid)
returns table (id uuid, rating smallint, comment text, created_at timestamptz,
               updated_at timestamptz, reviewer_name text, is_mine boolean)
language sql stable security definer set search_path = ''
as $$
  select r.id, r.rating, r.comment, r.created_at, r.updated_at,
         coalesce(p.display_name, '会員'),
         (auth.uid() is not null and r.user_id = auth.uid())
  from public.reviews r
  join public.tracks t on t.id = r.track_id
  left join public.profiles p on p.id = r.user_id
  where r.track_id = tid
    and (t.status = 'public' or t.user_id = auth.uid() or public.is_admin())
    and not coalesce(p.is_banned, false)
    and not aimuse_private.is_withdrawing(r.user_id)
  order by r.created_at desc
  limit 200;
$$;

create or replace function public.track_rating_summary(tid uuid)
returns table (average numeric, total integer)
language sql stable security definer set search_path = ''
as $$
  select round(avg(r.rating)::numeric, 1), count(*)::integer
  from public.reviews r
  join public.tracks t on t.id = r.track_id
  left join public.profiles p on p.id = r.user_id
  where r.track_id = tid and t.status = 'public' and not coalesce(p.is_banned, false)
    and not aimuse_private.is_withdrawing(r.user_id);
$$;

-- 退会の受付・完全削除のスイッチ（初期値はどちらもオフ。すでにある値は変更しない）
--   account_deletion_mode：off＝誰も申請できない / testers＝許可リストの会員だけ / all＝全員
--   account_purge_enabled：off＝完全削除は動かない / on＝動く
insert into aimuse_private.settings (key, value) values ('account_deletion_mode', 'off'), ('account_purge_enabled', 'off')
on conflict (key) do nothing;

-- 退会の検証に使うテスト用アカウントの許可リスト（運営者が SQL Editor で登録。アプリからは見えない）
create table if not exists aimuse_private.deletion_testers (
  user_id uuid primary key,
  note text check (note is null or char_length(note) <= 100),
  added_at timestamptz not null default now()
);
alter table aimuse_private.deletion_testers enable row level security;
revoke all on aimuse_private.deletion_testers from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on aimuse_private.deletion_testers from anon, authenticated';
  end if;
end $$;

-- 本人確認（パスワード照合）の試行記録：1人1時間に5回まで（総当たりの防止）
--   照合の前に1行を予約し（同時に送られても1件ずつ数える）、成功・一時的な障害のときだけ消す
create table if not exists aimuse_private.reauth_failures (
  user_id uuid not null,
  at timestamptz not null default now()
);
alter table aimuse_private.reauth_failures add column if not exists id uuid not null default gen_random_uuid();
create unique index if not exists reauth_failures_id_key on aimuse_private.reauth_failures(id);
create index if not exists reauth_failures_user_idx on aimuse_private.reauth_failures(user_id, at);
alter table aimuse_private.reauth_failures enable row level security;
revoke all on aimuse_private.reauth_failures from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on aimuse_private.reauth_failures from anon, authenticated';
  end if;
end $$;
-- 旧案（ログイン時刻で判定する関数）が残っていれば削除
drop function if exists aimuse_private.recently_authenticated(integer);


-- ---------- 3. 退会手続き中の会員を守る仕組み ----------

-- 退会手続き中の会員の曲は、管理者でも「公開」「審査待ち」に戻せない（取り消し後は元に戻ります）
create or replace function aimuse_private.tracks_block_withdrawing()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status is distinct from old.status and new.status in ('public', 'pending')
     and aimuse_private.is_withdrawing(new.user_id) then
    raise exception '退会手続き中の会員の楽曲は、公開・審査に戻せません';
  end if;
  return new;
end;
$$;
drop trigger if exists tracks_block_withdrawing on public.tracks;
create trigger tracks_block_withdrawing
  before update on public.tracks
  for each row execute function aimuse_private.tracks_block_withdrawing();

-- 退会手続き中は表示名を変更できない（アプリ経由。管理者・SQL Editor は対象外）
create or replace function aimuse_private.profiles_block_withdrawing()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.display_name is distinct from old.display_name
     and coalesce(auth.jwt()->>'role', '') in ('anon', 'authenticated')
     and not public.is_admin()
     and aimuse_private.is_withdrawing(old.id) then
    raise exception '退会手続き中のため、プロフィールを変更できません';
  end if;
  return new;
end;
$$;
drop trigger if exists profiles_block_withdrawing on public.profiles;
create trigger profiles_block_withdrawing
  before update on public.profiles
  for each row execute function aimuse_private.profiles_block_withdrawing();

-- その会員のファイルを削除対象の一覧に追加（すでにあるものは追加しない）
create or replace function aimuse_private.collect_account_files(p_request uuid, p_user uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_n integer;
begin
  insert into aimuse_private.account_deletion_files (request_id, bucket_id, name)
  select p_request, f.bucket_id, f.name from (
    -- 音源・ジャケット：本人のフォルダにあるファイル
    select o.bucket_id::text as bucket_id, o.name::text as name from storage.objects o
     where o.bucket_id in ('audio', 'covers') and split_part(o.name, '/', 1) = p_user::text
    -- アイコン・背景：本人が保存した画像
    union select o.bucket_id::text, o.name::text from storage.objects o
     where o.bucket_id = 'avatars' and o.owner_id = p_user::text
    -- 曲・プロフィールが参照しているファイル（ファイルが無くても一覧には載せる。削除時に「無い」ことを確認する）
    union select 'audio', t.audio_path from public.tracks t where t.user_id = p_user
    union select 'covers', t.image_path from public.tracks t where t.user_id = p_user and t.image_path is not null
    union select 'audio', d.track->>'audio_path' from aimuse_private.track_deletions d
     where d.track->>'user_id' = p_user::text and d.track->>'audio_path' is not null
    union select 'covers', d.track->>'image_path' from aimuse_private.track_deletions d
     where d.track->>'user_id' = p_user::text and d.track->>'image_path' is not null
    union select 'avatars', p.avatar_path from public.profiles p where p.id = p_user and p.avatar_path is not null
    union select 'avatars', p.header_path from public.profiles p where p.id = p_user and p.header_path is not null
  ) f
  where f.name is not null
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;


-- ---------- 4. 楽曲の削除（投稿者本人） ----------
--   ・公開中・審査待ち・非公開・却下のどれでも、本人なら削除できます（他人の曲は不可）
--   ・削除すると、公開一覧・検索・アーティストページからすぐに消えます
--   ・従来どおり、削除時の内容を30日間保存し、運営が復元できます（復元後は「非公開」）
--     音源・ジャケットのファイルも30日間は残し、その後に整理します
--   ・1回の処理（トランザクション）で行うため、途中で失敗しても「半分だけ削除」になりません
--   ・すでに削除済みの曲をもう一度削除しても、エラーにせず「削除済み」と返します（再試行しても安全）
create or replace function public.delete_my_track(p_track uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_t public.tracks%rowtype;
  v_reports jsonb;
begin
  if v_uid is null then
    raise exception 'ログインしてください';
  end if;
  if not public.is_active_member() then
    raise exception '楽曲を削除できません（ログイン状態・メール確認・利用状況を確認してください）';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_tracks:' || v_uid::text, 0));
  select * into v_t from public.tracks t where t.id = p_track for update;
  if not found then
    if exists (select 1 from aimuse_private.track_deletions d
               where d.track_id = p_track and d.track->>'user_id' = v_uid::text and d.restored_at is null) then
      return 'already_deleted';
    end if;
    raise exception '楽曲が見つかりません';
  end if;
  if v_t.user_id <> v_uid then
    raise exception '楽曲が見つかりません';   -- 他人の曲（存在するかどうかも知らせない）
  end if;

  v_reports := coalesce((select jsonb_agg(to_jsonb(r)) from public.reports r where r.song_id = p_track), '[]'::jsonb);
  -- 公開中の曲は、従来の安全装置（公開中は直接削除できない）に合わせて、同じ処理の中で非公開にしてから削除
  if v_t.status = 'public' then
    update public.tracks set status = 'hidden' where id = p_track;
  end if;
  delete from public.tracks where id = p_track;   -- 削除記録は従来のトリガーが保存
  -- 削除記録に「本人が削除」「削除前の状態」「通報内容」を記録（運営の確認・復元用）
  update aimuse_private.track_deletions d
     set track = jsonb_set(d.track, '{status}', to_jsonb(v_t.status)), reason = 'owner', reports = v_reports
   where d.id = (select x.id from aimuse_private.track_deletions x
                 where x.track_id = p_track and x.restored_at is null
                 order by x.deleted_at desc limit 1);
  return 'deleted';
end;
$$;


-- ---------- 5. 退会の申請・取り消し・状況の確認（本人のみ） ----------

-- 退会の申請（サーバー側の処理 account-delete-request 専用。service_role でのみ実行可）
--   本人確認の流れ（Edge Function の中）：
--     ① 送られてきたログイン情報（JWT）を Supabase で確認し、会員を特定（auth.getUser）
--     ② 「1時間に5回まで」の枠を1つ予約（account_reauth_begin。同時に送られても5回を超えない）
--     ③ 入力されたパスワードを Supabase の正式なログイン機能（signInWithPassword）で照合
--        結果を account_reauth_end で記録（失敗は残す・成功と一時的な障害は消す）。照合用に作られたログインはすぐに終了
--     ④ 照合できた会員IDで、この関数を呼ぶ（アプリ・会員・管理者は直接呼べません）
--   ・管理者アカウントは退会できません（先に管理者権限を外す必要があります）
--   ・公開中・審査待ちの曲を非公開にし、元の状態を記録します（取り消し時に復元）
--   ・削除するファイルの一覧を記録します
--   ・すでに申請中なら、新しく作らずに今の申請を返します（二重に押しても安全）
create or replace function public.account_request_deletion(p_user uuid)
returns table (status text, requested_at timestamptz, purge_after timestamptz)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_req aimuse_private.account_deletions%rowtype;
begin
  if p_user is null or not exists (select 1 from auth.users u where u.id = p_user) then
    raise exception '会員が見つかりません';
  end if;
  if exists (select 1 from public.profiles p where p.id = p_user and p.is_admin) then
    raise exception '管理者アカウントは退会できません。先に管理者権限を外してください';
  end if;
  -- 受付のスイッチ（初期値 off＝誰も申請できない）。testers のときは許可リストの会員だけ
  case coalesce((select s.value from aimuse_private.settings s where s.key = 'account_deletion_mode'), 'off')
    when 'all' then null;
    when 'testers' then
      if not exists (select 1 from aimuse_private.deletion_testers t where t.user_id = p_user) then
        raise exception 'NOT_ALLOWED: この会員は退会の検証対象ではありません';
      end if;
    else
      raise exception 'DELETION_DISABLED: 退会の申請は現在受け付けていません';
  end case;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_account:' || p_user::text, 0));

  select * into v_req from aimuse_private.account_deletions d
  where d.user_id = p_user and d.status in ('pending', 'processing', 'failed')
  for update;
  if found then
    return query select v_req.status, v_req.requested_at, v_req.purge_after;
    return;
  end if;

  insert into aimuse_private.account_deletions (user_id, purge_after, hidden_tracks)
  values (p_user, now() + interval '30 days',
          coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'status', t.status))
                    from public.tracks t where t.user_id = p_user and t.status in ('public', 'pending')), '[]'::jsonb))
  returning * into v_req;

  update public.tracks set status = 'hidden' where user_id = p_user and status in ('public', 'pending');
  perform aimuse_private.collect_account_files(v_req.id, p_user);

  return query select v_req.status, v_req.requested_at, v_req.purge_after;
end;
$$;

-- 旧案（確認と記録が別々の関数。同時に送ると上限を超えられた）が残っていれば削除
drop function if exists public.account_reauth_allowed(uuid);
drop function if exists public.account_reauth_failed(uuid);

-- パスワード照合の前に枠を1つ予約（直近1時間の記録が5件未満のときだけ）。上限なら null
--   会員ごとの鍵で1件ずつ処理するので、同時に送られても5回を超えない（1日より古い記録は掃除）
create or replace function public.account_reauth_begin(p_user uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if p_user is null then return null; end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_reauth:' || p_user::text, 0));
  delete from aimuse_private.reauth_failures where at < now() - interval '1 day';
  if (select count(*) from aimuse_private.reauth_failures f
      where f.user_id = p_user and f.at > now() - interval '1 hour') >= 5 then
    return null;
  end if;
  insert into aimuse_private.reauth_failures (user_id) values (p_user) returning id into v_id;
  return v_id;
end;
$$;

-- 照合の結果：失敗なら予約をそのまま失敗として残す。成功・一時的な障害なら予約を消す（回数に数えない）
create or replace function public.account_reauth_end(p_attempt uuid, p_failed boolean)
returns void
language sql security definer set search_path = ''
as $$
  delete from aimuse_private.reauth_failures where id = p_attempt and not coalesce(p_failed, true);
$$;

-- 旧案（会員が直接呼ぶ申請関数）が残っていれば削除
drop function if exists public.request_my_account_deletion();

-- 退会の取り消し（本人のみ・30日以内・完全削除が始まる前まで）
--   ・申請時に非公開にした曲を元の状態（公開中・審査待ち）に戻します
--   ・ただし、申請後に通報されて未対応の曲、または通報で「非公開」と判断された曲は、非公開のままにします
--   ・申請時に非公開・却下だった曲、申請後に運営が却下・削除した曲はそのままです
create or replace function public.cancel_my_account_deletion()
returns table (status text, restored integer, kept_hidden integer)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_req aimuse_private.account_deletions%rowtype;
  v_restored integer := 0;
  v_kept integer := 0;
  v_item jsonb;
  v_n integer;
begin
  if v_uid is null then
    raise exception 'ログインしてください';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_account:' || v_uid::text, 0));
  select * into v_req from aimuse_private.account_deletions d
  where d.user_id = v_uid and d.status in ('pending', 'processing', 'failed')
  for update;
  if not found then
    raise exception '取り消せる退会申請がありません';
  end if;
  -- 期限の判定は、削除処理の取り出し（account_purge_claim）と同じ行の鍵をかけた上で行うため、同時でも両方は成立しない
  if v_req.status <> 'pending' then
    raise exception '完全削除の処理がすでに始まっているため、取り消せません';
  end if;
  if v_req.purge_after <= now() then
    raise exception '取り消しの期限（申請から30日）を過ぎたため、取り消せません';
  end if;

  update aimuse_private.account_deletions
     set status = 'canceled', canceled_at = now(), lock_token = null, locked_until = null
   where id = v_req.id;

  for v_item in select * from jsonb_array_elements(v_req.hidden_tracks) loop
    if exists (select 1 from public.reports r
               where r.song_id = (v_item->>'id')::uuid and r.created_at > v_req.requested_at
                 and (r.status = 'open' or r.action = 'hide')) then
      v_kept := v_kept + 1;
      continue;
    end if;
    update public.tracks set status = v_item->>'status'
     where id = (v_item->>'id')::uuid and user_id = v_uid and status = 'hidden';
    get diagnostics v_n = row_count;
    v_restored := v_restored + v_n;
  end loop;

  delete from aimuse_private.account_deletion_files where request_id = v_req.id;
  return query select 'canceled'::text, v_restored, v_kept;
end;
$$;

-- 自分の退会手続きの状況（申請していなければ0行）
create or replace function public.my_account_deletion()
returns table (status text, requested_at timestamptz, purge_after timestamptz, can_cancel boolean)
language sql stable security definer set search_path = ''
as $$
  select d.status, d.requested_at, d.purge_after, (d.status = 'pending' and d.purge_after > now())
  from aimuse_private.account_deletions d
  where d.user_id = auth.uid() and d.status in ('pending', 'processing', 'failed')
  limit 1;
$$;


-- ---------- 6. 完全削除の処理（サーバー側の Edge Function 専用。service_role でのみ実行可） ----------
-- 処理の順番：①対象を1件取り出す（処理番号を発行）②ファイルを削除 ③データベースの記録を削除 ④ログイン情報（会員）を削除 ⑤完了を記録
-- ・②〜⑤は、処理番号が一致し、期限内のときだけ実行できます（同じ申請を2つの処理が同時に進めることはありません）
-- ・途中で止まっても、期限（10分）が過ぎれば次回の実行で続きから再開します。済んだ手順は飛ばします
-- ・「削除した」という報告は信用せず、データベース側で実際に無くなったことを確認してから記録します

-- 処理番号の確認と期限の延長（内部用）
create or replace function aimuse_private.purge_lease(p_request uuid, p_token uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid;
begin
  -- 途中で完全削除のスイッチがオフにされたら、次の手順に進まずに止める（緊急停止）
  if coalesce((select s.value from aimuse_private.settings s where s.key = 'account_purge_enabled'), 'off') <> 'on' then
    raise exception 'PURGE_DISABLED: 完全削除は停止中です';
  end if;
  update aimuse_private.account_deletions d
     set locked_until = now() + interval '10 minutes'
   where d.id = p_request and d.status = 'processing'
     and d.lock_token = p_token and d.locked_until > now()
  returning d.user_id into v_user;
  if v_user is null then
    raise exception 'LEASE_LOST: この削除処理は別の処理に引き継がれたか、期限切れです';
  end if;
  return v_user;
end;
$$;

-- ① 期限を過ぎた申請（または途中で止まった処理）を1件取り出す。同時に実行しても同じ申請は取り出されない
create or replace function public.account_purge_claim()
returns table (request_id uuid, user_id uuid, lock_token uuid)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  -- 完全削除のスイッチ（初期値 off）。オフの間は何も取り出さない
  if coalesce((select s.value from aimuse_private.settings s where s.key = 'account_purge_enabled'), 'off') <> 'on' then
    return;
  end if;
  -- 10回試しても終わらず止まったままの処理は「failed（運営の確認待ち）」にする
  update aimuse_private.account_deletions x set status = 'failed', lock_token = null, locked_until = null
   where x.status = 'processing' and x.attempts >= 10 and (x.locked_until is null or x.locked_until <= now());
  return query
  update aimuse_private.account_deletions d
     set status = 'processing',
         started_at = coalesce(d.started_at, now()),
         attempts = d.attempts + 1,
         lock_token = gen_random_uuid(),
         locked_until = now() + interval '10 minutes'
   where d.id = (
     select x.id from aimuse_private.account_deletions x
     where ((x.status = 'pending' and x.purge_after <= now())
         or (x.status = 'processing' and x.attempts < 10 and (x.locked_until is null or x.locked_until <= now())))
     order by x.purge_after
     limit 1
     for update skip locked)
  returning d.id, d.user_id, d.lock_token;
end;
$$;

-- ② 削除が済んでいないファイルの一覧（最大500件ずつ）。直前に、申請後に増えたファイルがないかも確認
create or replace function public.account_purge_pending_files(p_request uuid, p_token uuid)
returns table (bucket_id text, name text)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_user uuid := aimuse_private.purge_lease(p_request, p_token);
begin
  perform aimuse_private.collect_account_files(p_request, v_user);
  return query
    select f.bucket_id, f.name from aimuse_private.account_deletion_files f
    where f.request_id = p_request and f.deleted_at is null
    order by f.bucket_id, f.name
    limit 500;
end;
$$;

-- ② ファイルを削除したことの記録：Storage に実際に無いものだけを「削除済み」にする
create or replace function public.account_purge_mark_files(p_request uuid, p_token uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := aimuse_private.purge_lease(p_request, p_token);
  v_n integer;
begin
  update aimuse_private.account_deletion_files f set deleted_at = now()
   where f.request_id = p_request and f.deleted_at is null
     and not exists (select 1 from storage.objects o where o.bucket_id = f.bucket_id and o.name = f.name);
  get diagnostics v_n = row_count;
  if not exists (select 1 from aimuse_private.account_deletion_files f
                 where f.request_id = p_request and f.deleted_at is null) then
    update aimuse_private.account_deletions set files_done_at = coalesce(files_done_at, now()) where id = p_request;
  end if;
  return v_n;
end;
$$;

-- ③ データベースの記録の削除（ファイルがすべて無くなってから）
--   ・会員の曲を削除し、その削除記録（30日間の復元用）も残さない
--   ・他の曲の削除記録に含まれる、この会員のレビューも消す
--   ・プロフィール・アーティスト・お気に入り・フォロー・レビュー・通報は、④の会員削除で自動的に消える
create or replace function public.account_purge_db(p_request uuid, p_token uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := aimuse_private.purge_lease(p_request, p_token);
begin
  perform aimuse_private.collect_account_files(p_request, v_user);
  if exists (select 1 from aimuse_private.account_deletion_files f
             where f.request_id = p_request and f.deleted_at is null
               and exists (select 1 from storage.objects o where o.bucket_id = f.bucket_id and o.name = f.name)) then
    raise exception 'FILES_REMAIN: 削除されていないファイルがあります';
  end if;
  update aimuse_private.account_deletion_files set deleted_at = coalesce(deleted_at, now()) where request_id = p_request;
  update aimuse_private.account_deletions set files_done_at = coalesce(files_done_at, now()) where id = p_request;

  update public.tracks set status = 'hidden' where user_id = v_user and status = 'public';
  delete from public.tracks where user_id = v_user;
  delete from aimuse_private.track_deletions where track->>'user_id' = v_user::text;
  update aimuse_private.track_deletions d
     set reviews = coalesce((select jsonb_agg(e) from jsonb_array_elements(d.reviews) e
                             where e->>'user_id' is distinct from v_user::text), '[]'::jsonb)
   where d.reviews @> jsonb_build_array(jsonb_build_object('user_id', v_user::text));
  delete from aimuse_private.reauth_failures where user_id = v_user;
  update aimuse_private.account_deletions set db_done_at = coalesce(db_done_at, now()) where id = p_request;
end;
$$;

-- ⑤ 完了の記録：会員（auth.users）が実際に削除されていることを確認してから「完了」にする
create or replace function public.account_purge_finish(p_request uuid, p_token uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := aimuse_private.purge_lease(p_request, p_token);
begin
  if exists (select 1 from auth.users u where u.id = v_user) then
    raise exception 'USER_REMAINS: 会員の削除が確認できません';
  end if;
  if (select db_done_at from aimuse_private.account_deletions where id = p_request) is null then
    raise exception 'DB_NOT_DONE: データの削除が済んでいません';
  end if;
  update aimuse_private.account_deletions
     set status = 'done', finished_at = now(), lock_token = null, locked_until = null,
         hidden_tracks = '[]'::jsonb, last_error = null
   where id = p_request;
  delete from aimuse_private.account_deletion_files where request_id = p_request;
  delete from aimuse_private.reauth_failures where user_id = v_user;
end;
$$;

-- 失敗の記録：1時間おいてから再試行。10回失敗したら「failed（運営の確認待ち）」にして自動の再試行を止める（会員は非公開・操作不可のまま）
create or replace function public.account_purge_fail(p_request uuid, p_token uuid, p_error text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update aimuse_private.account_deletions d
     set last_error = left(coalesce(p_error, '不明なエラー'), 500),
         locked_until = now() + interval '1 hour', lock_token = null,
         status = case when d.attempts >= 10 then 'failed' else 'processing' end
   where d.id = p_request and d.status = 'processing' and d.lock_token = p_token;
end;
$$;


-- ---------- 7. 関数の実行権限：まず全員から外し、必要なものだけ許可 ----------
revoke all on function aimuse_private.is_withdrawing(uuid) from public;
revoke all on function aimuse_private.tracks_block_withdrawing() from public;
revoke all on function aimuse_private.profiles_block_withdrawing() from public;
revoke all on function aimuse_private.collect_account_files(uuid, uuid) from public;
revoke all on function aimuse_private.purge_lease(uuid, uuid) from public;
revoke all on function public.delete_my_track(uuid) from public, anon, authenticated;
revoke all on function public.account_request_deletion(uuid) from public, anon, authenticated;
revoke all on function public.account_reauth_begin(uuid) from public, anon, authenticated;
revoke all on function public.account_reauth_end(uuid, boolean) from public, anon, authenticated;
revoke all on function public.cancel_my_account_deletion() from public, anon, authenticated;
revoke all on function public.my_account_deletion() from public, anon, authenticated;
revoke all on function public.account_purge_claim() from public, anon, authenticated;
revoke all on function public.account_purge_pending_files(uuid, uuid) from public, anon, authenticated;
revoke all on function public.account_purge_mark_files(uuid, uuid) from public, anon, authenticated;
revoke all on function public.account_purge_db(uuid, uuid) from public, anon, authenticated;
revoke all on function public.account_purge_finish(uuid, uuid) from public, anon, authenticated;
revoke all on function public.account_purge_fail(uuid, uuid, text) from public, anon, authenticated;

-- 会員本人用
grant execute on function public.delete_my_track(uuid) to authenticated;
grant execute on function public.cancel_my_account_deletion() to authenticated;
grant execute on function public.my_account_deletion() to authenticated;
-- サーバー側の削除処理（Edge Function）専用
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.account_request_deletion(uuid) to service_role';
    execute 'grant execute on function public.account_reauth_begin(uuid) to service_role';
    execute 'grant execute on function public.account_reauth_end(uuid, boolean) to service_role';
    execute 'grant execute on function public.account_purge_claim() to service_role';
    execute 'grant execute on function public.account_purge_pending_files(uuid, uuid) to service_role';
    execute 'grant execute on function public.account_purge_mark_files(uuid, uuid) to service_role';
    execute 'grant execute on function public.account_purge_db(uuid, uuid) to service_role';
    execute 'grant execute on function public.account_purge_finish(uuid, uuid) to service_role';
    execute 'grant execute on function public.account_purge_fail(uuid, uuid, text) to service_role';
  end if;
end $$;

notify pgrst, 'reload schema';

-- =====================================================================
-- 完了
-- =====================================================================

-- #####################################################################
-- ##### ここから migration_v1_10_review_names.sql（GitHub release-fixes 50d98e5 と同じ内容）
-- #####################################################################

-- =====================================================================
-- AIMUSE v1.10 レビューの投稿者名を「公開用の名前」に変更（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：v1.5〜v1.9 を実行済みであること。満たさなければ何も変更せずに中止します
--   ・これまで：レビュー一覧（track_reviews）が、本人と運営だけに見せる約束の「表示名」を返していました
--   ・これから：公開中の曲があるアーティストの方は「アーティスト名」、それ以外の方は「リスナー」と返します
--     （表示名・メールアドレス・会員IDは返しません。引数・戻り値の形・権限は従来どおり）
--   ・既存のデータは変更・削除しません。何度実行しても壊れません
--   ・AIMUSE BOOST が使う関数・表は変更しません
-- =====================================================================

do $$
begin
  if to_regprocedure('public.account_purge_claim()') is null
     or to_regprocedure('public.public_artist_of_user(uuid)') is null then
    raise exception '先に v1.7（フォロー一覧）と v1.9（削除・退会）を実行してください。中止しました。';
  end if;
end $$;

create or replace function public.track_reviews(tid uuid)
returns table (id uuid, rating smallint, comment text, created_at timestamptz,
               updated_at timestamptz, reviewer_name text, is_mine boolean)
language sql stable security definer set search_path = ''
as $$
  select r.id, r.rating, r.comment, r.created_at, r.updated_at,
         coalesce((select a.name from public.artists a where a.id = public.public_artist_of_user(r.user_id)), 'リスナー'),
         (auth.uid() is not null and r.user_id = auth.uid())
  from public.reviews r
  join public.tracks t on t.id = r.track_id
  left join public.profiles p on p.id = r.user_id
  where r.track_id = tid
    and (t.status = 'public' or t.user_id = auth.uid() or public.is_admin())
    and not coalesce(p.is_banned, false)
    and not aimuse_private.is_withdrawing(r.user_id)
  order by r.created_at desc
  limit 200;
$$;

revoke all on function public.track_reviews(uuid) from public, anon, authenticated;
grant execute on function public.track_reviews(uuid) to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- 完了
-- =====================================================================


-- #####################################################################
-- ##### 最終確認（異常があれば全体を取り消し。COMMIT しない）
-- #####################################################################
do $aimuse_check$
declare
  v_ng integer;
  v_list text;
  v_after text;
begin
  select count(*), string_agg(q."番号" || '番 ' || q."確認項目" || '（' || q."詳細" || '）', ' / ' order by q."番号")
    into v_ng, v_list
  from (
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
         ('public_artist_followers'),('public_artist_following'),('my_following'),
         -- v1.8 カラーテーマ
         ('set_my_theme'),
         -- v1.9 楽曲の削除・退会
         ('delete_my_track'),('account_request_deletion'),('account_reauth_begin'),('account_reauth_end'),('cancel_my_account_deletion'),('my_account_deletion'),
         ('account_purge_claim'),('account_purge_pending_files'),('account_purge_mark_files'),('account_purge_db'),
         ('account_purge_finish'),('account_purge_fail')
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
  select 7, 'AIMUSEの関数58個がそろい、権限の強い関数は search_path 固定',
    (select count(*) from pubfn where name in (select name from aimuse_fn)) = 58
    and not exists (select 1 from pubfn
                    where name in (select name from aimuse_fn) and prosecdef
                      and not coalesce(proconfig @> array['search_path=""'], false)),
    (select count(*)::text || '/58個' from pubfn where name in (select name from aimuse_fn))
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
  select 21, 'v1.6：画像の保存場所の形式チェックが有効（会員IDを含まない名前）',
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
  select 24, 'v1.8：テーマ設定は形式チェックつき・本人も関数経由でしか変更できない',
    exists (select 1 from pg_constraint where conrelid = 'public.profiles'::regclass and conname = 'profiles_theme_chk')
    and not has_column_privilege('authenticated', 'public.profiles', 'theme', 'UPDATE')
    and not has_column_privilege('anon', 'public.profiles', 'theme', 'UPDATE'),
    null
  union all
  select 25, 'v1.9：退会の記録がアプリから見えない場所にあり、退会手続き中の保護が有効',
    to_regclass('aimuse_private.account_deletions') is not null
    and to_regclass('aimuse_private.account_deletion_files') is not null
    and to_regclass('aimuse_private.account_deletions_active_key') is not null
    and exists (select 1 from pg_trigger where tgname = 'tracks_block_withdrawing' and not tgisinternal)
    and exists (select 1 from pg_trigger where tgname = 'profiles_block_withdrawing' and not tgisinternal)
    and not has_function_privilege('anon', 'public.delete_my_track(uuid)', 'execute')
    and to_regclass('aimuse_private.reauth_failures') is not null
    and to_regprocedure('public.request_my_account_deletion()') is null,
    null
  union all
  select 26, 'v1.9：退会の申請・完全削除の関数はサーバー側（service_role）だけが実行できる',
    (select bool_and(not has_function_privilege('anon', p.oid, 'execute')
                     and not has_function_privilege('authenticated', p.oid, 'execute')
                     and has_function_privilege('service_role', p.oid, 'execute'))
     from pubfn p where p.name like 'account_purge_%' or p.name in ('account_request_deletion','account_reauth_begin','account_reauth_end'))
    and (select count(*) from pubfn where name like 'account_purge_%' or name in ('account_request_deletion','account_reauth_begin','account_reauth_end')) = 9,
    (select count(*)::text || '/9個' from pubfn where name like 'account_purge_%' or name in ('account_request_deletion','account_reauth_begin','account_reauth_end'))
  union all
  select 27, 'v1.9：失敗が続いて止まった退会処理がない（あれば運営の確認が必要）',
    not exists (select 1 from aimuse_private.account_deletions where status = 'failed'),
    coalesce((select string_agg(status || ' ' || n, ' / ' order by status)
              from (select status, count(*) as n from aimuse_private.account_deletions group by status) x), '申請なし')
  union all
  select 28, 'v1.10：レビューの投稿者名に表示名を使わない（アーティスト名または「リスナー」）',
    position('display_name' in pg_get_functiondef('public.track_reviews(uuid)'::regprocedure)) = 0
    and position('public_artist_of_user' in pg_get_functiondef('public.track_reviews(uuid)'::regprocedure)) > 0,
    null
  union all
  select 29, 'v1.9 r3：退会の受付・完全削除のスイッチがどちらも off（今回の公開では必須）',
    coalesce((select value from aimuse_private.settings where key = 'account_deletion_mode'), '') = 'off'
    and coalesce((select value from aimuse_private.settings where key = 'account_purge_enabled'), '') = 'off'
    and to_regclass('aimuse_private.deletion_testers') is not null,
    '受付=' || coalesce((select value from aimuse_private.settings where key = 'account_deletion_mode'), '未設定')
      || ' / 完全削除=' || coalesce((select value from aimuse_private.settings where key = 'account_purge_enabled'), '未設定')
      || ' / 検証用の許可 ' || (select count(*) from aimuse_private.deletion_testers) || '人'
  union all
  select 15, '（参考）現在のデータ件数',
    true,
    '楽曲 ' || (select count(*) from public.tracks) || '曲 / レビュー ' || (select count(*) from public.reviews) || '件'
)
select no as "番号", item as "確認項目", case when ok then 'OK' else '要確認' end as "結果", coalesce(detail, '') as "詳細"
from checks
order by no
  ) q
  where q."結果" <> 'OK';
  if v_ng > 0 then
    raise exception '最終確認で異常が % 件ありました。全体を取り消しました：%', v_ng, v_list;
  end if;
  v_after := (select count(*) from auth.users) || '/' || (select count(*) from public.profiles) || '/' ||
    (select count(*) from public.profiles where is_admin) || '/' || (select count(*) from public.profiles where is_banned) || '/' ||
    (select count(*) from public.artists) || '/' || (select count(*) from public.tracks where status = 'public') || '/' ||
    (select count(*) from public.tracks where status = 'pending') || '/' || (select count(*) from public.tracks where status = 'hidden') || '/' ||
    (select count(*) from public.tracks where status = 'rejected') || '/' || (select count(*) from public.favorites) || '/' ||
    (select count(*) from public.follows) || '/' || (select count(*) from public.reviews) || '/' || (select count(*) from public.reports) || '/' ||
    (select count(*) from public.play_events) || '/' || (select coalesce(sum(plays), 0) from public.tracks) || '/' ||
    (select count(*) from storage.objects) || '/' || (select count(*) from aimuse_private.track_deletions);
  if v_after is distinct from current_setting('aimuse.counts_before', true) then
    raise exception 'データ件数が実行前と変わりました（前 % / 後 %）。全体を取り消しました', current_setting('aimuse.counts_before', true), v_after;
  end if;
end $aimuse_check$;

commit;

-- ---------- 確認結果の表示（読み取りのみ。29行すべて OK なら完了） ----------
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
         ('public_artist_followers'),('public_artist_following'),('my_following'),
         -- v1.8 カラーテーマ
         ('set_my_theme'),
         -- v1.9 楽曲の削除・退会
         ('delete_my_track'),('account_request_deletion'),('account_reauth_begin'),('account_reauth_end'),('cancel_my_account_deletion'),('my_account_deletion'),
         ('account_purge_claim'),('account_purge_pending_files'),('account_purge_mark_files'),('account_purge_db'),
         ('account_purge_finish'),('account_purge_fail')
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
  select 7, 'AIMUSEの関数58個がそろい、権限の強い関数は search_path 固定',
    (select count(*) from pubfn where name in (select name from aimuse_fn)) = 58
    and not exists (select 1 from pubfn
                    where name in (select name from aimuse_fn) and prosecdef
                      and not coalesce(proconfig @> array['search_path=""'], false)),
    (select count(*)::text || '/58個' from pubfn where name in (select name from aimuse_fn))
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
  select 21, 'v1.6：画像の保存場所の形式チェックが有効（会員IDを含まない名前）',
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
  select 24, 'v1.8：テーマ設定は形式チェックつき・本人も関数経由でしか変更できない',
    exists (select 1 from pg_constraint where conrelid = 'public.profiles'::regclass and conname = 'profiles_theme_chk')
    and not has_column_privilege('authenticated', 'public.profiles', 'theme', 'UPDATE')
    and not has_column_privilege('anon', 'public.profiles', 'theme', 'UPDATE'),
    null
  union all
  select 25, 'v1.9：退会の記録がアプリから見えない場所にあり、退会手続き中の保護が有効',
    to_regclass('aimuse_private.account_deletions') is not null
    and to_regclass('aimuse_private.account_deletion_files') is not null
    and to_regclass('aimuse_private.account_deletions_active_key') is not null
    and exists (select 1 from pg_trigger where tgname = 'tracks_block_withdrawing' and not tgisinternal)
    and exists (select 1 from pg_trigger where tgname = 'profiles_block_withdrawing' and not tgisinternal)
    and not has_function_privilege('anon', 'public.delete_my_track(uuid)', 'execute')
    and to_regclass('aimuse_private.reauth_failures') is not null
    and to_regprocedure('public.request_my_account_deletion()') is null,
    null
  union all
  select 26, 'v1.9：退会の申請・完全削除の関数はサーバー側（service_role）だけが実行できる',
    (select bool_and(not has_function_privilege('anon', p.oid, 'execute')
                     and not has_function_privilege('authenticated', p.oid, 'execute')
                     and has_function_privilege('service_role', p.oid, 'execute'))
     from pubfn p where p.name like 'account_purge_%' or p.name in ('account_request_deletion','account_reauth_begin','account_reauth_end'))
    and (select count(*) from pubfn where name like 'account_purge_%' or name in ('account_request_deletion','account_reauth_begin','account_reauth_end')) = 9,
    (select count(*)::text || '/9個' from pubfn where name like 'account_purge_%' or name in ('account_request_deletion','account_reauth_begin','account_reauth_end'))
  union all
  select 27, 'v1.9：失敗が続いて止まった退会処理がない（あれば運営の確認が必要）',
    not exists (select 1 from aimuse_private.account_deletions where status = 'failed'),
    coalesce((select string_agg(status || ' ' || n, ' / ' order by status)
              from (select status, count(*) as n from aimuse_private.account_deletions group by status) x), '申請なし')
  union all
  select 28, 'v1.10：レビューの投稿者名に表示名を使わない（アーティスト名または「リスナー」）',
    position('display_name' in pg_get_functiondef('public.track_reviews(uuid)'::regprocedure)) = 0
    and position('public_artist_of_user' in pg_get_functiondef('public.track_reviews(uuid)'::regprocedure)) > 0,
    null
  union all
  select 29, 'v1.9 r3：退会の受付・完全削除のスイッチがどちらも off（今回の公開では必須）',
    coalesce((select value from aimuse_private.settings where key = 'account_deletion_mode'), '') = 'off'
    and coalesce((select value from aimuse_private.settings where key = 'account_purge_enabled'), '') = 'off'
    and to_regclass('aimuse_private.deletion_testers') is not null,
    '受付=' || coalesce((select value from aimuse_private.settings where key = 'account_deletion_mode'), '未設定')
      || ' / 完全削除=' || coalesce((select value from aimuse_private.settings where key = 'account_purge_enabled'), '未設定')
      || ' / 検証用の許可 ' || (select count(*) from aimuse_private.deletion_testers) || '人'
  union all
  select 15, '（参考）現在のデータ件数',
    true,
    '楽曲 ' || (select count(*) from public.tracks) || '曲 / レビュー ' || (select count(*) from public.reviews) || '件'
)
select no as "番号", item as "確認項目", case when ok then 'OK' else '要確認' end as "結果", coalesce(detail, '') as "詳細"
from checks
order by no;
