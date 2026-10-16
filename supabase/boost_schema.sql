-- =====================================================================
-- AIMUSE BOOST 追加SQL（Ver.0.2 r4）
-- AIMUSE と同じ Supabase プロジェクトの SQL Editor に全文を貼り付けて、1回実行してください。
--
-- ・AIMUSE の既存テーブル・データ・認証設定・関数は一切変更しません（読むだけ）
-- ・新しく「boost_」で始まるテーブルと関数だけを追加・更新します
-- ・何度実行しても壊れません（既存のBOOSTデータも消えません）
-- ・最初に構造チェックを行い、想定外の状態なら何も変更せずに中止します
-- ・架空のデータは一切追加しません
-- ・管理者の判定は AIMUSE と同じ public.is_admin()（profiles.is_admin = true）を使います
-- =====================================================================


-- =====================================================================
-- 0. 事前チェック（ここで中止された場合、データベースは何も変更されていません）
-- =====================================================================
do $$
declare
  def text;
  r record;
  -- BOOSTテーブルの想定構造（列名 → 型）。既存テーブルがあれば、これと照合する
  expected jsonb := '{
    "boost_links": {"id":"uuid","code":"text","track_id":"uuid","track_title":"text","artist":"text","platform":"text","utm_campaign":"text","created_by":"uuid","created_at":"timestamp with time zone"},
    "boost_clicks": {"id":"bigint","link_id":"uuid","track_id":"uuid","platform":"text","kind":"text","clicked_at":"timestamp with time zone"},
    "boost_posts": {"id":"uuid","track_id":"uuid","track_title":"text","artist":"text","platform":"text","tone":"text","source":"text","title":"text","body":"text","hashtags":"text","link_id":"uuid","status":"text","scheduled_at":"timestamp with time zone","posted_at":"timestamp with time zone","post_mode":"text","external_post_id":"text","idempotency_key":"uuid","created_by":"uuid","created_at":"timestamp with time zone","updated_at":"timestamp with time zone"},
    "boost_post_attempts": {"id":"bigint","post_id":"uuid","attempt":"integer","result":"text","error_message":"text","attempted_at":"timestamp with time zone"},
    "boost_sns_accounts": {"platform":"text","connected":"boolean","auto_post_enabled":"boolean","account_label":"text","note":"text","updated_at":"timestamp with time zone"},
    "boost_logs": {"id":"bigint","kind":"text","action":"text","detail":"jsonb","actor":"uuid","created_at":"timestamp with time zone"},
    "boost_settings": {"key":"text","value":"integer","updated_at":"timestamp with time zone"},
    "boost_ai_usage": {"day":"date","count":"integer"},
    "boost_rate_counters": {"scope":"text","bucket":"timestamp with time zone","n":"integer"}
  }'::jsonb;
  -- 以前の版にあった列（あれば残すが、使わない。NULL可にする）
  legacy jsonb := '{"boost_links": {"destination":"text"}}'::jsonb;
  -- 以前の版で無かった列（このSQLで追加する）
  addable jsonb := '{"boost_clicks": ["kind"]}'::jsonb;
