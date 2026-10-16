-- =====================================================================
-- AIMUSE BOOST 追加SQL（Ver.0.1 r1）
-- AIMUSE と同じ Supabase プロジェクトの SQL Editor に全文を貼り付けて、1回実行してください。
--
-- ・AIMUSE の既存テーブル（profiles / tracks など）は一切変更・削除しません
-- ・新しく「boost_」で始まるテーブルと関数だけを追加します
-- ・何度実行しても壊れません（既存のBOOSTデータも消えません）
-- ・架空のデータは一切追加しません
-- ・管理者の判定は AIMUSE と同じ public.is_admin()（profiles.is_admin = true）を使います
-- =====================================================================


-- =====================================================================
-- 0. 前提チェック（AIMUSE の構築SQLが実行済みか）
-- =====================================================================
do $$ begin
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'AIMUSE の構築SQL（aimuse_schema.sql）が未実行です。先に実行してください。';
  end if;
  if to_regclass('public.tracks') is null then
    raise exception 'public.tracks がありません。AIMUSE の構築SQLを先に実行してください。';
  end if;
end $$;


-- =====================================================================
-- 1. 宣伝リンク（boost_links）
--    SNSに載せる短縮リンク。/go/<code> を開くとクリックを記録してAIMUSEへ移動します。
--    track_id は AIMUSE の楽曲ID（外部キーは付けず、AIMUSE側の削除処理に影響させない）
-- =====================================================================
create table if not exists public.boost_links (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Za-z0-9]{6,12}$'),
  track_id uuid,
  track_title text,
  artist text,
  platform text not null check (platform in ('x', 'instagram', 'tiktok', 'youtube', 'other')),
  destination text not null check (destination ~ '^https://' and char_length(destination) <= 1000),
  utm_campaign text check (utm_campaign is null or char_length(utm_campaign) <= 80),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists boost_links_track_idx on public.boost_links(track_id);


-- =====================================================================
-- 2. クリック記録（boost_clicks）
--    個人情報は保存しません（IPアドレス・端末情報・Cookieなし）。
--    記録するのは「どのリンクが・いつ」クリックされたかだけです。
-- =====================================================================
create table if not exists public.boost_clicks (
  id bigint generated always as identity primary key,
  link_id uuid not null references public.boost_links(id) on delete cascade,
  track_id uuid,
  platform text not null,
  clicked_at timestamptz not null default now()
);
create index if not exists boost_clicks_clicked_idx on public.boost_clicks(clicked_at);
create index if not exists boost_clicks_link_idx on public.boost_clicks(link_id, clicked_at);


