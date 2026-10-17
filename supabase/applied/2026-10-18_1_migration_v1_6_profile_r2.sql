-- =====================================================================
-- AIMUSE v1.6 プロフィール編集（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・既存のテーブル・データ・関数は削除・変更しません（列・関数・保存場所・ルールの「追加」のみ）
--   ・何度実行しても壊れません
--   ・前提：AIMUSE 構築SQL（v1.5 r2）を実行済みであること。満たさない場合は何もせずに中止します
--   ・AIMUSE BOOST が使う is_admin()・profiles.is_admin・protect_profile_flags・tracks・covers は変更しません
--
-- 追加する内容
--   1. profiles にアイコン・背景画像の保存場所（avatar_path / header_path）を追加
--      → アプリから直接は書き換えられず、確認つきの関数 set_my_profile_image だけで変更できます
--   2. アーティスト名の変更履歴（aimuse_private.artist_name_history：アプリからは直接見えない場所）
--   3. 関数
--      set_my_profile_image  … 本人がアイコン・背景を設定／初期画像に戻す
--      rename_my_artist      … 本人がアーティスト名を変更（禁止語・なりすまし・回数制限・履歴）
--      public_artist_profiles… 公開中の曲があるアーティストのアイコン・背景だけを返す（未ログイン可）
--      admin_reset_profile_image / admin_set_artist_name / admin_artist_name_history … 管理者用
--   4. 画像の保存場所「avatars」（JPEG・PNG・WebP、1ファイル2MBまで、1人4ファイルまで）とアクセスルール
--      ファイル名は「avatar-ランダムID.jpg」「header-ランダムID.jpg」で、会員IDを含めません（公開URLから会員IDが分からない）
--      持ち主の確認は、Storage が保存時に自動で記録する owner_id（ログイン中の会員ID）で行います
--
-- r2（本番実行用）：全体を BEGIN〜COMMIT で囲みました。途中でエラーが出た場合は、それまでの変更もすべて取り消されます
--   エラーが出たときは、同じ画面の内容を消して「rollback;」だけを1回実行してから報告してください
-- =====================================================================

begin;

-- ---------- 0. 前提の確認（満たさなければ中止） ----------
do $$
begin
  if to_regclass('public.profiles') is null or to_regclass('public.artists') is null
     or to_regclass('public.tracks') is null or to_regclass('aimuse_private.settings') is null then
    raise exception 'AIMUSE の構築SQL（v1.5）が未実行です。中止しました。';
  end if;
  if to_regprocedure('public.is_admin()') is null or to_regprocedure('public.is_active_member()') is null
     or to_regprocedure('public.is_reserved_name(text)') is null then
    raise exception 'AIMUSE の関数（is_admin / is_active_member / is_reserved_name）が見つかりません。中止しました。';
  end if;
  if to_regclass('storage.objects') is null or to_regclass('storage.buckets') is null then
    raise exception 'Supabase Storage が見つかりません。中止しました。';
  end if;
end $$;


-- ---------- 1. profiles：アイコン・背景画像の保存場所 ----------
alter table public.profiles add column if not exists avatar_path text;
alter table public.profiles add column if not exists header_path text;
alter table public.profiles add column if not exists media_updated_at timestamptz;

-- 保存場所の形式チェック：「avatar-ランダムID.拡張子」「header-ランダムID.拡張子」のみ（会員IDは含めない）
-- 本人の画像であることは、設定時に set_my_profile_image が owner_id で確認します
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_avatar_path_chk' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_avatar_path_chk check (
      avatar_path is null or (
        avatar_path ~ '^avatar-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_header_path_chk' and conrelid = 'public.profiles'::regclass) then
    alter table public.profiles add constraint profiles_header_path_chk check (
      header_path is null or (
        header_path ~ '^header-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'));
  end if;
end $$;

-- 念のため：アプリ（会員・未ログイン）にこれらの列を直接書き換える権限を与えない
-- （profiles の更新権限は従来どおり display_name だけ。この SQL では付与しません）
revoke update (avatar_path, header_path, media_updated_at) on public.profiles from anon, authenticated;
revoke insert on public.profiles from anon, authenticated;


