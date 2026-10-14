-- =====================================================================
-- AIMUSE 本番データベース 構築SQL（v1.5 最終版・安全な削除対応 r2）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
-- ・何度実行しても壊れません（テーブルの削除・データの削除は行いません）
-- ・架空のデータは一切追加しません
-- ・メール認証の必須化、CAPTCHA、URL設定は SQL ではなく
--   Supabase の管理画面で設定します（手順は別途案内）
-- =====================================================================


-- =====================================================================
-- 0. 非公開の設定置き場（アプリからは一切見えない場所）
--    再生数の判定に使う秘密の値などを保存します。
-- =====================================================================
create schema if not exists aimuse_private;
revoke all on schema aimuse_private from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema aimuse_private from anon, authenticated';
  end if;
end $$;

create table if not exists aimuse_private.settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
revoke all on aimuse_private.settings from public;

-- IPアドレスを保存せずに済むよう、ハッシュ化に使う秘密の値（初回のみ生成）
insert into aimuse_private.settings (key, value)
values ('play_salt', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
on conflict (key) do nothing;

-- 楽曲の削除記録（誤って削除した曲を30日以内なら復元できるよう、削除時の内容を保存）
create table if not exists aimuse_private.track_deletions (
  id uuid primary key default gen_random_uuid(),
  track_id uuid not null,
  track jsonb not null,
  reviews jsonb not null default '[]'::jsonb,
  report_count integer not null default 0,
  deleted_by uuid,
  deleted_at timestamptz not null default now(),
  restored_at timestamptz
);
create index if not exists track_deletions_deleted_at_idx on aimuse_private.track_deletions(deleted_at);
revoke all on aimuse_private.track_deletions from public;

-- 未ログイン利用者の判定に使うHTTPヘッダー
--   初期値は Cloudflare が付ける cf-connecting-ip だけを信頼します。
--   X-Forwarded-For・X-Real-IP は利用者が偽装できる可能性があるため使いません。
--   本番で「偽装できないこと」を確認するまでは、未ログインの再生は数えられない場合があります。
insert into aimuse_private.settings (key, value)
values ('client_ip_headers', 'cf-connecting-ip')
on conflict (key) do nothing;


-- =====================================================================
-- 1. 会員プロフィール（profiles）
--    会員登録すると自動で1行作られます。
--    is_admin（管理者）・is_banned（利用停止）はアプリから変更できません。
-- =====================================================================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (display_name is null or char_length(display_name) <= 40),
  is_admin boolean not null default false,
  is_banned boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists is_banned boolean not null default false;

-- 運営になりすます名前かどうか（全角・半角、大文字・小文字を区別せず判定）
create or replace function public.is_reserved_name(n text)
returns boolean
language sql immutable set search_path = ''
as $$
  select coalesce(lower(normalize(n, NFKC)) ~ '(aimuse|運営|管理者|公式|admin|staff|スタッフ)', false);
$$;

-- 管理者かどうか
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;

-- 書き込みできる会員か（ログイン済み・メール認証済み・利用停止でない）
create or replace function public.is_active_member()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null
     and exists (select 1 from auth.users u
                 where u.id = auth.uid() and u.email_confirmed_at is not null)
     and not coalesce((select p.is_banned from public.profiles p where p.id = auth.uid()), true);
$$;

-- 会員登録時にプロフィールを自動作成（管理者権限は必ず false）
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_name text;
begin
  v_name := left(coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), split_part(new.email, '@', 1)), 40);
  if public.is_reserved_name(v_name) then
    v_name := '会員';
  end if;
  insert into public.profiles (id, display_name, is_admin, is_banned)
  values (new.id, v_name, false, false)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- auth.users のトリガーは削除・作り直しをせず、無い場合だけ作成
-- （Supabase では auth.users の所有者ではないため、既存トリガーの削除は権限エラーになる）
do $$ begin
  if not exists (select 1 from pg_trigger
                 where tgname = 'on_auth_user_created' and tgrelid = 'auth.users'::regclass) then
    create trigger on_auth_user_created
      after insert on auth.users
      for each row execute function public.handle_new_user();
  end if;
end $$;

-- すでに登録済みの会員がいれば、プロフィールを作成（既存の行は変更しない）
insert into public.profiles (id, display_name, is_admin, is_banned)
select u.id, left(split_part(u.email, '@', 1), 40), false, false
from auth.users u
on conflict (id) do nothing;

-- 管理者・利用停止フラグの書き換え防止
--   is_admin  ：アプリ経由では誰も変更不可（SQL Editor でのみ変更）
--   is_banned ：管理者用の関数経由でのみ変更可
--   表示名     ：運営になりすます名前（AIMUSE・運営・管理者 など）は使用不可
create or replace function public.protect_profile_flags()
returns trigger
language plpgsql set search_path = ''
as $$
declare
  v_role text := coalesce(auth.jwt()->>'role', '');
begin
  if new.id is distinct from old.id then
    raise exception '会員IDは変更できません';
  end if;
  if new.is_admin is distinct from old.is_admin and v_role in ('anon', 'authenticated') then
    raise exception '管理者権限はアプリから変更できません';
  end if;
  if new.is_banned is distinct from old.is_banned and v_role in ('anon', 'authenticated')
     and not public.is_admin() then
    raise exception '利用停止の設定は管理者のみ変更できます';
  end if;
  if new.display_name is distinct from old.display_name and v_role in ('anon', 'authenticated')
     and not public.is_admin() and public.is_reserved_name(new.display_name) then
    raise exception '表示名に使用できない言葉が含まれています';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_admin on public.profiles;
