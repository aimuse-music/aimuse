-- =====================================================================
-- AIMUSE v1.17 アクセス解析（管理者専用）
--   ・追加のみ・何度実行しても同じ結果。既存の会員・楽曲・再生数・歌詞のデータは変更しません
--   ・訪問者は「匿名ID」（端末のブラウザが作るランダムな値）で数えます。
--     保存するのは匿名IDを秘密の値で変換（ハッシュ化）した値・画面の種類・日時だけで、
--     IPアドレス・メールアドレス・会員IDは解析の記録に保存しません
--   ・管理者のアクセスは数えません（ログイン中は会員情報で判定、
--     管理者としてログインしたことがある端末は、その端末の匿名IDで判定）
--   ・同じ端末で同じ画面を30分以内に開き直した分は1回として数えます
--   ・生のアクセス記録は90日で削除し、日別・月別の集計値だけを残します
--   ・再生数（tracks.plays）の数え方は変えません。数えたときにだけ、日別の集計にも1を足します
--     （管理者の再生は日別の集計に入れません。公開中の再生数は今までどおりです）
--   ・解析データは誰も直接読めません。集計を見る関数は管理者以外が呼ぶとエラーになります
--   前提：構築SQL（v1.5）以降。元に戻す：rollback/rollback_v1_17.sql
-- =====================================================================
begin;

do $$ begin
  if to_regprocedure('public.increment_plays(uuid)') is null or to_regclass('public.play_events') is null
     or to_regprocedure('public.is_admin()') is null or to_regclass('aimuse_private.settings') is null then
    raise exception '前提の構築SQLが未実行です。何も変更せずに中止しました。';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. 設定（解析用の秘密の値は、再生数用の play_salt とは別。既にあれば変更しない）