-- ---------- 2. アーティスト名の変更履歴（アプリから直接は読み書きできない場所） ----------
create table if not exists aimuse_private.artist_name_history (
  id uuid primary key default gen_random_uuid(),
  artist_id uuid not null references public.artists(id) on delete cascade,
  user_id uuid not null,               -- アーティストの持ち主
  changed_by uuid,                     -- 変更した人（本人 または 管理者）
  by_admin boolean not null default false,
  old_name text not null,
  new_name text not null,
  changed_at timestamptz not null default now()
);
create index if not exists artist_name_history_user_idx on aimuse_private.artist_name_history(user_id, changed_at);
create index if not exists artist_name_history_changed_idx on aimuse_private.artist_name_history(changed_at);
revoke all on aimuse_private.artist_name_history from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on aimuse_private.artist_name_history from anon, authenticated';
  end if;
end $$;
alter table aimuse_private.artist_name_history enable row level security;  -- ポリシーなし＝アプリから直接アクセス不可


-- ---------- 3. 関数 ----------

-- アーティスト名の比較用（全角・半角、大文字・小文字、空白の違いを無視）
create or replace function public.artist_name_key(n text)
returns text
language sql immutable set search_path = ''
as $$
  select lower(regexp_replace(normalize(coalesce(n, ''), NFKC), '[\s\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]+', '', 'g'));
$$;

-- アーティスト名の整形（前後の空白を除き、連続する空白を1つに）
create or replace function public.artist_name_clean(n text)
returns text
language sql immutable set search_path = ''
as $$
  select btrim(regexp_replace(coalesce(n, ''), '\s+', ' ', 'g'));
$$;