begin
  -- (1) AIMUSE本体が構築済みか
  if to_regclass('public.tracks') is null or to_regclass('public.profiles') is null then
    raise exception 'AIMUSE の構築SQLが未実行です（public.tracks / public.profiles がありません）。中止しました。';
  end if;

  -- (2) 管理者判定 public.is_admin() が想定どおりか（変更されていたら中止）
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'public.is_admin() がありません。中止しました。';
  end if;
  select pg_get_functiondef('public.is_admin()'::regprocedure) into def;
  if def !~* 'from public\.profiles' or def !~* '\.is_admin' or def !~* 'auth\.uid\(\)' or def !~* 'returns boolean' then
    raise exception 'public.is_admin() の内容が想定と異なります（profiles.is_admin と auth.uid() で判定していない）。安全のため中止しました。';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles' and column_name = 'is_admin' and data_type = 'boolean') then
    raise exception 'profiles.is_admin（boolean）がありません。中止しました。';
  end if;
  -- (3) 会員が自分を管理者にできないこと（AIMUSE側の保護）を確認
  if has_column_privilege('authenticated', 'public.profiles', 'is_admin', 'UPDATE')
     or has_column_privilege('anon', 'public.profiles', 'is_admin', 'UPDATE')
     or has_table_privilege('authenticated', 'public.profiles', 'INSERT')
     or has_table_privilege('anon', 'public.profiles', 'INSERT') then
    raise exception '会員が profiles.is_admin を変更できる状態です。AIMUSE側の権限を確認してください。中止しました。';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'tracks' and column_name = 'status') then
    raise exception 'tracks.status がありません。中止しました。';
  end if;

  -- (4) 既にBOOSTテーブルがある場合、構造を照合（想定外なら中止）
  for r in
    select c.table_name, c.column_name, c.data_type, c.is_nullable, c.column_default, c.is_identity
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name like 'boost\_%'
      and c.table_name not in (select jsonb_object_keys(expected))
  loop
    raise exception '想定外のBOOSTテーブル % があります。中止しました。', r.table_name;
  end loop;

  for r in
    select c.table_name, c.column_name, c.data_type, c.is_nullable, c.column_default, c.is_identity
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name in (select jsonb_object_keys(expected))
  loop
    if expected -> r.table_name ? r.column_name then
      if expected -> r.table_name ->> r.column_name <> r.data_type then
        raise exception '%.% の型が想定（%）と異なります（現在：%）。中止しました。',
          r.table_name, r.column_name, expected -> r.table_name ->> r.column_name, r.data_type;
      end if;
    elsif legacy -> r.table_name ? r.column_name then
      if legacy -> r.table_name ->> r.column_name <> r.data_type then
        raise exception '%.% の型が想定と異なります。中止しました。', r.table_name, r.column_name;
      end if;
    else
      raise exception '%.% は想定外の列です。中止しました。', r.table_name, r.column_name;
    end if;
  end loop;

  -- 既存テーブルに足りない列がないか（追加予定の列を除く）
  for r in
    select t.key as table_name, k.key as column_name
    from jsonb_each(expected) t, jsonb_each_text(t.value) k
    where to_regclass('public.' || t.key) is not null
      and not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public' and c.table_name = t.key and c.column_name = k.key)
  loop
    if not coalesce((addable -> r.table_name) ? r.column_name, false) then
      raise exception '%.% がありません（想定外の構造）。中止しました。', r.table_name, r.column_name;
    end if;
  end loop;

  -- BOOSTテーブルがビューなど、テーブル以外になっていないか
  for r in
    select c.relname, c.relkind from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in (select jsonb_object_keys(expected)) and c.relkind <> 'r'
  loop
    raise exception '% がテーブルではありません。中止しました。', r.relname;
  end loop;
end $$;


-- =====================================================================
-- 1. 宣伝リンク（boost_links）
--    SNSに載せる短縮リンク /go/<code>。移動先は「BOOSTの宣伝ページ /s/<楽曲ID>」に固定。
--    任意のURLは保存できない（外部サイトへの転送に悪用されないため）
--    track_id は AIMUSE の楽曲ID（外部キーは付けず、AIMUSE側の削除処理に影響させない）
-- =====================================================================
create table if not exists public.boost_links (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Za-z0-9]{6,12}$'),
  track_id uuid not null,
  track_title text check (track_title is null or char_length(track_title) <= 200),
  artist text check (artist is null or char_length(artist) <= 200),
  platform text not null check (platform in ('x', 'instagram', 'tiktok', 'youtube', 'other')),
  utm_campaign text check (utm_campaign is null or char_length(utm_campaign) <= 80),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