drop trigger if exists profiles_protect_flags on public.profiles;
create trigger profiles_protect_flags
  before update on public.profiles
  for each row execute function public.protect_profile_flags();


-- =====================================================================
-- 2. アーティスト（artists）
--    楽曲投稿時に「会員 × アーティスト名」で自動作成されます。
--    他の会員が同じ名前を使っても、別のアーティストとして扱います。
-- =====================================================================
create table if not exists public.artists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  bio text not null default '' check (char_length(bio) <= 500),
  created_at timestamptz not null default now(),
  unique (user_id, name)
);
create index if not exists artists_user_idx on public.artists(user_id);


-- =====================================================================
-- 3. 楽曲（tracks）
--    status：pending=審査待ち / public=公開中 / hidden=非公開 / rejected=却下
--    却下理由（reject_reason）は投稿者本人が確認できます。
-- =====================================================================
create table if not exists public.tracks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  artist_id uuid references public.artists(id) on delete set null,
  title text not null check (char_length(title) between 1 and 60),
  artist text not null check (char_length(artist) between 1 and 40),
  genre text not null check (char_length(genre) between 1 and 40),
  tool text not null check (char_length(tool) between 1 and 40),
  tool_name text not null check (char_length(tool_name) between 1 and 60),
  audio_path text not null,
  audio_name text,
  audio_size bigint check (audio_size is null or audio_size between 0 and 52428800),
  audio_ext text,
  audio_sha256 text check (audio_sha256 is null or audio_sha256 ~ '^[0-9a-f]{64}$'),
  duration integer not null default 0 check (duration between 0 and 3600),
  image_path text,
  image_name text,
  lyrics text[] not null default '{}',
  checks boolean[] not null default '{}',
  status text not null default 'pending' check (status in ('pending', 'public', 'hidden', 'rejected')),
  reject_reason text,
  plays integer not null default 0 check (plays >= 0),
  hues integer[] not null default '{270,230}',
  pattern integer not null default 0,
  submitted_at text,
  approved_at text,
  reviewed_at text,
  created_at timestamptz not null default now()
);
alter table public.tracks add column if not exists artist_id uuid references public.artists(id) on delete set null;
alter table public.tracks add column if not exists audio_sha256 text check (audio_sha256 is null or audio_sha256 ~ '^[0-9a-f]{64}$');
create unique index if not exists tracks_audio_path_key on public.tracks(audio_path);
create unique index if not exists tracks_image_path_key on public.tracks(image_path);
-- 同じ音源ファイルの二重投稿を防止（アプリがファイルの指紋を送った場合）
create unique index if not exists tracks_user_audio_sha256_key on public.tracks(user_id, audio_sha256)
  where audio_sha256 is not null;
create index if not exists tracks_status_idx on public.tracks(status);
create index if not exists tracks_user_idx on public.tracks(user_id);
create index if not exists tracks_artist_idx on public.tracks(artist_id);
create index if not exists tracks_user_created_idx on public.tracks(user_id, created_at);

-- 投稿時の安全処理
--   一般会員は必ず「審査待ち・再生数0」で登録
--   審査待ちは1人10曲まで、投稿は1人24時間で20曲まで（同時投稿でもすり抜けない）
--   運営になりすますアーティスト名は使用不可
--   アーティストを自動作成
create or replace function public.tracks_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_artist_id uuid;
begin
  -- アプリ経由（未ログイン・一般会員）の投稿にだけ制限をかける
  -- 管理者、および SQL Editor からの管理作業（復元など）は対象外
  if coalesce(auth.jwt()->>'role', '') in ('anon', 'authenticated') and not public.is_admin() then
    new.status := 'pending';
    new.plays := 0;
    new.reject_reason := null;
    new.approved_at := null;
    new.reviewed_at := null;
    new.created_at := now();
    if public.is_reserved_name(new.artist) then
      raise exception 'このアーティスト名は使用できません';
    end if;
    -- 同じ会員の同時投稿を1件ずつ処理し、上限のすり抜けを防ぐ
    perform pg_advisory_xact_lock(hashtextextended('aimuse_tracks:' || new.user_id::text, 0));
    if (select count(*) from public.tracks t
        where t.user_id = new.user_id and t.status = 'pending') >= 10 then
      raise exception '審査待ちの楽曲は1人10曲までです';
    end if;
    if (select count(*) from public.tracks t
        where t.user_id = new.user_id and t.created_at > now() - interval '24 hours') >= 20 then
      raise exception '投稿は24時間に20曲までです';
    end if;
  end if;

  insert into public.artists (user_id, name)
  values (new.user_id, new.artist)
  on conflict (user_id, name) do update set name = excluded.name
  returning id into v_artist_id;
  new.artist_id := v_artist_id;

  return new;
end;
$$;

drop trigger if exists tracks_before_insert on public.tracks;
create trigger tracks_before_insert
  before insert on public.tracks
  for each row execute function public.tracks_before_insert();

-- 更新時の安全処理：投稿者・音源/画像の保存先・投稿日時は管理者でも変更不可
create or replace function public.tracks_before_update()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.user_id is distinct from old.user_id
     or new.audio_path is distinct from old.audio_path
     or new.image_path is distinct from old.image_path
     or new.audio_sha256 is distinct from old.audio_sha256
     or new.created_at is distinct from old.created_at then
    raise exception '投稿者・音源・画像・投稿日時は変更できません';
  end if;
  return new;