-- アイコン・背景の設定（本人のみ。p_path = null で初期画像に戻す）
--   ・保存場所が「種類-ランダムID.拡張子」であること
--   ・その画像が avatars に実際に保存されていて、持ち主（owner_id）が本人であること
--   を確認してから設定し、それまで使っていた画像の場所を返します（アプリはその後で古い画像を削除）
create or replace function public.set_my_profile_image(p_kind text, p_path text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_old text;
begin
  if v_uid is null or not public.is_active_member() then
    raise exception 'プロフィールを変更できません（ログイン状態・メール確認・利用状況を確認してください）';
  end if;
  if p_kind is null or p_kind not in ('avatar', 'header') then
    raise exception '画像の種類が正しくありません';
  end if;
  if p_path is not null then
    if p_path !~ ('^' || p_kind || '-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$') then
      raise exception '画像の保存場所が正しくありません';
    end if;
    if not exists (select 1 from storage.objects o
                   where o.bucket_id = 'avatars' and o.name = p_path and o.owner_id = v_uid::text) then
      raise exception '画像が保存されていないか、あなたの画像ではありません';
    end if;
  end if;

  select case when p_kind = 'avatar' then p.avatar_path else p.header_path end
    into v_old
  from public.profiles p where p.id = v_uid
  for update;
  if not found then
    raise exception 'プロフィールが見つかりません';
  end if;

  if p_kind = 'avatar' then
    update public.profiles set avatar_path = p_path, media_updated_at = now() where id = v_uid;
  else
    update public.profiles set header_path = p_path, media_updated_at = now() where id = v_uid;
  end if;
  return v_old;
end;
$$;

-- アーティスト名の変更（本人のみ・即時反映）
--   ・1〜40文字、制御文字・見えない文字（ゼロ幅スペース等）なし
--   ・運営になりすます言葉（AIMUSE・運営・公式・管理者 など）は使用不可
--   ・他の会員のアーティスト名と同じ名前（全角半角・大文字小文字・空白の違いを無視）は使用不可
--   ・24時間に3回まで
--   ・変更前と変更後の名前を履歴に保存し、そのアーティストの曲の表示名もまとめて変更
create or replace function public.rename_my_artist(p_artist uuid, p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_old text;
  v_new text := public.artist_name_clean(p_name);
begin
  if v_uid is null or not public.is_active_member() then
    raise exception 'アーティスト名を変更できません（ログイン状態・メール確認・利用状況を確認してください）';
  end if;
  if char_length(v_new) < 1 or char_length(v_new) > 40 then
    raise exception 'アーティスト名は1〜40文字で入力してください';
  end if;
  -- 制御文字・見えない文字（ゼロ幅スペース・文字の向きを変える記号など）は、なりすましに使われるため不可
  if v_new ~ '[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]' then
    raise exception 'アーティスト名に使用できない文字が含まれています';
  end if;

  -- 同じ会員の変更を1件ずつ処理（回数制限のすり抜け防止）
  perform pg_advisory_xact_lock(hashtextextended('aimuse_artist_rename:' || v_uid::text, 0));

  select a.user_id, a.name into v_owner, v_old
  from public.artists a where a.id = p_artist
  for update;
  if not found or v_owner is distinct from v_uid then
    raise exception 'アーティストが見つかりません';
  end if;
  if v_old = v_new then
    return v_new;
  end if;

  if public.is_reserved_name(v_new)
     or exists (select 1 from public.artists a
                where a.user_id <> v_uid
                  and public.artist_name_key(a.name) = public.artist_name_key(v_new)) then
    raise exception 'このアーティスト名は使用できません（運営と誤解される言葉を含む、または他の会員が使用しています）';
  end if;
  if exists (select 1 from public.artists a
             where a.user_id = v_uid and a.id <> p_artist
               and public.artist_name_key(a.name) = public.artist_name_key(v_new)) then
    raise exception 'あなたの別のアーティストで同じ名前を使用しています';
  end if;
  if (select count(*) from aimuse_private.artist_name_history h
      where h.user_id = v_uid and not h.by_admin and h.changed_at > now() - interval '24 hours') >= 3 then
    raise exception 'アーティスト名の変更は24時間に3回までです。時間をおいてから変更してください';
  end if;

  update public.artists set name = v_new where id = p_artist;
  update public.tracks set artist = v_new where artist_id = p_artist;
  insert into aimuse_private.artist_name_history (artist_id, user_id, changed_by, by_admin, old_name, new_name)
  values (p_artist, v_uid, v_uid, false, v_old, v_new);
  return v_new;
end;
$$;

-- 公開用：公開中の曲があるアーティストのアイコン・背景の保存場所だけを返す（未ログインでも利用可）
--   メールアドレス・表示名・会員ID・管理者フラグなどは返しません。利用停止中の会員の画像は返しません
create or replace function public.public_artist_profiles(p_artist_ids uuid[])
returns table (artist_id uuid, avatar_path text, header_path text)
language sql stable security definer set search_path = ''
as $$
  select a.id, p.avatar_path, p.header_path
  from public.artists a
  join public.profiles p on p.id = a.user_id
  where a.id = any ((coalesce(p_artist_ids, '{}'::uuid[]))[1:200])
    and not p.is_banned
    and (p.avatar_path is not null or p.header_path is not null)
    and exists (select 1 from public.tracks t where t.artist_id = a.id and t.status = 'public');
$$;

-- 管理者用：アーティストの持ち主のアイコン・背景を初期画像に戻す（それまでの画像の場所を返す）
create or replace function public.admin_reset_profile_image(p_artist uuid, p_kind text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_old text;
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  if p_kind is null or p_kind not in ('avatar', 'header') then
    raise exception '画像の種類が正しくありません';
  end if;
  select a.user_id into v_uid from public.artists a where a.id = p_artist;
  if v_uid is null then
    raise exception 'アーティストが見つかりません';
  end if;
  select case when p_kind = 'avatar' then p.avatar_path else p.header_path end
    into v_old
  from public.profiles p where p.id = v_uid
  for update;
  if p_kind = 'avatar' then
    update public.profiles set avatar_path = null, media_updated_at = now() where id = v_uid;
  else
    update public.profiles set header_path = null, media_updated_at = now() where id = v_uid;
  end if;
  return v_old;
end;
$$;

-- 管理者用：アーティスト名を変更（なりすましの是正など。履歴に「管理者による変更」として保存）
create or replace function public.admin_set_artist_name(p_artist uuid, p_name text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_old text;
  v_new text := public.artist_name_clean(p_name);
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  if char_length(v_new) < 1 or char_length(v_new) > 40
     or v_new ~ '[[:cntrl:]\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]' then
    raise exception 'アーティスト名は1〜40文字で入力してください';
  end if;
  select a.user_id, a.name into v_uid, v_old from public.artists a where a.id = p_artist for update;
  if not found then
    raise exception 'アーティストが見つかりません';
  end if;
  if v_old = v_new then
    return v_new;
  end if;
  if exists (select 1 from public.artists a
             where a.user_id = v_uid and a.id <> p_artist and a.name = v_new) then
    raise exception 'この会員の別のアーティストで同じ名前を使用しています';
  end if;
  update public.artists set name = v_new where id = p_artist;
  update public.tracks set artist = v_new where artist_id = p_artist;
  insert into aimuse_private.artist_name_history (artist_id, user_id, changed_by, by_admin, old_name, new_name)
  values (p_artist, v_uid, auth.uid(), true, v_old, v_new);
  return v_new;
end;
$$;

-- 管理者用：アーティスト名の変更履歴（新しい順）
create or replace function public.admin_artist_name_history(p_limit integer default 100)
returns table (changed_at timestamptz, artist_id uuid, current_name text, old_name text, new_name text, by_admin boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  return query
    select h.changed_at, h.artist_id, a.name, h.old_name, h.new_name, h.by_admin
    from aimuse_private.artist_name_history h
    join public.artists a on a.id = h.artist_id
    order by h.changed_at desc
    limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

-- avatars に保存できるか：書き込みできる会員・本人の画像が4ファイル未満
create or replace function public.avatar_can_upload()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_active_member()
     and (select count(*) from storage.objects o
          where o.bucket_id = 'avatars' and o.owner_id = auth.uid()::text) < 4;
$$;

-- avatars から削除できるか：管理者、または本人の画像のうち「プロフィールで使用中でない」もの
-- （使用中の画像を先に消してプロフィールが壊れる事故を防ぐ）
create or replace function public.avatar_can_delete(object_name text, object_owner text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_admin()
      or (auth.uid() is not null
          and object_owner = auth.uid()::text
          and not exists (select 1 from public.profiles p
                          where p.avatar_path = object_name or p.header_path = object_name));
$$;

-- 関数の実行権限：まず全員から外し、必要なものだけ許可
revoke all on function public.artist_name_key(text) from public, anon, authenticated;
revoke all on function public.artist_name_clean(text) from public, anon, authenticated;
revoke all on function public.set_my_profile_image(text, text) from public, anon, authenticated;
revoke all on function public.rename_my_artist(uuid, text) from public, anon, authenticated;
revoke all on function public.public_artist_profiles(uuid[]) from public, anon, authenticated;
revoke all on function public.admin_reset_profile_image(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_set_artist_name(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_artist_name_history(integer) from public, anon, authenticated;
revoke all on function public.avatar_can_upload() from public, anon, authenticated;
revoke all on function public.avatar_can_delete(text, text) from public, anon, authenticated;
grant execute on function public.public_artist_profiles(uuid[]) to anon, authenticated;
grant execute on function public.set_my_profile_image(text, text) to authenticated;
grant execute on function public.rename_my_artist(uuid, text) to authenticated;
grant execute on function public.admin_reset_profile_image(uuid, text) to authenticated;
grant execute on function public.admin_set_artist_name(uuid, text) to authenticated;
grant execute on function public.admin_artist_name_history(integer) to authenticated;
grant execute on function public.avatar_can_upload() to authenticated;
grant execute on function public.avatar_can_delete(text, text) to authenticated;


-- ---------- 4. 画像の保存場所「avatars」とアクセスルール ----------
-- アイコン・背景は誰にでも表示する画像のため「公開」の保存場所にします
-- （ファイル名はランダムで推測できません。音源・ジャケットの保存場所は非公開のまま変更しません）
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 保存：「avatar-ランダムID」「header-ランダムID」の名前で新規保存のみ（上書き不可）。持ち主は本人
drop policy if exists "aimuse avatars upload own" on storage.objects;
create policy "aimuse avatars upload own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and name ~ '^(avatar|header)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
    and owner_id = auth.uid()::text
    and public.avatar_can_upload()
  );

-- 一覧・削除の対象にできる範囲：本人の画像、または管理者
--（画像の表示は公開URLで行うため、この範囲は表示には影響しません）
drop policy if exists "aimuse avatars select own" on storage.objects;
create policy "aimuse avatars select own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and (owner_id = auth.uid()::text or public.is_admin())
  );

-- 削除：管理者、または本人の「使用中でない」画像のみ
drop policy if exists "aimuse avatars delete own" on storage.objects;
create policy "aimuse avatars delete own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and public.avatar_can_delete(name, owner_id)
  );

-- データベース内部の関数（ファイル数の上限・保存済みの確認）が avatars のファイルを数えられるようにする
-- 対象は SQL Editor の管理用ロール postgres のみ。アプリの利用者には影響しません
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'postgres') then
    execute 'drop policy if exists "aimuse avatars internal read" on storage.objects';
    execute 'create policy "aimuse avatars internal read" on storage.objects for select to postgres using (bucket_id = ''avatars'')';
  end if;
end $$;

-- 上書き更新は誰にも許可しません（更新用のポリシーは作りません）

-- APIに変更を即時反映（COMMIT の時点で通知されます）
notify pgrst, 'reload schema';

commit;

-- =====================================================================
-- 完了
-- =====================================================================