-- 以前の版（destination 列あり・track_id 空欄可）からの移行（データは消さない）
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public'
             and table_name = 'boost_links' and column_name = 'destination') then
    -- 新しいアプリは移動先を保存しない。以前の値は残すが、移動には使わない
    alter table public.boost_links alter column destination drop not null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'boost_links_track_required'
                 and conrelid = 'public.boost_links'::regclass)
     and exists (select 1 from information_schema.columns where table_schema = 'public'
                 and table_name = 'boost_links' and column_name = 'track_id' and is_nullable = 'YES') then
    -- 以前の行は検査せず、これから追加する行だけ楽曲IDを必須にする
    alter table public.boost_links add constraint boost_links_track_required check (track_id is not null) not valid;
  end if;
end $$;
create index if not exists boost_links_track_idx on public.boost_links(track_id);


-- =====================================================================
-- 2. クリック記録（boost_clicks）
--    個人情報は保存しません（IPアドレス・端末情報は保存しない）。
--    記録するのは「どのリンク/曲が・どのSNSで・いつ」だけです。
--    kind：link=SNSに載せた計測リンク（/go/…）が開かれた
--          listen=宣伝ページの「AIMUSEで聴く」が押された
-- =====================================================================
create table if not exists public.boost_clicks (
  id bigint generated always as identity primary key,
  link_id uuid references public.boost_links(id) on delete cascade,
  track_id uuid,
  platform text not null,
  kind text not null default 'link' check (kind in ('link', 'listen')),
  clicked_at timestamptz not null default now()
);
-- 以前の版（r1）からの移行（データは消えません）
alter table public.boost_clicks add column if not exists kind text not null default 'link' check (kind in ('link', 'listen'));
alter table public.boost_clicks alter column link_id drop not null;
create index if not exists boost_clicks_clicked_idx on public.boost_clicks(clicked_at);
create index if not exists boost_clicks_link_idx on public.boost_clicks(link_id, clicked_at);
create index if not exists boost_clicks_track_idx on public.boost_clicks(track_id, clicked_at);


-- =====================================================================
-- 2-2. 記録回数のカウンター（boost_rate_counters）※いたずら・大量アクセス対策
--    「範囲（全体／リンクごと／曲ごと）× 時間枠（1分／1日）」ごとに1行で回数を数える。
--    1行を「上限未満なら+1」で原子的に更新するため、同時アクセスでも上限を超えない。
--    数えるのは主キーで1行を読むだけなので、記録が増えてもデータベースの負荷は増えない。
--    2日より古い行は自動で削除する。誰も直接は読み書きできない（記録関数の中だけで使う）
-- =====================================================================
create table if not exists public.boost_rate_counters (
  scope text not null check (char_length(scope) <= 64),
  bucket timestamptz not null,
  n integer not null default 0 check (n >= 0),
  primary key (scope, bucket)
);
create index if not exists boost_rate_counters_bucket_idx on public.boost_rate_counters(bucket);


-- =====================================================================
-- 3. 投稿（boost_posts）
--    status：draft=下書き / scheduled=予定 / posted=投稿済み / skipped=見送り
--    post_mode：manual=手動投稿（現在はすべて手動）/ auto=公式API自動投稿（将来）
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


-- =====================================================================
-- 4. 自動投稿の試行記録（boost_post_attempts）※将来の公式API連携用
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
--    認証情報（トークン等）はここに保存しません。初期状態はすべて「未接続」。
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
-- 8. 投稿の自動処理（トリガー）
-- =====================================================================
create or replace function public.boost_posts_touch()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    new.created_by := old.created_by;   -- 作成者は変更不可
    new.created_at := old.created_at;
  end if;
  if new.status = 'posted' and new.posted_at is null then new.posted_at := now(); end if;
  if new.status <> 'posted' then new.posted_at := null; end if;
  -- 自動投稿は未接続のため、auto には設定できない
  if new.post_mode = 'auto' and not exists (
       select 1 from public.boost_sns_accounts a
       where a.platform = new.platform and a.auto_post_enabled) then
    raise exception 'このSNSは自動投稿に接続されていません';
  end if;
  return new;
end $$;

drop trigger if exists boost_posts_touch on public.boost_posts;
create trigger boost_posts_touch before insert or update on public.boost_posts
  for each row execute function public.boost_posts_touch();