-- =====================================================================
-- 3. 投稿（boost_posts）
--    status：draft=下書き / scheduled=予定 / posted=投稿済み / skipped=見送り
--    post_mode：manual=手動投稿（Ver.0.1 はすべて手動）/ auto=公式API自動投稿（将来）
-- =====================================================================
create table if not exists public.boost_posts (
  id uuid primary key default gen_random_uuid(),
  track_id uuid,
  track_title text,
  artist text,
  platform text not null check (platform in ('x', 'instagram', 'tiktok', 'youtube')),
  tone text check (tone is null or tone in ('emotional', 'cool', 'love', 'friendly', 'simple')),
  source text not null default 'template' check (source in ('template', 'ai', 'manual')),
  title text check (title is null or char_length(title) <= 200),
  body text not null default '' check (char_length(body) <= 5000),
  hashtags text not null default '' check (char_length(hashtags) <= 1000),
  link_id uuid references public.boost_links(id) on delete set null,
  status text not null default 'draft' check (status in ('draft', 'scheduled', 'posted', 'skipped')),
  scheduled_at timestamptz,
  posted_at timestamptz,
  post_mode text not null default 'manual' check (post_mode in ('manual', 'auto')),
  external_post_id text,                       -- 自動投稿時にSNSが返す投稿ID（重複防止）
  idempotency_key uuid not null default gen_random_uuid() unique,  -- 自動投稿の二重送信防止
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists boost_posts_scheduled_idx on public.boost_posts(scheduled_at);
create index if not exists boost_posts_status_idx on public.boost_posts(status);
create unique index if not exists boost_posts_external_key
  on public.boost_posts(platform, external_post_id) where external_post_id is not null;

create or replace function public.boost_posts_touch()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if new.status = 'posted' and new.posted_at is null then new.posted_at := now(); end if;
  if new.status <> 'posted' then new.posted_at := null; end if;
  -- Ver.0.1：自動投稿は未接続のため、auto には設定できない
  if new.post_mode = 'auto' and not exists (
       select 1 from public.boost_sns_accounts a
       where a.platform = new.platform and a.auto_post_enabled) then
    raise exception 'このSNSは自動投稿に接続されていません';
  end if;
  return new;
end $$;


-- =====================================================================
-- 4. 自動投稿の試行記録（boost_post_attempts）※将来の公式API連携用
--    失敗時の記録・再試行回数の管理に使います。Ver.0.1 では使用しません。
-- =====================================================================
create table if not exists public.boost_post_attempts (
  id bigint generated always as identity primary key,
  post_id uuid not null references public.boost_posts(id) on delete cascade,
  attempt integer not null check (attempt between 1 and 10),
  result text not null check (result in ('success', 'failed', 'skipped_duplicate')),
  error_message text check (error_message is null or char_length(error_message) <= 2000),
  attempted_at timestamptz not null default now(),
  unique (post_id, attempt)
);


-- =====================================================================
-- 5. SNS接続状況（boost_sns_accounts）
--    認証情報（トークン等）はここに保存しません。将来は Cloudflare の秘密変数に保存します。
--    初期状態はすべて「未接続」。
-- =====================================================================
create table if not exists public.boost_sns_accounts (
  platform text primary key check (platform in ('x', 'instagram', 'tiktok', 'youtube')),
  connected boolean not null default false,
  auto_post_enabled boolean not null default false check (not auto_post_enabled or connected),
  account_label text check (account_label is null or char_length(account_label) <= 80),
  note text check (note is null or char_length(note) <= 500),
  updated_at timestamptz not null default now()
);
insert into public.boost_sns_accounts (platform) values ('x'), ('instagram'), ('tiktok'), ('youtube')
on conflict (platform) do nothing;

drop trigger if exists boost_posts_touch on public.boost_posts;
create trigger boost_posts_touch before insert or update on public.boost_posts
  for each row execute function public.boost_posts_touch();


-- =====================================================================
-- 6. 操作履歴・エラーログ（boost_logs）
-- =====================================================================
create table if not exists public.boost_logs (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('action', 'error')),
  action text not null check (char_length(action) <= 80),
  detail jsonb not null default '{}'::jsonb,
  actor uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists boost_logs_created_idx on public.boost_logs(created_at);


-- =====================================================================
-- 7. 設定・AI利用回数（料金の上限管理）
-- =====================================================================
create table if not exists public.boost_settings (
  key text primary key check (key in ('ai_daily_limit')),
  value integer not null check (value between 0 and 500),
  updated_at timestamptz not null default now()
);
insert into public.boost_settings (key, value) values ('ai_daily_limit', 30)
on conflict (key) do nothing;

create table if not exists public.boost_ai_usage (
  day date primary key,
  count integer not null default 0 check (count >= 0)
);


-- =====================================================================
-- 8. アクセス権（すべて管理者のみ。未ログイン・一般会員は読み書き不可）
-- =====================================================================
revoke all on public.boost_links, public.boost_clicks, public.boost_posts, public.boost_post_attempts,
              public.boost_sns_accounts, public.boost_logs, public.boost_settings, public.boost_ai_usage
  from public, anon, authenticated;

grant select, insert, delete on public.boost_links to authenticated;
grant select on public.boost_clicks to authenticated;
grant select, insert, update, delete on public.boost_posts to authenticated;
grant select on public.boost_post_attempts to authenticated;
grant select, update (account_label, note) on public.boost_sns_accounts to authenticated;  -- 接続フラグはアプリから変更不可
grant select, insert on public.boost_logs to authenticated;
grant select, update (value) on public.boost_settings to authenticated;
grant select on public.boost_ai_usage to authenticated;

alter table public.boost_links         enable row level security;
alter table public.boost_clicks        enable row level security;
alter table public.boost_posts         enable row level security;
alter table public.boost_post_attempts enable row level security;
alter table public.boost_sns_accounts  enable row level security;
alter table public.boost_logs          enable row level security;
alter table public.boost_settings      enable row level security;
alter table public.boost_ai_usage      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['boost_links','boost_clicks','boost_posts','boost_post_attempts',
                           'boost_sns_accounts','boost_logs','boost_settings','boost_ai_usage'] loop
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())',
                   t || '_admin', t);
  end loop;
