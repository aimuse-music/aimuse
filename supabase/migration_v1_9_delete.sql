-- =====================================================================
-- AIMUSE v1.9 r2 楽曲の削除（投稿者本人）とアカウントの退会（30日間の取り消し期間つき）
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

-- 本人確認（パスワード照合）の失敗記録：1人1時間に5回まで（総当たりの防止）
create table if not exists aimuse_private.reauth_failures (
  user_id uuid not null,
  at timestamptz not null default now()
);
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
--     ② この関数群で「1時間に5回まで」を確認（account_reauth_allowed）
--     ③ 入力されたパスワードを Supabase の正式なログイン機能（signInWithPassword）で照合
--        失敗したら account_reauth_failed で記録。照合用に作られたログインはすぐに終了
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

-- パスワード照合をしてよいか（直近1時間の失敗が5回未満）
create or replace function public.account_reauth_allowed(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select count(*) from aimuse_private.reauth_failures f
          where f.user_id = p_user and f.at > now() - interval '1 hour') < 5;
$$;

-- パスワード照合の失敗を記録（1日より古い記録は掃除）
create or replace function public.account_reauth_failed(p_user uuid)
returns void
language sql security definer set search_path = ''
as $$
  insert into aimuse_private.reauth_failures (user_id) values (p_user);
  delete from aimuse_private.reauth_failures where at < now() - interval '1 day';
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
revoke all on function public.account_reauth_allowed(uuid) from public, anon, authenticated;
revoke all on function public.account_reauth_failed(uuid) from public, anon, authenticated;
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
    execute 'grant execute on function public.account_reauth_allowed(uuid) to service_role';
    execute 'grant execute on function public.account_reauth_failed(uuid) to service_role';
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