-- =====================================================================
-- 9. アクセス権
--    ・未ログイン（anon）：BOOSTのテーブルには一切アクセス不可
--    ・ログイン会員（authenticated）：権限はあるが、RLSで管理者以外は0件・書き込み不可
--    ・回数カウンター：誰も直接アクセス不可
-- =====================================================================
revoke all on public.boost_links, public.boost_clicks, public.boost_posts, public.boost_post_attempts,
              public.boost_sns_accounts, public.boost_logs, public.boost_settings, public.boost_ai_usage,
              public.boost_rate_counters
  from public, anon, authenticated;

grant select, insert, delete on public.boost_links to authenticated;
grant select on public.boost_clicks to authenticated;
grant select, insert, update, delete on public.boost_posts to authenticated;
grant select on public.boost_post_attempts to authenticated;
grant select, update (account_label, note) on public.boost_sns_accounts to authenticated;  -- 接続フラグはアプリから変更不可
grant select, insert on public.boost_logs to authenticated;
grant select, update (value) on public.boost_settings to authenticated;
grant select on public.boost_ai_usage to authenticated;
-- boost_rate_counters：付与なし

alter table public.boost_links         enable row level security;
alter table public.boost_clicks        enable row level security;
alter table public.boost_posts         enable row level security;
alter table public.boost_post_attempts enable row level security;
alter table public.boost_sns_accounts  enable row level security;
alter table public.boost_logs          enable row level security;
alter table public.boost_settings      enable row level security;
alter table public.boost_ai_usage      enable row level security;
alter table public.boost_rate_counters enable row level security;   -- ポリシーなし＝誰も読み書き不可

-- BOOSTテーブルのポリシーをすべて作り直す（以前の版や手作業で追加された緩いポリシーを残さない）
do $$
declare p record; t text;
begin
  for p in select tablename, policyname from pg_policies
           where schemaname = 'public' and tablename like 'boost\_%' loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
  foreach t in array array['boost_links','boost_clicks','boost_posts','boost_post_attempts',
                           'boost_sns_accounts','boost_settings','boost_ai_usage'] loop
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())',
                   t || '_admin', t);
  end loop;
end $$;
-- 操作ログは本人名義でのみ追加可（なりすまし防止）
create policy boost_logs_admin on public.boost_logs for all to authenticated
  using (public.is_admin()) with check (public.is_admin() and actor = auth.uid());


-- =====================================================================
-- 10. 回数の上限チェック（記録関数の中だけで使う。外部からは呼べない）
--     上限未満なら1増やして true、上限に達していれば何もせず false。
--     同じ行への同時更新はデータベースが順番に処理するため、上限を超えることはない
-- =====================================================================
drop function if exists public.boost_click_allowed();   -- r3 の旧方式（あれば削除）

create or replace function public.boost_take_slot(p_scope text, p_bucket timestamptz, p_limit integer)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v integer;
begin
  insert into public.boost_rate_counters as c (scope, bucket, n) values (p_scope, p_bucket, 1)
  on conflict (scope, bucket) do update set n = c.n + 1 where c.n < p_limit
  returning c.n into v;
  return v is not null;
end $$;