end;
$$;

drop trigger if exists tracks_before_update on public.tracks;
create trigger tracks_before_update
  before update on public.tracks
  for each row execute function public.tracks_before_update();

-- 削除時の安全処理
--   ・公開中の曲は削除できません（先に「非公開」にする2段階方式）
--     ※ 会員そのものを削除した場合（その会員の曲がまとめて消える場合）は例外として削除できます
--   ・削除時の内容（曲の情報・レビュー・通報件数）を30日間保存し、管理者が復元できます
--   ・音源・画像ファイルはすぐには消さず、30日を過ぎてから整理します
create or replace function public.tracks_before_delete()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if pg_trigger_depth() = 1 and old.status = 'public' then
    raise exception '公開中の楽曲は削除できません。先に非公開にしてください';
  end if;
  insert into aimuse_private.track_deletions (track_id, track, reviews, report_count, deleted_by)
  values (
    old.id,
    to_jsonb(old),
    coalesce((select jsonb_agg(to_jsonb(r)) from public.reviews r where r.track_id = old.id), '[]'::jsonb),
    (select count(*) from public.reports rp where rp.song_id = old.id),
    auth.uid()
  );
  delete from aimuse_private.track_deletions where deleted_at < now() - interval '30 days';
  return old;
end;
$$;

drop trigger if exists tracks_before_delete on public.tracks;
create trigger tracks_before_delete
  before delete on public.tracks
  for each row execute function public.tracks_before_delete();


-- =====================================================================
-- 4. お気に入り（favorites）
-- =====================================================================
create table if not exists public.favorites (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, track_id)
);
create index if not exists favorites_track_idx on public.favorites(track_id);


-- =====================================================================
-- 5. フォロー（follows）
-- =====================================================================
create table if not exists public.follows (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  artist_id uuid not null references public.artists(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, artist_id)
);
create index if not exists follows_artist_idx on public.follows(artist_id);

-- フォロワー数（誰がフォローしているかは公開せず、人数だけ返す）
create or replace function public.artist_follower_count(aid uuid)
returns integer
language sql stable security definer set search_path = ''
as $$
  select count(*)::integer from public.follows f where f.artist_id = aid;
$$;


-- =====================================================================
-- 6. レビュー（reviews）：5段階評価とコメント（1人1曲1件まで）
-- =====================================================================
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  track_id uuid not null references public.tracks(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  rating smallint not null check (rating between 1 and 5),
  comment text not null default '' check (char_length(comment) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (track_id, user_id)
);
create index if not exists reviews_track_idx on public.reviews(track_id);

create or replace function public.reviews_touch()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.track_id is distinct from old.track_id or new.user_id is distinct from old.user_id then
    raise exception 'レビューの対象曲・投稿者は変更できません';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists reviews_touch on public.reviews;
create trigger reviews_touch
  before update on public.reviews
  for each row execute function public.reviews_touch();

-- 公開中の曲のレビュー一覧（投稿者の表示名つき。メールアドレス等は返さない）
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
  order by r.created_at desc
  limit 200;
$$;

-- 公開中の曲の平均評価と件数
create or replace function public.track_rating_summary(tid uuid)
returns table (average numeric, total integer)
language sql stable security definer set search_path = ''
as $$
  select round(avg(r.rating)::numeric, 1), count(*)::integer
  from public.reviews r
  join public.tracks t on t.id = r.track_id
  left join public.profiles p on p.id = r.user_id
  where r.track_id = tid and t.status = 'public' and not coalesce(p.is_banned, false);
$$;


-- =====================================================================
-- 7. 通報（reports）
-- =====================================================================
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  song_id uuid not null references public.tracks(id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 100),
  reporter_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reporter_name text,
  at text,
  status text not null default 'open' check (status in ('open', 'resolved')),
  action text,
  resolved_at text,
  created_at timestamptz not null default now()
);
create index if not exists reports_song_idx on public.reports(song_id);
create index if not exists reports_status_idx on public.reports(status);
create index if not exists reports_reporter_created_idx on public.reports(reporter_id, created_at);

-- 通報時の安全処理
--   通報者名はプロフィールから自動設定（なりすまし防止）
--   同じ曲への未対応の重複通報は、エラーにせず登録しない
--   通報は1人24時間で30件まで
create or replace function public.reports_before_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(auth.jwt()->>'role', '') in ('anon', 'authenticated') and not public.is_admin() then
    new.status := 'open';
    new.action := null;
    new.resolved_at := null;
    new.created_at := now();
    perform pg_advisory_xact_lock(hashtextextended('aimuse_reports:' || new.reporter_id::text, 0));
    if (select count(*) from public.reports r
        where r.reporter_id = new.reporter_id and r.created_at > now() - interval '24 hours') >= 30 then
      raise exception '通報は24時間に30件までです';
    end if;
  end if;
  if exists (select 1 from public.reports r
             where r.song_id = new.song_id and r.reporter_id = new.reporter_id and r.status = 'open') then
    return null;
  end if;
  new.reporter_name := coalesce(
    (select p.display_name from public.profiles p where p.id = new.reporter_id),
    '会員'
  );
  return new;
end;
$$;

drop trigger if exists reports_before_insert on public.reports;
create trigger reports_before_insert
  before insert on public.reports
  for each row execute function public.reports_before_insert();


