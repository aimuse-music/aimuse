-- =====================================================================
-- AIMUSE v1.11 プレイリスト（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・既存のテーブル・データ・関数・アクセスルールは変更しません（表2つと関数の「追加」のみ）
--   ・何度実行しても壊れません。全体を BEGIN〜COMMIT で囲んでいます（途中でエラーなら全体を取り消し）
--   ・前提：v1.9（楽曲の削除・退会）まで適用済みであること。満たさない場合は何もせずに中止します
--   ・AIMUSE BOOST の表・関数には触れません
--
-- 仕組み
--   ・表 playlists / playlist_tracks はアプリから直接は読み書きできません（RLS 有効・ルールなし・権限なし）
--   ・読み書きはすべて下の関数経由。会員IDは返しません
--       my_playlists()                       … 自分のプレイリスト（非公開を含む）と曲の並び
--       public_playlists(p_limit)            … 公開プレイリスト（公開中の曲だけ。未ログインでも可）
--       create_playlist(p_name, p_public)    … 作成（1人50個まで・名前1〜40文字）
--       update_playlist(p_id, p_name, p_public) … 名前・公開設定の変更（null の項目は変更しない）
--       delete_playlist(p_id)                … 削除
--       playlist_add_track(p_id, p_track)    … 曲を末尾に追加（公開中の曲だけ・1つに200曲まで・重複は無視）
--       playlist_remove_track(p_id, p_track) … 曲を外す
--   ・書き込みは「書き込みできる会員」（メール確認済み・利用停止でない・退会手続き中でない）だけ
--   ・会員を削除すると、その会員のプレイリストも消えます。曲が削除されると、各プレイリストからも外れます
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.is_active_member()') is null or to_regclass('aimuse_private.account_deletions') is null then
    raise exception 'v1.9 が未適用です。何も変更せずに中止しました。';
  end if;
end $$;

create table if not exists public.playlists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists playlists_user_idx on public.playlists(user_id, created_at);
create index if not exists playlists_public_idx on public.playlists(updated_at desc) where is_public;

create table if not exists public.playlist_tracks (
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  position integer not null,
  added_at timestamptz not null default now(),
  primary key (playlist_id, track_id)
);
create index if not exists playlist_tracks_track_idx on public.playlist_tracks(track_id);

-- アプリから直接は読み書きできない（関数経由のみ）
alter table public.playlists enable row level security;
alter table public.playlist_tracks enable row level security;
revoke all on public.playlists, public.playlist_tracks from public, anon, authenticated;

-- 名前の整形と確認（前後の空白を除く・1〜40文字・制御文字や見えない文字は不可）
create or replace function aimuse_private.playlist_name(p_name text)
returns text
language plpgsql immutable set search_path = ''
as $$
declare v text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if char_length(v) < 1 or char_length(v) > 40 then
    raise exception 'プレイリスト名は1〜40文字で入力してください';
  end if;
  if v ~ '[[:cntrl:]​-‏‪-‮⁠-⁤﻿]' then
    raise exception 'プレイリスト名に使用できない文字が含まれています';
  end if;
  return v;
end;
$$;

-- 自分のプレイリストを書き換えられるか（書き込みできる会員で、持ち主であること）
create or replace function aimuse_private.playlist_owned(p_id uuid)
returns void
language plpgsql set search_path = ''
as $$
begin
  if auth.uid() is null or not public.is_active_member() then
    raise exception 'プレイリストを変更できません（ログイン状態・メール確認・利用状況を確認してください）';
  end if;
  if not exists (select 1 from public.playlists p where p.id = p_id and p.user_id = auth.uid()) then
    raise exception 'プレイリストが見つかりません';
  end if;
end;
$$;

create or replace function public.my_playlists()
returns table (id uuid, name text, is_public boolean, updated_at timestamptz, track_ids uuid[])
language sql stable security definer set search_path = ''
as $$
  select p.id, p.name, p.is_public, p.updated_at,
         coalesce((select array_agg(pt.track_id order by pt.position) from public.playlist_tracks pt where pt.playlist_id = p.id), '{}')
  from public.playlists p
  where p.user_id = auth.uid()
  order by p.created_at;
$$;