-- ---------------------------------------------------------------------
insert into aimuse_private.settings (key, value) values
  ('analytics_salt', encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex')),
  ('analytics_enabled', 'on'),                                                   -- off にすると記録を止める（緊急停止用）
  ('analytics_started', to_char((now() at time zone 'Asia/Tokyo')::date, 'YYYY-MM-DD')),  -- 計測開始日（日本時間）
  ('analytics_raw_from', to_char((now() at time zone 'Asia/Tokyo')::date, 'YYYY-MM-DD'))  -- 生の記録がそろっている最初の日
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. 記録用の表（すべて aimuse_private：アプリからは直接読み書きできない）
-- ---------------------------------------------------------------------
-- 画面の表示（生の記録・90日で削除）
create table if not exists aimuse_private.analytics_views (
  vid_hash   text not null,          -- 匿名IDを秘密の値で変換した値（元の匿名IDには戻せない）
  page       text not null,          -- 画面の種類（home・search など。曲やアーティストのIDは記録しない）
  day        date not null,          -- 日本時間の日付
  created_at timestamptz not null default now()
);
create index if not exists analytics_views_day_idx on aimuse_private.analytics_views (day);
create index if not exists analytics_views_vid_idx on aimuse_private.analytics_views (vid_hash, page, created_at);

-- 管理者としてログインしたことがある端末（匿名IDの変換値だけ）
create table if not exists aimuse_private.analytics_excluded (
  vid_hash   text primary key,
  created_at timestamptz not null default now()
);

-- 大量送信の防止（接続元ごとの1時間の件数。2時間で削除。接続元はIPアドレスを元に戻せない形に変換した値）
create table if not exists aimuse_private.analytics_rate (
  bucket       text not null,
  window_start timestamptz not null,
  hits         integer not null default 0,
  primary key (bucket, window_start)
);
create table if not exists aimuse_private.analytics_rate_ids (
  bucket       text not null,
  window_start timestamptz not null,
  id_hash      text not null,        -- 接続元と匿名IDを組み合わせて変換した値（解析の記録とは照合できない）
  primary key (bucket, window_start, id_hash)
);

-- 集計値（個人を区別する情報は含まない）
create table if not exists aimuse_private.analytics_daily (
  day        date primary key,
  pv         integer not null,
  uu         integer not null,
  updated_at timestamptz not null default now()
);
create table if not exists aimuse_private.analytics_monthly (
  month      date primary key,       -- 月の初日
  pv         integer not null,
  uu         integer not null,
  updated_at timestamptz not null default now()
);
create table if not exists aimuse_private.analytics_plays_daily (
  day      date not null,
  track_id uuid not null,            -- 曲のIDだけ（誰が聴いたかは記録しない）
  plays    integer not null default 0,
  primary key (day, track_id)
);

alter table aimuse_private.analytics_views      enable row level security;
alter table aimuse_private.analytics_excluded   enable row level security;
alter table aimuse_private.analytics_rate       enable row level security;
alter table aimuse_private.analytics_rate_ids   enable row level security;
alter table aimuse_private.analytics_daily      enable row level security;
alter table aimuse_private.analytics_monthly    enable row level security;
alter table aimuse_private.analytics_plays_daily enable row level security;
do $$ declare t text; r text; begin
  foreach t in array array['analytics_views','analytics_excluded','analytics_rate','analytics_rate_ids',
                           'analytics_daily','analytics_monthly','analytics_plays_daily'] loop
    execute format('revoke all on aimuse_private.%I from public', t);
    foreach r in array array['anon','authenticated','service_role'] loop
      if exists (select 1 from pg_roles where rolname = r) then
        execute format('revoke all on aimuse_private.%I from %I', t, r);
      end if;
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 3. 内部の関数
-- ---------------------------------------------------------------------
-- 匿名IDの変換（秘密の値つき。元の匿名IDには戻せない）
create or replace function aimuse_private.analytics_vid_hash(p_vid uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case when s.value is null or p_vid is null then null
              else encode(sha256(convert_to('vid|' || s.value || '|' || p_vid::text, 'UTF8')), 'hex') end
  from (select (select value from aimuse_private.settings where key = 'analytics_salt') as value) s;
$$;

-- 接続元の変換値（大量送信の防止だけに使用。再生数と同じく、偽装できる X-Forwarded-For は使わない）
create or replace function aimuse_private.analytics_ip_bucket()
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_headers json;
  v_header text;
  v_ip text;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  if v_headers is not null then
    for v_header in
      select trim(h) from unnest(string_to_array(
        coalesce((select s.value from aimuse_private.settings s where s.key = 'client_ip_headers'),
                 'cf-connecting-ip'), ',')) as h
    loop
      v_ip := nullif(trim(v_headers->>lower(v_header)), '');
      exit when v_ip is not null;
    end loop;
  end if;
  if v_ip is null or v_ip !~ '^[0-9a-fA-F:.]{3,45}$' then
    return 'noip';
  end if;
  -- IPv6 は /64 単位でまとめる（同じ回線でアドレスを替えて上限を逃れるのを防ぐ）
  begin
    if family(v_ip::inet) = 6 then
      v_ip := host(network(set_masklen(v_ip::inet, 64)));
    end if;
  exception when others then
    return 'noip';
  end;
  return encode(sha256(convert_to('rate|' || coalesce((select s.value from aimuse_private.settings s where s.key = 'analytics_salt'), '')
                                  || '|' || v_ip, 'UTF8')), 'hex');
end;
$$;

-- 再生数を数える処理（v1.5 の increment_plays の中身をそのまま移したもの。数えたら true）
create or replace function aimuse_private.play_count_core(tid uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_key text := public.request_viewer_key();
  v_window timestamptz := date_trunc('hour', now());
  v_new integer;
  v_upd integer := 0;
begin
  if v_key is null then
    return false;  -- 利用者を判定できない接続は数えない
  end if;
  if not exists (select 1 from public.tracks t where t.id = tid and t.status = 'public') then
    return false;
  end if;
  if (select count(*) from public.play_events e
      where e.viewer_key = v_key and e.window_start = v_window) >= 60 then
    return false;
  end if;

  insert into public.play_events (track_id, viewer_key, window_start)
  values (tid, v_key, v_window)
  on conflict do nothing;
  get diagnostics v_new = row_count;

  if v_new = 1 then
    update public.tracks set plays = plays + 1 where id = tid and status = 'public';
    get diagnostics v_upd = row_count;
  end if;

  -- 古い再生記録の掃除（呼び出しのおよそ100回に1回）
  if random() < 0.01 then
    delete from public.play_events where created_at < now() - interval '2 days';
  end if;
  return v_upd = 1;
end;
$$;

-- 日別の再生数に1を足す（管理者・管理者の端末・停止中は足さない）
create or replace function aimuse_private.analytics_note_play(tid uuid, p_vid uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce((select value from aimuse_private.settings where key = 'analytics_enabled'), 'on') <> 'on' then
    return;
  end if;
  if auth.uid() is not null and public.is_admin() then
    return;
  end if;
  if p_vid is not null and exists (select 1 from aimuse_private.analytics_excluded e
                                   where e.vid_hash = aimuse_private.analytics_vid_hash(p_vid)) then
    return;
  end if;
  insert into aimuse_private.analytics_plays_daily (day, track_id, plays)
  values ((now() at time zone 'Asia/Tokyo')::date, tid, 1)
  on conflict (day, track_id) do update set plays = aimuse_private.analytics_plays_daily.plays + 1;
end;
$$;

-- 集計値の作成と古い記録の削除（毎日1回＋管理画面を開いたとき。p_force = false は前回から1時間未満なら何もしない）
create or replace function aimuse_private.analytics_maintain(p_force boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_cut date := (now() at time zone 'Asia/Tokyo')::date - 89;   -- これより前の日の生の記録は削除（90日分を保存）
  v_start date;
  v_from date;
  v_last timestamptz;
  v_purged integer := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('aimuse_analytics_maintain')) then
    return jsonb_build_object('result', 'busy');
  end if;
  v_last := nullif((select value from aimuse_private.settings where key = 'analytics_last_maintain'), '')::timestamptz;
  if not p_force and v_last is not null and v_last > now() - interval '1 hour' then
    return jsonb_build_object('result', 'skipped');
  end if;
  v_start := coalesce((select value from aimuse_private.settings where key = 'analytics_started')::date, v_today);
  v_from  := coalesce((select value from aimuse_private.settings where key = 'analytics_raw_from')::date, v_start);

  -- 日別：生の記録がそろっている日だけ作り直す（それより前の日は確定済み）
  delete from aimuse_private.analytics_daily where day >= v_from;
  insert into aimuse_private.analytics_daily (day, pv, uu, updated_at)
  select v.day, count(*), count(distinct v.vid_hash), now()
  from aimuse_private.analytics_views v
  where v.day >= v_from
    and not exists (select 1 from aimuse_private.analytics_excluded e where e.vid_hash = v.vid_hash)
  group by v.day;

  -- 月別：その月の生の記録がすべてそろっている月だけ作り直す
  delete from aimuse_private.analytics_monthly m
  where m.month >= date_trunc('month', v_from)::date and (m.month >= v_from or v_from <= v_start);
  insert into aimuse_private.analytics_monthly (month, pv, uu, updated_at)
  select date_trunc('month', v.day)::date, count(*), count(distinct v.vid_hash), now()
  from aimuse_private.analytics_views v
  where v.day >= v_from
    and not exists (select 1 from aimuse_private.analytics_excluded e where e.vid_hash = v.vid_hash)
    and (date_trunc('month', v.day)::date >= v_from or v_from <= v_start)
  group by 1;

  -- 90日より前の生の記録を削除（集計値は残る）
  delete from aimuse_private.analytics_views where day < v_cut;
  get diagnostics v_purged = row_count;
  if v_cut > v_from then
    insert into aimuse_private.settings (key, value) values ('analytics_raw_from', to_char(v_cut, 'YYYY-MM-DD'))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;

  -- 大量送信の防止用の記録は2時間で削除
  delete from aimuse_private.analytics_rate where window_start < now() - interval '2 hours';
  delete from aimuse_private.analytics_rate_ids where window_start < now() - interval '2 hours';

  insert into aimuse_private.settings (key, value) values ('analytics_last_maintain', now()::text)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('result', 'done', 'purged', v_purged);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. アプリから呼ぶ関数
-- ---------------------------------------------------------------------
-- 画面の表示を記録（未ログインでも呼べる。条件に合わないものは黙って数えない）
create or replace function public.analytics_track(p_vid uuid, p_page text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_hour timestamptz := date_trunc('hour', now());
  v_day date := (now() at time zone 'Asia/Tokyo')::date;
  v_vid text;
  v_bucket text;
  v_id text;
  v_hits integer;
begin
  -- 決まった画面の名前と、ブラウザが作るランダムな匿名ID（UUID v4）だけを受け付ける
  if p_vid is null or p_page is null
     or p_page not in ('home','search','upload','me','artist','legal','profile','follows','playlist',
                       'guide','settings','account','lyricsync')
     or p_vid::text !~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    return;
  end if;
  if coalesce((select value from aimuse_private.settings where key = 'analytics_enabled'), 'on') <> 'on' then
    return;
  end if;
  if auth.uid() is not null and public.is_admin() then
    return;  -- 管理者のアクセスは数えない
  end if;
  v_vid := aimuse_private.analytics_vid_hash(p_vid);
  if v_vid is null then
    return;
  end if;

  -- 大量送信の防止：同じ接続元から1時間に600件・新しい匿名ID 30個まで
  v_bucket := aimuse_private.analytics_ip_bucket();
  insert into aimuse_private.analytics_rate (bucket, window_start, hits) values (v_bucket, v_hour, 1)
  on conflict (bucket, window_start) do update set hits = aimuse_private.analytics_rate.hits + 1
  returning hits into v_hits;
  if v_hits > 600 then
    return;
  end if;
  v_id := encode(sha256(convert_to(v_bucket || '|' || v_vid, 'UTF8')), 'hex');
  if not exists (select 1 from aimuse_private.analytics_rate_ids r
                 where r.bucket = v_bucket and r.window_start = v_hour and r.id_hash = v_id) then
    if (select count(*) from aimuse_private.analytics_rate_ids r
        where r.bucket = v_bucket and r.window_start = v_hour) >= 30 then
      return;
    end if;
    insert into aimuse_private.analytics_rate_ids (bucket, window_start, id_hash)
    values (v_bucket, v_hour, v_id) on conflict do nothing;
  end if;

  if exists (select 1 from aimuse_private.analytics_excluded e where e.vid_hash = v_vid) then
    return;  -- 管理者としてログインしたことがある端末
  end if;
  -- 同じ端末で同じ画面を30分以内に開き直した分は数えない（再読み込み・再描画の対策）
  if exists (select 1 from aimuse_private.analytics_views v
             where v.vid_hash = v_vid and v.page = p_page and v.created_at > v_now - interval '30 minutes') then
    return;
  end if;
  -- 1つの端末で1日200件まで
  if (select count(*) from aimuse_private.analytics_views v where v.vid_hash = v_vid and v.day = v_day) >= 200 then
    return;
  end if;

  insert into aimuse_private.analytics_views (vid_hash, page, day, created_at) values (v_vid, p_page, v_day, v_now);

  if random() < 0.005 then
    perform aimuse_private.analytics_maintain(false);
  end if;
end;
$$;

-- 管理者としてログインした端末を、以後の計測から外す（管理者のみ）
create or replace function public.analytics_exclude_device(p_vid uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'NOT_ALLOWED: 管理者のみ利用できます';
  end if;
  if p_vid is null or (select count(*) from aimuse_private.analytics_excluded) >= 200 then
    return;
  end if;
  insert into aimuse_private.analytics_excluded (vid_hash) values (aimuse_private.analytics_vid_hash(p_vid))
  on conflict do nothing;
end;
$$;

-- 再生数を数える（v1.17 以降のアプリ用。数え方は increment_plays と同じで、どちらか一方だけを呼ぶ）
--   匿名IDを受け取るのは、管理者としてログインしたことがある端末の再生を日別の集計から外すため
create or replace function public.count_play(tid uuid, p_vid uuid default null)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if aimuse_private.play_count_core(tid) then
    begin
      perform aimuse_private.analytics_note_play(tid, p_vid);
    exception when others then
      null;  -- 解析の記録に失敗しても、再生数は必ず数える
    end;
  end if;
end;
$$;

-- 既存の関数（古い版のアプリ用）：数え方は同じ。数えたときに日別の集計にも1を足す
create or replace function public.increment_plays(tid uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if aimuse_private.play_count_core(tid) then
    begin
      perform aimuse_private.analytics_note_play(tid, null);
    exception when others then
      null;  -- 解析の記録に失敗しても、再生数は必ず数える
    end;
  end if;
end;
$$;

-- 管理者の集計画面：訪問者数（推計）・表示数・日別／月別の推移・画面別
create or replace function public.admin_analytics()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_from date;
  v_last timestamptz;
  v_hits integer;
  v_out jsonb;
begin
  if not public.is_admin() then
    raise exception 'NOT_ALLOWED: 管理者のみ利用できます';
  end if;
  -- 集計の呼び出しは1時間に120回まで
  insert into aimuse_private.analytics_rate (bucket, window_start, hits) values ('admin', date_trunc('hour', now()), 1)
  on conflict (bucket, window_start) do update set hits = aimuse_private.analytics_rate.hits + 1
  returning hits into v_hits;
  if v_hits > 120 then
    raise exception 'RATE_LIMIT: 短時間に何度も読み込んだため、しばらく待ってからお試しください';
  end if;
  -- 集計値は5分ごとに作り直す
  v_last := nullif((select value from aimuse_private.settings where key = 'analytics_last_maintain'), '')::timestamptz;
  if v_last is null or v_last < now() - interval '5 minutes' then
    perform aimuse_private.analytics_maintain(true);
  end if;
  v_from := coalesce((select value from aimuse_private.settings where key = 'analytics_raw_from')::date, v_today);

  with v as (
    select x.vid_hash, x.day, x.page from aimuse_private.analytics_views x
    where not exists (select 1 from aimuse_private.analytics_excluded e where e.vid_hash = x.vid_hash)
  ),
  plays as (select p.day, sum(p.plays)::bigint as n from aimuse_private.analytics_plays_daily p group by p.day),
  days as (select d::date as day from generate_series(v_today - 29, v_today, interval '1 day') d),
  months as (select (date_trunc('month', v_today) - make_interval(months => k))::date as month from generate_series(0, 11) k)
  select jsonb_build_object(
    'today', v_today,
    'started', (select value from aimuse_private.settings where key = 'analytics_started'),
    'raw_from', v_from,
    'enabled', coalesce((select value from aimuse_private.settings where key = 'analytics_enabled'), 'on') = 'on',
    'updated_at', (select value from aimuse_private.settings where key = 'analytics_last_maintain'),
    'summary', jsonb_build_object(
      'today',     (select jsonb_build_object('uu', count(distinct vid_hash), 'pv', count(*)) from v where day = v_today),
      'yesterday', (select jsonb_build_object('uu', count(distinct vid_hash), 'pv', count(*)) from v where day = v_today - 1),
      'd7',        (select jsonb_build_object('uu', count(distinct vid_hash), 'pv', count(*)) from v where day > v_today - 7),
      'd30',       (select jsonb_build_object('uu', count(distinct vid_hash), 'pv', count(*)) from v where day > v_today - 30)
    ),
    'plays', jsonb_build_object(
      'today', coalesce((select n from plays where day = v_today), 0),
      'yesterday', coalesce((select n from plays where day = v_today - 1), 0),
      'd7',  coalesce((select sum(n) from plays where day > v_today - 7), 0),
      'd30', coalesce((select sum(n) from plays where day > v_today - 30), 0),
      'all', coalesce((select sum(n) from plays), 0),
      'total_public', coalesce((select sum(t.plays) from public.tracks t), 0)
    ),
    'daily', (select jsonb_agg(jsonb_build_object('day', d.day, 'uu', coalesce(a.uu, 0), 'pv', coalesce(a.pv, 0),
                                                  'plays', coalesce(p.n, 0)) order by d.day)
              from days d left join aimuse_private.analytics_daily a on a.day = d.day left join plays p on p.day = d.day),
    'monthly', (select jsonb_agg(jsonb_build_object('month', m.month, 'uu', coalesce(a.uu, 0), 'pv', coalesce(a.pv, 0),
                                                    'plays', coalesce((select sum(p.n) from plays p where date_trunc('month', p.day)::date = m.month), 0))
                                 order by m.month)
                from months m left join aimuse_private.analytics_monthly a on a.month = m.month),
    'pages', (select coalesce(jsonb_agg(jsonb_build_object('page', page, 'pv', n) order by n desc), '[]'::jsonb)
              from (select page, count(*) as n from v where day > v_today - 30 group by page) s)
  ) into v_out;
  return v_out;
end;
$$;

-- 管理者の集計画面：楽曲別の再生ランキング（p_days：7・30・90、0 は計測開始からの合計。並びは期間内の再生数）
--   累計（total）は公開中の再生数（tracks.plays：管理者の再生や計測開始前の分も含む）
create or replace function public.admin_analytics_ranking(p_days integer default 30, p_limit integer default 50)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_days integer := case when p_days in (0, 7, 30, 90) then p_days else 30 end;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if not public.is_admin() then
    raise exception 'NOT_ALLOWED: 管理者のみ利用できます';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('track_id', r.id, 'title', r.title, 'artist', r.artist,
                                                 'status', r.status, 'period', r.period, 'total', r.plays)
                              order by r.period desc, r.plays desc, r.title), '[]'::jsonb)
    from (
      select t.id, t.title, t.artist, t.status, t.plays, coalesce(sum(p.plays), 0)::bigint as period
      from public.tracks t
      left join aimuse_private.analytics_plays_daily p
        on p.track_id = t.id and (v_days = 0 or p.day > v_today - v_days)
      where t.status in ('public', 'hidden')
      group by t.id
      order by period desc, t.plays desc, t.title
      limit v_limit
    ) r
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 5. 実行権限（内部の関数は誰も直接呼べない）
-- ---------------------------------------------------------------------
revoke all on function aimuse_private.analytics_vid_hash(uuid) from public;
revoke all on function aimuse_private.analytics_ip_bucket() from public;
revoke all on function aimuse_private.play_count_core(uuid) from public;
revoke all on function aimuse_private.analytics_note_play(uuid, uuid) from public;
revoke all on function aimuse_private.analytics_maintain(boolean) from public;
revoke all on function public.analytics_track(uuid, text) from public;
revoke all on function public.analytics_exclude_device(uuid) from public;
revoke all on function public.count_play(uuid, uuid) from public;
revoke all on function public.admin_analytics() from public;
revoke all on function public.admin_analytics_ranking(integer, integer) from public;
do $$ declare r text; begin
  foreach r in array array['anon','authenticated','service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on function aimuse_private.analytics_vid_hash(uuid) from %I', r);
      execute format('revoke all on function aimuse_private.analytics_ip_bucket() from %I', r);
      execute format('revoke all on function aimuse_private.play_count_core(uuid) from %I', r);
      execute format('revoke all on function aimuse_private.analytics_note_play(uuid, uuid) from %I', r);
      execute format('revoke all on function aimuse_private.analytics_maintain(boolean) from %I', r);
      execute format('revoke all on function public.analytics_track(uuid, text) from %I', r);
      execute format('revoke all on function public.analytics_exclude_device(uuid) from %I', r);
      execute format('revoke all on function public.count_play(uuid, uuid) from %I', r);
      execute format('revoke all on function public.admin_analytics() from %I', r);
      execute format('revoke all on function public.admin_analytics_ranking(integer, integer) from %I', r);
    end if;
  end loop;
end $$;
grant execute on function public.analytics_track(uuid, text) to anon, authenticated;
grant execute on function public.count_play(uuid, uuid) to anon, authenticated;
grant execute on function public.analytics_exclude_device(uuid) to authenticated;
grant execute on function public.admin_analytics() to authenticated;
grant execute on function public.admin_analytics_ranking(integer, integer) to authenticated;
-- increment_plays は既存の権限のまま（create or replace は権限を変えない）

-- ---------------------------------------------------------------------
-- 6. 毎日の集計（日本時間 0:20。pg_cron がある場合だけ。同じ名前なら上書き）
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('aimuse-analytics-maintain', '20 15 * * *',
                          'select aimuse_private.analytics_maintain(true)');
  else
    raise notice 'pg_cron がないため、毎日の集計は登録しませんでした（管理画面を開いたとき・アクセスのたまに集計します）';
  end if;
end $$;

commit;