-- =====================================================================
-- 8. 再生数・再生時間
--    ・公開中の曲だけ数えます
--    ・「同じ人 × 同じ曲」は1時間に1回まで
--    ・同じ人が数えられるのは1時間に合計60回まで（大量アクセス対策）
--    ・ログイン中は会員ID、未ログインはIPアドレスで判定
--      IPアドレスは秘密の値でハッシュ化して保存し、2日で削除します
--      利用者が偽装できる可能性のある X-Forwarded-For・X-Real-IP は使いません
--    ・再生記録の表に直接アクセスすることは誰にもできません
-- =====================================================================
create table if not exists public.play_events (
  track_id uuid not null references public.tracks(id) on delete cascade,
  viewer_key text not null,
  window_start timestamptz not null,
  created_at timestamptz not null default now(),
  primary key (track_id, viewer_key, window_start)
);
create index if not exists play_events_created_idx on public.play_events(created_at);
create index if not exists play_events_viewer_idx on public.play_events(viewer_key, window_start);

create or replace function public.request_viewer_key()
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_headers json;
  v_header text;
  v_ip text;
  v_salt text;
begin
  if auth.uid() is not null then
    return 'u:' || auth.uid()::text;
  end if;
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  if v_headers is null then
    return null;
  end if;
  for v_header in
    select trim(h) from unnest(string_to_array(
      coalesce((select s.value from aimuse_private.settings s where s.key = 'client_ip_headers'),
               'cf-connecting-ip'), ',')) as h
  loop
    v_ip := nullif(trim(v_headers->>lower(v_header)), '');
    exit when v_ip is not null;
  end loop;
  if v_ip is null or v_ip !~ '^[0-9a-fA-F:.]{3,45}$' then
    return null;
  end if;
  v_salt := (select s.value from aimuse_private.settings s where s.key = 'play_salt');
  return 'ip:' || encode(sha256(convert_to(coalesce(v_salt, '') || '|' || v_ip, 'UTF8')), 'hex');
end;
$$;