-- 1回の記録の可否：対象ごと1分60回 → 全体1分300回 → 全体1日（日本時間）2万回 の順に確認
create or replace function public.boost_click_gate(p_scope text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  m timestamptz := date_trunc('minute', now());
  d timestamptz := date_trunc('day', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
  first_in_minute boolean;
begin
  if not public.boost_take_slot(p_scope, m, 60) then return false; end if;
  if not public.boost_take_slot('all:minute', m, 300) then return false; end if;
  -- 1分に1回だけ、2日より古いカウンターを片付ける
  select n = 1 into first_in_minute from public.boost_rate_counters where scope = 'all:minute' and bucket = m;
  if first_in_minute then
    delete from public.boost_rate_counters where bucket < now() - interval '2 days';
  end if;
  return public.boost_take_slot('all:day', d, 20000);
end $$;


-- =====================================================================
-- 11. 短縮リンクのクリック記録（/go/<code> から呼ばれる。ログイン不要）
--     ・存在するリンクのクリックだけ記録する
--     ・返すのは BOOST の宣伝ページのパス（/s/<楽曲ID>?src=<SNS>）だけ。外部URLは返さない
-- =====================================================================
create or replace function public.boost_resolve_link(p_code text, p_record boolean default true)
returns text
language plpgsql security definer set search_path = ''
as $$
declare l_id uuid; l_track uuid; l_platform text;
begin
  if p_code is null or p_code !~ '^[A-Za-z0-9]{6,12}$' then return null; end if;
  select id, track_id, platform into l_id, l_track, l_platform from public.boost_links where code = p_code;
  if l_id is null or l_track is null then return null; end if;
  if p_record is true and public.boost_click_gate('link:' || l_id::text) then
    insert into public.boost_clicks (link_id, track_id, platform, kind) values (l_id, l_track, l_platform, 'link');
  end if;
  return '/s/' || l_track::text || case when l_platform in ('x', 'instagram', 'tiktok', 'youtube') then '?src=' || l_platform else '' end;
end $$;


-- =====================================================================
-- 12. 宣伝ページの「AIMUSEで聴く」の記録（/out/<楽曲ID> から呼ばれる。ログイン不要）
--     ・AIMUSEで公開中の曲だけ記録する（AIMUSEの楽曲は読むだけ）
-- =====================================================================
create or replace function public.boost_record_listen(p_track uuid, p_platform text)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare plat text := case when p_platform in ('x', 'instagram', 'tiktok', 'youtube') then p_platform else 'other' end;
begin
  if p_track is null or not exists (select 1 from public.tracks t where t.id = p_track and t.status = 'public') then
    return false;
  end if;
  if not public.boost_click_gate('listen:' || p_track::text) then return false; end if;
  insert into public.boost_clicks (link_id, track_id, platform, kind) values (null, p_track, plat, 'listen');
  return true;
end $$;


-- =====================================================================
-- 13. AI生成の利用回数チェック（サーバー処理から管理者のログイン情報で呼ばれる）
--     1日の上限（初期30回）を超えると allowed=false。管理者以外はエラー。
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
  if lim <= 0 then
    return json_build_object('allowed', false, 'used', coalesce((select count from public.boost_ai_usage where day = today), 0), 'limit', lim);
  end if;
  insert into public.boost_ai_usage as u (day, count) values (today, 1)
  on conflict (day) do update set count = u.count + 1 where u.count < lim
  returning u.count into used;
  if used is null then
    select count into used from public.boost_ai_usage where day = today;
    return json_build_object('allowed', false, 'used', used, 'limit', lim);
  end if;
  return json_build_object('allowed', true, 'used', used, 'limit', lim);
end $$;


-- =====================================================================
-- 14. 関数の実行権限
--     ・Supabase は新しい関数を自動で誰でも実行可能にするため、まず全員から外す
--     ・未ログインで呼べるのは「クリック記録」の2つだけ
-- =====================================================================
revoke all on function public.boost_posts_touch() from public, anon, authenticated;
revoke all on function public.boost_take_slot(text, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.boost_click_gate(text) from public, anon, authenticated;
revoke all on function public.boost_resolve_link(text, boolean) from public, anon, authenticated;
revoke all on function public.boost_record_listen(uuid, text) from public, anon, authenticated;
revoke all on function public.boost_ai_take_quota() from public, anon, authenticated;
grant execute on function public.boost_resolve_link(text, boolean) to anon, authenticated;
grant execute on function public.boost_record_listen(uuid, text) to anon, authenticated;
grant execute on function public.boost_ai_take_quota() to authenticated;


-- =====================================================================
-- 15. 確認（結果に9行・すべて RLS有効 = true、未ログイン権限 = なし と表示されればOK）
-- =====================================================================
select c.relname as "BOOSTテーブル",
       c.relrowsecurity as "RLS有効",
       case when has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE') then 'あり（要確認）' else 'なし' end as "未ログイン権限"
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname like 'boost\_%' and c.relkind = 'r'
order by 1;