end $$;

-- 操作ログは本人名義でのみ追加可（なりすまし防止）
drop policy if exists boost_logs_admin on public.boost_logs;
create policy boost_logs_admin on public.boost_logs for all to authenticated
  using (public.is_admin()) with check (public.is_admin() and actor = auth.uid());


-- =====================================================================
-- 9. 短縮リンクのクリック記録（/go/<code> から呼ばれる。ログイン不要）
--    ・存在するリンクのクリックだけ記録し、移動先URLを返す
--    ・いたずら対策：1リンクあたり1分間に60回を超えた分は記録しない
-- =====================================================================
create or replace function public.boost_resolve_link(p_code text, p_record boolean default true)
returns text
language plpgsql security definer set search_path = ''
as $$
declare l public.boost_links;
begin
  if p_code is null or p_code !~ '^[A-Za-z0-9]{6,12}$' then return null; end if;
  select * into l from public.boost_links where code = p_code;
  if not found then return null; end if;
  if p_record and (select count(*) from public.boost_clicks c
                   where c.link_id = l.id and c.clicked_at > now() - interval '1 minute') < 60 then
    insert into public.boost_clicks (link_id, track_id, platform) values (l.id, l.track_id, l.platform);
  end if;
  return l.destination;
end $$;


-- =====================================================================
-- 10. AI生成の利用回数チェック（サーバー処理から管理者のログイン情報で呼ばれる）
--     1日の上限（初期30回）を超えると false。管理者以外はエラー。
-- =====================================================================
create or replace function public.boost_ai_take_quota()
returns json
language plpgsql security definer set search_path = ''
as $$
declare lim integer; used integer; today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if not public.is_admin() then raise exception '管理者のみ利用できます'; end if;
  select value into lim from public.boost_settings where key = 'ai_daily_limit';
  lim := coalesce(lim, 30);
  insert into public.boost_ai_usage (day, count) values (today, 0) on conflict (day) do nothing;
  select count into used from public.boost_ai_usage where day = today for update;
  if used >= lim then
    return json_build_object('allowed', false, 'used', used, 'limit', lim);
  end if;
  update public.boost_ai_usage set count = count + 1 where day = today;
  return json_build_object('allowed', true, 'used', used + 1, 'limit', lim);
end $$;

revoke all on function public.boost_posts_touch() from public, anon, authenticated;
revoke all on function public.boost_resolve_link(text, boolean) from public, anon, authenticated;
revoke all on function public.boost_ai_take_quota() from public, anon, authenticated;
grant execute on function public.boost_resolve_link(text, boolean) to anon, authenticated;
grant execute on function public.boost_ai_take_quota() to authenticated;


-- =====================================================================
-- 11. 確認（結果に8行表示されればOK）
-- =====================================================================
select c.relname as "BOOSTテーブル", c.relrowsecurity as "RLS有効"
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname like 'boost\_%' and c.relkind = 'r'
order by 1;