create or replace function public.increment_plays(tid uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_key text := public.request_viewer_key();
  v_window timestamptz := date_trunc('hour', now());
  v_new integer;
begin
  if v_key is null then
    return;  -- 利用者を判定できない接続は数えない
  end if;
  if not exists (select 1 from public.tracks t where t.id = tid and t.status = 'public') then
    return;
  end if;
  if (select count(*) from public.play_events e
      where e.viewer_key = v_key and e.window_start = v_window) >= 60 then
    return;
  end if;

  insert into public.play_events (track_id, viewer_key, window_start)
  values (tid, v_key, v_window)
  on conflict do nothing;
  get diagnostics v_new = row_count;

  if v_new = 1 then
    update public.tracks set plays = plays + 1 where id = tid and status = 'public';
  end if;

  -- 古い再生記録の掃除（呼び出しのおよそ100回に1回）
  if random() < 0.01 then
    delete from public.play_events where created_at < now() - interval '2 days';
  end if;
end;
$$;

-- 再生時間（duration）
--   ・通常は投稿時に投稿者本人が登録します（アプリが音源から自動で読み取り）
--   ・登録できなかった場合（0秒）だけ、この関数で後から1回設定できます
--   ・設定できるのは「その曲の投稿者本人」と「管理者」だけ。未ログイン・他の会員は不可
--   ・すでに設定済みの値は、この関数では変更できません（訂正は管理者が管理画面から）
create or replace function public.set_duration_if_missing(tid uuid, d integer)
returns void
language sql security definer set search_path = ''
as $$
  update public.tracks t set duration = d
  where t.id = tid
    and t.duration = 0
    and d between 1 and 3600
    and auth.uid() is not null
    and ((t.user_id = auth.uid() and public.is_active_member()) or public.is_admin());
$$;


-- =====================================================================
-- 9. 管理者専用の関数（管理者以外が呼ぶとエラー）
-- =====================================================================

-- 集計（実データのみ）
create or replace function public.admin_stats()
returns json
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  return json_build_object(
    'members',          (select count(*) from public.profiles),
    'members_banned',   (select count(*) from public.profiles where is_banned),
    'artists',          (select count(*) from public.artists),
    'tracks_pending',   (select count(*) from public.tracks where status = 'pending'),
    'tracks_public',    (select count(*) from public.tracks where status = 'public'),
    'tracks_hidden',    (select count(*) from public.tracks where status = 'hidden'),
    'tracks_rejected',  (select count(*) from public.tracks where status = 'rejected'),
    'plays_total',      (select coalesce(sum(plays), 0) from public.tracks),
    'reviews',          (select count(*) from public.reviews),
    'favorites',        (select count(*) from public.favorites),
    'follows',          (select count(*) from public.follows),
    'reports_open',     (select count(*) from public.reports where status = 'open')
  );
end;
$$;

-- 会員一覧
create or replace function public.admin_list_members(p_limit integer default 50, p_offset integer default 0)
returns table (id uuid, email text, display_name text, is_admin boolean, is_banned boolean,
               email_confirmed boolean, created_at timestamptz, track_count bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  return query
    select p.id, u.email::text, p.display_name, p.is_admin, p.is_banned,
           (u.email_confirmed_at is not null), p.created_at,
           (select count(*) from public.tracks t where t.user_id = p.id)
    from public.profiles p
    join auth.users u on u.id = p.id
    order by p.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
    offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- 会員の利用停止・解除（管理者は対象外。自分自身も不可）
create or replace function public.admin_set_member_ban(p_user uuid, p_banned boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  if p_user is null or p_banned is null then
    raise exception '会員と設定（停止・解除）を指定してください';
  end if;
  if p_user = auth.uid() then
    raise exception '自分自身は利用停止できません';
  end if;
  if exists (select 1 from public.profiles p where p.id = p_user and p.is_admin) then
    raise exception '管理者は利用停止できません';
  end if;
  update public.profiles set is_banned = p_banned where id = p_user;
  if not found then
    raise exception '会員が見つかりません';
  end if;
end;
$$;

-- 孤立ファイルの一覧（どの楽曲にも使われていない、指定時間より古いファイル。削除後30日以内の曲のファイルは除く）
-- ※ 実際の削除はアプリの管理画面から Storage の削除機能で行います
create or replace function public.admin_orphan_files(p_min_age_hours integer default 24)
returns table (bucket_id text, name text, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  return query
    select o.bucket_id::text, o.name::text, o.created_at
    from storage.objects o
    where o.bucket_id in ('audio', 'covers')
      and o.created_at < now() - make_interval(hours => greatest(coalesce(p_min_age_hours, 24), 1))
      and not exists (
        select 1 from public.tracks t
        where (o.bucket_id = 'audio' and t.audio_path = o.name)
           or (o.bucket_id = 'covers' and t.image_path = o.name)
      )
      -- 削除から30日以内の曲のファイルは、復元できるよう対象外
      and not exists (
        select 1 from aimuse_private.track_deletions d
        where d.restored_at is null
          and d.deleted_at > now() - interval '30 days'
          and ((o.bucket_id = 'audio' and d.track->>'audio_path' = o.name)
            or (o.bucket_id = 'covers' and d.track->>'image_path' = o.name))
      )
    order by o.created_at
    limit 500;
end;
$$;

-- 削除した楽曲の一覧（30日以内）
create or replace function public.admin_list_deleted_tracks()
returns table (deletion_id uuid, track_id uuid, title text, artist text, status_before text,
               review_count integer, report_count integer, deleted_at timestamptz,
               audio_file_exists boolean, restored_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if coalesce(auth.jwt()->>'role', '') in ('anon', 'authenticated') and not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  return query
    select d.id, d.track_id, d.track->>'title', d.track->>'artist', d.track->>'status',
           jsonb_array_length(d.reviews), d.report_count, d.deleted_at,
           exists (select 1 from storage.objects o where o.bucket_id = 'audio' and o.name = d.track->>'audio_path'),
           d.restored_at
    from aimuse_private.track_deletions d
    where d.deleted_at > now() - interval '30 days'
    order by d.deleted_at desc;
end;
$$;

-- 削除した楽曲の復元（30日以内・音源ファイルが残っている場合のみ）
--   復元後は安全のため「非公開」の状態になります。内容を確認してから公開してください
--   レビューも復元します（レビューした会員が退会済みの場合、その分は復元されません）
create or replace function public.admin_restore_track(p_deletion_id uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_del aimuse_private.track_deletions%rowtype;
  v_track jsonb;
begin
  if coalesce(auth.jwt()->>'role', '') in ('anon', 'authenticated') and not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  select * into v_del from aimuse_private.track_deletions
  where id = p_deletion_id and restored_at is null and deleted_at > now() - interval '30 days';
  if not found then
    raise exception '復元できる削除記録が見つかりません（30日を過ぎたか、復元済みです）';
  end if;
  if exists (select 1 from public.tracks t where t.id = v_del.track_id) then
    raise exception 'この楽曲はすでに存在します';
  end if;
  if not exists (select 1 from auth.users u where u.id = (v_del.track->>'user_id')::uuid) then
    raise exception '投稿者の会員が存在しないため復元できません';
  end if;
  if not exists (select 1 from storage.objects o
                 where o.bucket_id = 'audio' and o.name = v_del.track->>'audio_path') then
    raise exception '音源ファイルがすでに削除されているため復元できません';
  end if;

  v_track := jsonb_set(v_del.track, '{status}', '"hidden"');
  if v_track->>'image_path' is not null and not exists (
       select 1 from storage.objects o where o.bucket_id = 'covers' and o.name = v_track->>'image_path') then
    v_track := jsonb_set(v_track, '{image_path}', 'null');
  end if;
  insert into public.tracks
  select * from jsonb_populate_record(null::public.tracks, v_track);

  insert into public.reviews
  select r.* from jsonb_populate_recordset(null::public.reviews, v_del.reviews) r
  where exists (select 1 from auth.users u where u.id = r.user_id)
  on conflict do nothing;

  update aimuse_private.track_deletions set restored_at = now() where id = v_del.id;
  return v_del.track_id;
end;
$$;

-- 本番確認用：利用者判定に使えるヘッダーが届いているか（値はハッシュ化して返す）
create or replace function public.admin_check_request_headers()
returns json
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_headers json;
begin
  if not public.is_admin() then
    raise exception '管理者のみ利用できます';
  end if;
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  return json_build_object(
    'cf-connecting-ip', (v_headers->>'cf-connecting-ip') is not null,
    'x-real-ip',        (v_headers->>'x-real-ip') is not null,
    'x-forwarded-for',  (v_headers->>'x-forwarded-for') is not null,
    'configured',       (select s.value from aimuse_private.settings s where s.key = 'client_ip_headers'),
    'viewer_key_found', public.request_viewer_key() is not null
  );
end;
$$;


-- =====================================================================
-- 10. 権限（どの操作を許可するか。細かい条件は「11. RLS」で制御）
-- =====================================================================
revoke all on public.profiles    from anon, authenticated;
revoke all on public.artists     from anon, authenticated;
revoke all on public.tracks      from anon, authenticated;
revoke all on public.favorites   from anon, authenticated;
revoke all on public.follows     from anon, authenticated;
revoke all on public.reviews     from anon, authenticated;
revoke all on public.reports     from anon, authenticated;
revoke all on public.play_events from anon, authenticated;

-- profiles：自分の表示名だけ変更可（is_admin・is_banned 列は更新権限なし）
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;

-- artists：閲覧は誰でも。紹介文の変更は本人または管理者。削除は管理者
grant select on public.artists to anon, authenticated;
grant update (bio) on public.artists to authenticated;
grant delete on public.artists to authenticated;

-- tracks：閲覧は誰でも。投稿・削除は会員。更新は管理者のみ（RLSで制限）
grant select on public.tracks to anon, authenticated;
grant insert, update, delete on public.tracks to authenticated;

-- favorites / follows：会員本人のみ
grant select, insert, delete on public.favorites to authenticated;
grant select, insert, delete on public.follows to authenticated;

-- reviews：閲覧は誰でも。投稿・削除は会員。変更は評価とコメントのみ
grant select on public.reviews to anon, authenticated;
grant insert, delete on public.reviews to authenticated;
grant update (rating, comment) on public.reviews to authenticated;

-- reports：通報は会員。閲覧・対応は管理者（RLSで制限）
grant select, insert, update, delete on public.reports to authenticated;

-- 関数：まず全員から実行権限を外し、必要なものだけ許可
revoke all on function public.is_reserved_name(text) from public, anon, authenticated;
revoke all on function public.is_admin() from public, anon, authenticated;
revoke all on function public.is_active_member() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.protect_profile_flags() from public, anon, authenticated;
revoke all on function public.tracks_before_insert() from public, anon, authenticated;
revoke all on function public.tracks_before_update() from public, anon, authenticated;
revoke all on function public.tracks_before_delete() from public, anon, authenticated;
revoke all on function public.admin_list_deleted_tracks() from public, anon, authenticated;
revoke all on function public.admin_restore_track(uuid) from public, anon, authenticated;
revoke all on function public.reviews_touch() from public, anon, authenticated;
revoke all on function public.reports_before_insert() from public, anon, authenticated;
revoke all on function public.request_viewer_key() from public, anon, authenticated;
revoke all on function public.increment_plays(uuid) from public, anon, authenticated;
revoke all on function public.set_duration_if_missing(uuid, integer) from public, anon, authenticated;
revoke all on function public.artist_follower_count(uuid) from public, anon, authenticated;
revoke all on function public.track_reviews(uuid) from public, anon, authenticated;
revoke all on function public.track_rating_summary(uuid) from public, anon, authenticated;
revoke all on function public.admin_stats() from public, anon, authenticated;
revoke all on function public.admin_list_members(integer, integer) from public, anon, authenticated;
revoke all on function public.admin_set_member_ban(uuid, boolean) from public, anon, authenticated;
revoke all on function public.admin_orphan_files(integer) from public, anon, authenticated;
revoke all on function public.admin_check_request_headers() from public, anon, authenticated;

-- RLS・トリガーの判定で使う関数（中身は「自分が管理者か／書き込みできる会員か／予約語か」を返すだけ）
grant execute on function public.is_reserved_name(text) to authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.is_active_member() to anon, authenticated;
-- 誰でも使える関数
grant execute on function public.increment_plays(uuid) to anon, authenticated;
grant execute on function public.set_duration_if_missing(uuid, integer) to authenticated;
grant execute on function public.artist_follower_count(uuid) to anon, authenticated;
grant execute on function public.track_reviews(uuid) to anon, authenticated;
grant execute on function public.track_rating_summary(uuid) to anon, authenticated;
-- 管理者用（関数の中で管理者か確認し、違えばエラー）
grant execute on function public.admin_stats() to authenticated;
grant execute on function public.admin_list_members(integer, integer) to authenticated;
grant execute on function public.admin_set_member_ban(uuid, boolean) to authenticated;
grant execute on function public.admin_orphan_files(integer) to authenticated;
grant execute on function public.admin_check_request_headers() to authenticated;
grant execute on function public.admin_list_deleted_tracks() to authenticated;
grant execute on function public.admin_restore_track(uuid) to authenticated;


-- =====================================================================
-- 11. 行レベルセキュリティ（RLS）
-- =====================================================================
alter table public.profiles    enable row level security;
alter table public.artists     enable row level security;
alter table public.tracks      enable row level security;
alter table public.favorites   enable row level security;
alter table public.follows     enable row level security;
alter table public.reviews     enable row level security;
alter table public.reports     enable row level security;
alter table public.play_events enable row level security;  -- ポリシーなし＝直接アクセス不可
alter table aimuse_private.settings enable row level security;
alter table aimuse_private.track_deletions enable row level security;

-- ---------- profiles ----------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------- artists ----------
drop policy if exists artists_select on public.artists;
create policy artists_select on public.artists
  for select to anon, authenticated
  using (
    user_id = auth.uid()
    or public.is_admin()
    or exists (select 1 from public.tracks t where t.artist_id = artists.id and t.status = 'public')
  );

drop policy if exists artists_update_own on public.artists;
create policy artists_update_own on public.artists
  for update to authenticated
  using ((user_id = auth.uid() and public.is_active_member()) or public.is_admin())
  with check ((user_id = auth.uid() and public.is_active_member()) or public.is_admin());

drop policy if exists artists_delete_admin on public.artists;
create policy artists_delete_admin on public.artists
  for delete to authenticated
  using (public.is_admin());

-- ---------- tracks ----------
-- 公開中の曲は誰でも閲覧。審査待ち・非公開・却下は投稿者本人と管理者のみ
drop policy if exists tracks_select on public.tracks;
create policy tracks_select on public.tracks
  for select to anon, authenticated
  using (status = 'public' or user_id = auth.uid() or public.is_admin());

-- 投稿：メール認証済みの会員が本人として、自分の「会員ID/楽曲ID.拡張子」のファイルでのみ
drop policy if exists tracks_insert on public.tracks;
create policy tracks_insert on public.tracks
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.is_active_member()
    and status = 'pending'
    and plays = 0
    and audio_path ~ ('^' || auth.uid()::text || '/' || id::text || '\.(mp3|wav|m4a)$')
    and (image_path is null or image_path ~ ('^' || auth.uid()::text || '/' || id::text || '\.(jpg|jpeg|png|heic|heif)$'))
  );

-- 審査・公開切替などの変更は管理者のみ（投稿者本人も変更不可）
drop policy if exists tracks_update_admin on public.tracks;
create policy tracks_update_admin on public.tracks
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- 削除：管理者、または投稿者本人（他人の曲は削除不可。公開中の曲は先に非公開にする必要あり）
drop policy if exists tracks_delete on public.tracks;
create policy tracks_delete on public.tracks
  for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ---------- favorites ----------
drop policy if exists favorites_select_own on public.favorites;
create policy favorites_select_own on public.favorites
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists favorites_insert_own on public.favorites;
create policy favorites_insert_own on public.favorites
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.is_active_member()
    and exists (select 1 from public.tracks t where t.id = track_id and t.status = 'public')
  );

drop policy if exists favorites_delete_own on public.favorites;
create policy favorites_delete_own on public.favorites
  for delete to authenticated
  using (user_id = auth.uid());

-- ---------- follows ----------
drop policy if exists follows_select_own on public.follows;
create policy follows_select_own on public.follows
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists follows_insert_own on public.follows;
create policy follows_insert_own on public.follows
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.is_active_member()
    and exists (select 1 from public.artists a where a.id = artist_id)
  );

drop policy if exists follows_delete_own on public.follows;
create policy follows_delete_own on public.follows
  for delete to authenticated
  using (user_id = auth.uid());

-- ---------- reviews ----------
drop policy if exists reviews_select on public.reviews;
create policy reviews_select on public.reviews
  for select to anon, authenticated
  using (
    user_id = auth.uid()
    or public.is_admin()
    or exists (select 1 from public.tracks t where t.id = track_id and t.status = 'public')
  );

drop policy if exists reviews_insert_own on public.reviews;
create policy reviews_insert_own on public.reviews
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.is_active_member()
    and exists (select 1 from public.tracks t where t.id = track_id and t.status = 'public')
  );

drop policy if exists reviews_update_own on public.reviews;
create policy reviews_update_own on public.reviews
  for update to authenticated
  using (user_id = auth.uid() and public.is_active_member())
  with check (user_id = auth.uid());

drop policy if exists reviews_delete on public.reviews;
create policy reviews_delete on public.reviews
  for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- ---------- reports ----------
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports
  for insert to authenticated
  with check (
    reporter_id = auth.uid()
    and public.is_active_member()
    and status = 'open'
    and exists (select 1 from public.tracks t where t.id = song_id)
  );

drop policy if exists reports_admin_select on public.reports;
create policy reports_admin_select on public.reports
  for select to authenticated
  using (public.is_admin());

drop policy if exists reports_admin_update on public.reports;
create policy reports_admin_update on public.reports
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists reports_admin_delete on public.reports;
create policy reports_admin_delete on public.reports
  for delete to authenticated
  using (public.is_admin());


-- =====================================================================
-- 12. Storage（音源・ジャケット画像の保存場所）
--     audio  ：音源（MP3・WAV・M4A、1ファイル50MBまで）
--     covers ：ジャケット画像（JPG・PNG・HEIC、1ファイル15MBまで）
--     どちらも非公開バケット。アプリは有効期限1時間の署名付きURLで再生・表示します。
--     署名付きURLを発行できるのは：
--       ・公開中（public）の曲の音源・画像 … 誰でも
--       ・自分が投稿した曲の音源・画像 … 本人
--       ・すべて … 管理者
--     保存場所は「会員ID/楽曲ID.拡張子」の形式に限定します。
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('audio', 'audio', false, 52428800,
    array['audio/mpeg', 'audio/mp3', 'audio/wav', 'audio/x-wav', 'audio/wave', 'audio/vnd.wave',
          'audio/mp4', 'audio/x-m4a', 'audio/m4a', 'audio/aac']),
  ('covers', 'covers', false, 15728640,
    array['image/jpeg', 'image/jpg', 'image/png', 'image/heic', 'image/heif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 音源・画像を読めるか（署名付きURLの発行可否）
create or replace function public.can_read_media(bucket text, object_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select
    (auth.uid() is not null and split_part(object_name, '/', 1) = auth.uid()::text)
    or public.is_admin()
    or exists (
      select 1 from public.tracks t
      where t.status = 'public'
        and ((bucket = 'audio' and t.audio_path = object_name)
          or (bucket = 'covers' and t.image_path = object_name))
    );
$$;

-- そのファイルが「使用中」か
--   ・楽曲で使われているファイル
--   ・削除から30日以内（復元できる期間）の楽曲のファイル
-- 使用中のファイルは、投稿者本人でも削除・置き換えできません（審査後の差し替え防止・復元の保護）
create or replace function public.media_path_in_use(bucket text, object_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tracks t
    where (bucket = 'audio' and t.audio_path = object_name)
       or (bucket = 'covers' and t.image_path = object_name)
  )
  or exists (
    select 1 from aimuse_private.track_deletions d
    where d.restored_at is null
      and d.deleted_at > now() - interval '30 days'
      and ((bucket = 'audio' and d.track->>'audio_path' = object_name)
        or (bucket = 'covers' and d.track->>'image_path' = object_name))
  );
$$;

-- その楽曲IDがすでに使われているか（存在する曲、または削除から30日以内の曲）
-- ファイル名「会員ID/楽曲ID.拡張子」の楽曲ID部分で判定し、既存の曲の場所への新規保存を防ぎます
create or replace function public.media_track_id_taken(object_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tracks t
    where t.id::text = split_part(split_part(object_name, '/', 2), '.', 1)
  )
  or exists (
    select 1 from aimuse_private.track_deletions d
    where d.restored_at is null
      and d.deleted_at > now() - interval '30 days'
      and d.track_id::text = split_part(split_part(object_name, '/', 2), '.', 1)
  );
$$;

-- アップロードできるか
--   書き込みできる会員・保存ファイルが1人200個未満・使用中の場所や楽曲IDではない
create or replace function public.storage_can_upload(bucket text, object_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_active_member()
     and not public.media_path_in_use(bucket, object_name)
     and not public.media_track_id_taken(object_name)
     and (select count(*) from storage.objects o
          where o.bucket_id in ('audio', 'covers')
            and split_part(o.name, '/', 1) = auth.uid()::text) < 200;
$$;

-- 削除できるか
--   管理者：すべて
--   投稿者本人：自分のフォルダのうち、使用中でないファイルだけ（アップロード失敗時の後片付け用）
create or replace function public.storage_can_delete(bucket text, object_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_admin()
     or (auth.uid() is not null
         and split_part(object_name, '/', 1) = auth.uid()::text
         and not public.media_path_in_use(bucket, object_name));
$$;

revoke all on function public.can_read_media(text, text) from public, anon, authenticated;
revoke all on function public.media_path_in_use(text, text) from public, anon, authenticated;
revoke all on function public.media_track_id_taken(text) from public, anon, authenticated;
revoke all on function public.storage_can_upload(text, text) from public, anon, authenticated;
revoke all on function public.storage_can_delete(text, text) from public, anon, authenticated;
grant execute on function public.can_read_media(text, text) to anon, authenticated;
grant execute on function public.storage_can_upload(text, text) to authenticated;
grant execute on function public.storage_can_delete(text, text) to authenticated;

-- 旧バージョンのポリシー名を削除（あれば）
drop policy if exists "aimuse select own or admin" on storage.objects;
drop policy if exists "aimuse update own" on storage.objects;

-- アップロード：会員が「自分の会員ID/楽曲ID.拡張子」にだけ、新規保存のみ可（使用中の場所への再保存は不可）
drop policy if exists "aimuse upload own folder" on storage.objects;
create policy "aimuse upload own folder" on storage.objects
  for insert to authenticated
  with check (
    (
      (bucket_id = 'audio'
        and name ~ ('^' || auth.uid()::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(mp3|wav|m4a)$'))
      or
      (bucket_id = 'covers'
        and name ~ ('^' || auth.uid()::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|heic|heif)$'))
    )
    and public.storage_can_upload(bucket_id, name)
  );

-- 参照（署名付きURLの発行）：公開中の曲は誰でも。それ以外は本人と管理者のみ
drop policy if exists "aimuse read media" on storage.objects;
create policy "aimuse read media" on storage.objects
  for select to anon, authenticated
  using (
    bucket_id in ('audio', 'covers')
    and public.can_read_media(bucket_id, name)
  );

-- 削除：管理者、または本人の「楽曲で使われていない」ファイルのみ（他人のファイルは削除不可）
drop policy if exists "aimuse delete own or admin" on storage.objects;
create policy "aimuse delete own or admin" on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('audio', 'covers')
    and public.storage_can_delete(bucket_id, name)
  );

-- 旧バージョンの関数を削除（あれば。ポリシーを作り直した後なので安全）
drop function if exists public.storage_upload_allowed();

-- データベース内部の関数（アップロード上限・孤立ファイル検出）がファイル数を正しく数えるための参照許可
-- 対象は SQL Editor の管理用ロール postgres のみ。アプリの利用者（anon・authenticated）には影響しません
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'postgres') then
    execute 'drop policy if exists "aimuse internal read" on storage.objects';
    execute 'create policy "aimuse internal read" on storage.objects for select to postgres using (bucket_id in (''audio'', ''covers''))';
  end if;
end $$;

-- 上書き更新は誰にも許可しません（更新用のポリシーは作りません）

-- APIに変更を即時反映
notify pgrst, 'reload schema';

-- =====================================================================
-- 完了
-- =====================================================================