-- 公開プレイリスト：持ち主が利用停止・退会手続き中のものは出さない。曲は公開中のものだけ。曲が0件のものは出さない
create or replace function public.public_playlists(p_limit integer default 30)
returns table (id uuid, name text, updated_at timestamptz, track_ids uuid[])
language sql stable security definer set search_path = ''
as $$
  select x.id, x.name, x.updated_at, x.ids from (
    select p.id, p.name, p.updated_at,
           coalesce((select array_agg(pt.track_id order by pt.position) from public.playlist_tracks pt
                     join public.tracks t on t.id = pt.track_id and t.status = 'public'
                     where pt.playlist_id = p.id), '{}') as ids
    from public.playlists p
    join public.profiles pr on pr.id = p.user_id
    where p.is_public and not pr.is_banned
      and not exists (select 1 from aimuse_private.account_deletions d
                      where d.user_id = p.user_id and d.status in ('pending', 'processing', 'failed'))
  ) x
  where cardinality(x.ids) > 0
  order by x.updated_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

create or replace function public.create_playlist(p_name text, p_public boolean default false)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null or not public.is_active_member() then
    raise exception 'プレイリストを作成できません（ログイン状態・メール確認・利用状況を確認してください）';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_playlist:' || v_uid::text, 0));
  if (select count(*) from public.playlists where user_id = v_uid) >= 50 then
    raise exception 'プレイリストは1人50個までです';
  end if;
  insert into public.playlists (user_id, name, is_public)
  values (v_uid, aimuse_private.playlist_name(p_name), coalesce(p_public, false))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.update_playlist(p_id uuid, p_name text default null, p_public boolean default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform aimuse_private.playlist_owned(p_id);
  update public.playlists
     set name = case when p_name is null then name else aimuse_private.playlist_name(p_name) end,
         is_public = coalesce(p_public, is_public),
         updated_at = now()
   where id = p_id and user_id = auth.uid();
end;
$$;

create or replace function public.delete_playlist(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform aimuse_private.playlist_owned(p_id);
  delete from public.playlists where id = p_id and user_id = auth.uid();
end;
$$;

create or replace function public.playlist_add_track(p_id uuid, p_track uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform aimuse_private.playlist_owned(p_id);
  if not exists (select 1 from public.tracks t where t.id = p_track and t.status = 'public') then
    raise exception '公開中の曲だけ追加できます';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_playlist_tracks:' || p_id::text, 0));
  if exists (select 1 from public.playlist_tracks where playlist_id = p_id and track_id = p_track) then
    return;   -- すでに入っている（二重タップなど）
  end if;
  if (select count(*) from public.playlist_tracks where playlist_id = p_id) >= 200 then
    raise exception '1つのプレイリストに入れられる曲は200曲までです';
  end if;
  insert into public.playlist_tracks (playlist_id, track_id, position)
  values (p_id, p_track, coalesce((select max(position) from public.playlist_tracks where playlist_id = p_id), 0) + 1);
  update public.playlists set updated_at = now() where id = p_id;
end;
$$;

create or replace function public.playlist_remove_track(p_id uuid, p_track uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform aimuse_private.playlist_owned(p_id);
  delete from public.playlist_tracks where playlist_id = p_id and track_id = p_track;
  update public.playlists set updated_at = now() where id = p_id;
end;
$$;

-- 関数の実行権限：まず全員から外し、必要なものだけ許可
revoke all on function aimuse_private.playlist_name(text) from public;
revoke all on function aimuse_private.playlist_owned(uuid) from public;
revoke all on function public.my_playlists() from public, anon, authenticated;
revoke all on function public.public_playlists(integer) from public, anon, authenticated;
revoke all on function public.create_playlist(text, boolean) from public, anon, authenticated;
revoke all on function public.update_playlist(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.delete_playlist(uuid) from public, anon, authenticated;
revoke all on function public.playlist_add_track(uuid, uuid) from public, anon, authenticated;
revoke all on function public.playlist_remove_track(uuid, uuid) from public, anon, authenticated;
grant execute on function public.public_playlists(integer) to anon, authenticated;
grant execute on function public.my_playlists() to authenticated;
grant execute on function public.create_playlist(text, boolean) to authenticated;
grant execute on function public.update_playlist(uuid, text, boolean) to authenticated;
grant execute on function public.delete_playlist(uuid) to authenticated;
grant execute on function public.playlist_add_track(uuid, uuid) to authenticated;
grant execute on function public.playlist_remove_track(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
