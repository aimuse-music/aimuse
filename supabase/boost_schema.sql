-- =====================================================================
-- AIMUSE BOOST 追加SQL（Ver.0.2 r9）
-- AIMUSE と同じ Supabase プロジェクトの SQL Editor に全文を貼り付けて、1回実行してください。
--
-- ・AIMUSE の既存テーブル・データ・認証設定・関数は一切変更しません（読むだけ）
-- ・新しく「boost_」で始まるテーブルと関数だけを追加・更新します
-- ・変更はすべて【1つの文（DOブロック）】の中で行います。途中で1か所でも失敗すると、
--   実行方法に関係なく全体が自動的に取り消され、データベースは実行前の状態のままです
-- ・最初に構造チェックを行い、想定外の状態なら何も変更せずに中止します
-- ・何度実行しても壊れません（既存のBOOSTデータも消えません）
-- ・変更の最後に、同じ取引の中で必須の確認（RLS・権限・ポリシー条件など）を行い、
--   NGが1件でもあれば全体を取り消します（NGのまま変更が残ることはありません）
-- ・最後の表（読み取りのみ）は、確認結果を一覧で見るためのものです
-- ・管理者の判定は AIMUSE と同じ public.is_admin()（profiles.is_admin = true）を使います
-- ・宣伝の対象は「AIMUSEで現在公開中（tracks.status = 'public'）の楽曲」だけです。
--   リンク・投稿の作成も、クリックの記録も、この同じ条件で判定します
-- =====================================================================

do $boost$
declare
  v_def text;
  v_rec record;
  v_tbl text;
  v_ng integer;
  v_total integer;
  v_detail text;
  v_ids uuid[];
  v_flags boolean[];
  v_i integer;
  v_got boolean;
  -- BOOSTテーブルの想定構造（列名 → 型）。既存テーブルがあれば、これと照合する
  v_expected jsonb := '{
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
  v_legacy jsonb := '{"boost_links": {"destination":"text"}}'::jsonb;
  -- 以前の版で無かった列（このSQLで追加する）
  v_addable jsonb := '{"boost_clicks": ["kind"]}'::jsonb;
begin
  -- ===================================================================
  -- 0. 事前チェック（ここで中止された場合、データベースは何も変更されていません）
  -- ===================================================================
  -- (1) AIMUSE本体が構築済みか
  if to_regclass('public.tracks') is null or to_regclass('public.profiles') is null then
    raise exception 'AIMUSE の構築SQLが未実行です（public.tracks / public.profiles がありません）。中止しました。';
  end if;
  -- (2) 管理者判定 public.is_admin() が想定どおりか（定義そのものを照合。違えば中止）
  --     ・本体：AIMUSE構築SQLの定義と完全一致（空白の違いだけは許容）
  --       select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
  --     ・戻り値 boolean／言語 sql／SECURITY DEFINER／search_path 固定
  if to_regprocedure('public.is_admin()') is null then
    raise exception 'public.is_admin() がありません。中止しました。';
  end if;
  select p.prosrc into v_def from pg_proc p where p.oid = 'public.is_admin()'::regprocedure;
  if md5(btrim(regexp_replace(v_def, '\s+', ' ', 'g'))) <> '065dbcd2c17f6a4da4ba7cc6b24dad9e'
     or not exists (select 1 from pg_proc p join pg_language l on l.oid = p.prolang
                    where p.oid = 'public.is_admin()'::regprocedure and p.prorettype = 'boolean'::regtype
                      and l.lanname = 'sql' and p.prosecdef and 'search_path=""' = any(p.proconfig)) then
    raise exception 'public.is_admin() の定義がAIMUSE構築SQLと一致しません（現在の本体：%）。安全のため中止しました。', btrim(regexp_replace(v_def, '\s+', ' ', 'g'));
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles' and column_name = 'is_admin' and data_type = 'boolean') then
    raise exception 'profiles.is_admin（boolean）がありません。中止しました。';
  end if;
  -- (3) 会員・未ログイン・全員（PUBLIC）が profiles.is_admin を変更・追加できないこと
  --     （データベースの権限情報で判定。権限がなければ、どんな方法でも書き換えられない）
  if has_column_privilege('authenticated', 'public.profiles', 'is_admin', 'UPDATE')
     or has_column_privilege('anon', 'public.profiles', 'is_admin', 'UPDATE')
     or has_column_privilege('public', 'public.profiles', 'is_admin', 'UPDATE')
     or has_column_privilege('authenticated', 'public.profiles', 'is_admin', 'INSERT')
     or has_column_privilege('anon', 'public.profiles', 'is_admin', 'INSERT')
     or has_column_privilege('public', 'public.profiles', 'is_admin', 'INSERT') then
    raise exception '会員などが profiles.is_admin を変更できる権限を持っています。AIMUSE側の権限を確認してください。中止しました。';
  end if;
  -- AIMUSE側の二重の保護（管理者フラグの変更を拒否するトリガー）が有効であること
  if not exists (select 1 from pg_trigger g
                 where g.tgrelid = 'public.profiles'::regclass and not g.tgisinternal
                   and g.tgfoid = 'public.protect_profile_flags'::regproc and g.tgenabled <> 'D'
                   and (g.tgtype & 1) = 1 and (g.tgtype & 2) = 2 and (g.tgtype & 16) = 16) then
    raise exception 'profiles の保護トリガー（protect_profile_flags）が見つからないか無効です。中止しました。';
  end if;
  -- (3-2) 実際の動作で確認（読み取りのみ）：AIMUSE の通常の会員として is_admin() を呼び、結果を確かめる
  --     ・未ログイン → false ／ 存在しない会員 → false
  --     ・登録済みの全会員（最大5000人）→ profiles.is_admin と同じ値（管理者だけ true）
  --     ・管理者が1人以上いる
  select coalesce(array_agg(p.id order by p.id), '{}'), coalesce(array_agg(p.is_admin order by p.id), '{}')
    into v_ids, v_flags
  from (select id, is_admin from public.profiles order by id limit 5000) p;
  if not (true = any(v_flags)) then
    raise exception '管理者（profiles.is_admin = true）が1人もいません。中止しました。';
  end if;
  begin
    execute 'set local role anon';
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('request.jwt.claim.sub', '', true);
    if public.is_admin() then raise exception using errcode = 'BST02', message = '未ログインで is_admin() が true'; end if;
    execute 'set local role authenticated';
    perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid())::text, true);
    perform set_config('request.jwt.claim.sub', current_setting('request.jwt.claims')::json ->> 'sub', true);
    if public.is_admin() then raise exception using errcode = 'BST02', message = '存在しない会員で is_admin() が true'; end if;
    for v_i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
      perform set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', v_ids[v_i])::text, true);
      perform set_config('request.jwt.claim.sub', v_ids[v_i]::text, true);
      v_got := public.is_admin();
      if v_got is distinct from v_flags[v_i] then
        raise exception using errcode = 'BST02', message = '会員 ' || v_ids[v_i] || ' の is_admin() が ' || coalesce(v_got::text, 'null') || '（profiles では ' || v_flags[v_i] || '）';
      end if;
    end loop;
    execute 'reset role';
    perform set_config('request.jwt.claims', '', true);
    perform set_config('request.jwt.claim.sub', '', true);
  exception
    when sqlstate 'BST02' then
      raise exception 'is_admin() の動作確認で問題が見つかりました（%）。中止しました。', sqlerrm;
    when insufficient_privilege then
      raise exception 'is_admin() の動作確認ができませんでした（実行者 % が会員の立場に切り替えられません：%）。中止しました。', current_user, sqlerrm;
  end;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'tracks' and column_name = 'status') then
    raise exception 'tracks.status がありません。中止しました。';
  end if;
  -- (4) 既にBOOSTテーブルがある場合、構造を照合（想定外なら中止）
  for v_rec in
    select distinct c.relname as table_name from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname like 'boost\_%' and c.relkind in ('r', 'v', 'm', 'p', 'f')
      and c.relname not in (select jsonb_object_keys(v_expected))
  loop
    raise exception '想定外のBOOSTテーブル % があります。中止しました。', v_rec.table_name;
  end loop;
  for v_rec in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in (select jsonb_object_keys(v_expected)) and c.relkind <> 'r'
  loop
    raise exception '% がテーブルではありません。中止しました。', v_rec.relname;
  end loop;
  for v_rec in
    select c.table_name, c.column_name, c.data_type
    from information_schema.columns c
    where c.table_schema = 'public' and c.table_name in (select jsonb_object_keys(v_expected))
  loop
    if v_expected -> v_rec.table_name ? v_rec.column_name then
      if v_expected -> v_rec.table_name ->> v_rec.column_name <> v_rec.data_type then
        raise exception '%.% の型が想定（%）と異なります（現在：%）。中止しました。',
          v_rec.table_name, v_rec.column_name, v_expected -> v_rec.table_name ->> v_rec.column_name, v_rec.data_type;
      end if;
    elsif v_legacy -> v_rec.table_name ? v_rec.column_name then
      if v_legacy -> v_rec.table_name ->> v_rec.column_name <> v_rec.data_type then
        raise exception '%.% の型が想定と異なります。中止しました。', v_rec.table_name, v_rec.column_name;
      end if;
    else
      raise exception '%.% は想定外の列です。中止しました。', v_rec.table_name, v_rec.column_name;
    end if;
  end loop;
  for v_rec in
    select t.key as table_name, k.key as column_name
    from jsonb_each(v_expected) t, jsonb_each_text(t.value) k
    where to_regclass('public.' || t.key) is not null
      and not exists (select 1 from information_schema.columns c
                      where c.table_schema = 'public' and c.table_name = t.key and c.column_name = k.key)
  loop
    if not coalesce((v_addable -> v_rec.table_name) ? v_rec.column_name, false) then
      raise exception '%.% がありません（想定外の構造）。中止しました。', v_rec.table_name, v_rec.column_name;
    end if;
  end loop;
  -- (5) 既存のBOOSTテーブルが、このSQLを実行する人の所有であること
  --     （所有者が違うと、記録用の関数がテーブルに書き込めない・権限の付け直しができないため）
  for v_rec in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in (select jsonb_object_keys(v_expected))
      and c.relowner <> (select oid from pg_roles where rolname = current_user)
  loop
    raise exception '% の所有者が実行者（%）と異なります。中止しました。', v_rec.relname, current_user;
  end loop;

  -- (6) 既にBOOSTテーブルがある場合（再実行・旧版からの更新）、先に全テーブルをまとめて確保する
  --     ・クリック記録の処理と同じ順番（リンク → カウンター → クリック → その他）で確保するため、
  --       公開中のリンクが同時に使われていても、互いに待ち合って止まる（デッドロック）ことがない
  --     ・10秒以内に確保できなければ中止（何も変更されない。少し待って再実行すればよい）
  --     ・確保している間（通常1秒未満）、計測リンクの記録は待たされるだけで失われない
  perform set_config('lock_timeout', '10s', true);
  foreach v_tbl in array array['boost_links','boost_rate_counters','boost_clicks','boost_posts','boost_post_attempts',
                               'boost_sns_accounts','boost_logs','boost_settings','boost_ai_usage'] loop
    if to_regclass('public.' || v_tbl) is not null then
      execute format('lock table public.%I in access exclusive mode', v_tbl);
    end if;
  end loop;


  -- ===================================================================
  -- 1. 宣伝リンク（boost_links）
  --    SNSに載せる短縮リンク /go/<code>。移動先は「BOOSTの宣伝ページ /s/<楽曲ID>」に固定。
  --    任意のURLは保存できない（外部サイトへの転送に悪用されないため）
  --    track_id は AIMUSE の楽曲ID（外部キーは付けず、AIMUSE側の削除処理に影響させない）
  -- ===================================================================
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
  if exists (select 1 from information_schema.columns where table_schema = 'public'
             and table_name = 'boost_links' and column_name = 'destination') then
    alter table public.boost_links alter column destination drop not null;   -- 以前の値は残すが、移動には使わない
  end if;
  if not exists (select 1 from pg_constraint where conname = 'boost_links_track_required'
                 and conrelid = 'public.boost_links'::regclass)
     and exists (select 1 from information_schema.columns where table_schema = 'public'
                 and table_name = 'boost_links' and column_name = 'track_id' and is_nullable = 'YES') then
    -- 以前の行は検査せず、これから追加する行だけ楽曲IDを必須にする
    alter table public.boost_links add constraint boost_links_track_required check (track_id is not null) not valid;
  end if;
  create index if not exists boost_links_track_idx on public.boost_links(track_id);

  -- ===================================================================
  -- 2. クリック記録（boost_clicks）
  --    個人情報は保存しません（IPアドレス・端末情報は保存しない）。
  --    kind：link=計測リンク（/go/…）が開かれた／listen=宣伝ページの「AIMUSEで聴く」が押された
  -- ===================================================================
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

  -- ===================================================================
  -- 2-2. 記録回数のカウンター（boost_rate_counters）※いたずら・大量アクセス対策
  --    「範囲 × 時間枠（1分／1日）」ごとに1行で回数を数える。主キーで1行を読むだけなので軽い。
  --    誰も直接は読み書きできない（記録関数の中だけで使う）
  -- ===================================================================
  create table if not exists public.boost_rate_counters (
    scope text not null check (char_length(scope) <= 64),
    bucket timestamptz not null,
    n integer not null default 0 check (n >= 0),
    primary key (scope, bucket)
  );
  create index if not exists boost_rate_counters_bucket_idx on public.boost_rate_counters(bucket);

  -- ===================================================================
  -- 3. 投稿（boost_posts）
  --    status：draft=下書き / scheduled=予定 / posted=投稿済み / skipped=見送り
  --    post_mode：manual=手動投稿（現在はすべて手動）/ auto=公式API自動投稿（将来）
  -- ===================================================================
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
    external_post_id text,
    idempotency_key uuid not null default gen_random_uuid() unique,
    created_by uuid default auth.uid(),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
  );
  create index if not exists boost_posts_scheduled_idx on public.boost_posts(scheduled_at);
  create index if not exists boost_posts_status_idx on public.boost_posts(status);
  create unique index if not exists boost_posts_external_key
    on public.boost_posts(platform, external_post_id) where external_post_id is not null;

  -- ===================================================================
  -- 4. 自動投稿の試行記録（boost_post_attempts）※将来の公式API連携用
  -- ===================================================================
  create table if not exists public.boost_post_attempts (
    id bigint generated always as identity primary key,
    post_id uuid not null references public.boost_posts(id) on delete cascade,
    attempt integer not null check (attempt between 1 and 10),
    result text not null check (result in ('success', 'failed', 'skipped_duplicate')),
    error_message text check (error_message is null or char_length(error_message) <= 2000),
    attempted_at timestamptz not null default now(),
    unique (post_id, attempt)
  );

  -- ===================================================================
  -- 5. SNS接続状況（boost_sns_accounts）※認証情報は保存しない。初期状態はすべて「未接続」
  -- ===================================================================
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

  -- ===================================================================
  -- 6. 操作履歴・エラーログ（boost_logs）
  -- ===================================================================
  create table if not exists public.boost_logs (
    id bigint generated always as identity primary key,
    kind text not null check (kind in ('action', 'error')),
    action text not null check (char_length(action) <= 80),
    detail jsonb not null default '{}'::jsonb,
    actor uuid default auth.uid(),
    created_at timestamptz not null default now()
  );
  create index if not exists boost_logs_created_idx on public.boost_logs(created_at);

  -- ===================================================================
  -- 7. 設定・AI利用回数（料金の上限管理）
  -- ===================================================================
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

  -- ===================================================================
  -- 8. 投稿の自動処理（トリガー）
  -- ===================================================================
  create or replace function public.boost_posts_touch()
  returns trigger language plpgsql set search_path = '' as $fn$
  begin
    new.updated_at := now();
    if tg_op = 'INSERT' then
      new.created_by := auth.uid();       -- 作成者は保存した本人（送られてきた値は使わない）
      new.created_at := now();
    else
      new.created_by := old.created_by;   -- 作成者・作成日時は変更不可
      new.created_at := old.created_at;
    end if;
    -- 宣伝の対象は公開中の楽曲だけ（新しく作るとき・楽曲を付け替えるときに確認。
    -- 作成後に非公開になった曲の投稿も、編集・削除はできる）
    if new.track_id is not null
       and (tg_op = 'INSERT' or new.track_id is distinct from old.track_id)
       and not exists (select 1 from public.tracks t where t.id = new.track_id and t.status = 'public') then
      raise exception '公開中の楽曲だけ宣伝投稿を作成できます';
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
  end $fn$;

  drop trigger if exists boost_posts_touch on public.boost_posts;
  create trigger boost_posts_touch before insert or update on public.boost_posts
    for each row execute function public.boost_posts_touch();

  -- 宣伝リンクの作成：公開中の楽曲だけ。曲名・アーティスト名・作成者・作成日時はアプリから送られた値ではなく、
  -- AIMUSEの楽曲データとログイン情報から自動で入れる（表示と実際の曲がずれない・他人になりすませない）
  -- ※ 作成者（管理者）の権限で動く。管理者は AIMUSE の全楽曲を読めるため、特別な権限は不要
  create or replace function public.boost_links_guard()
  returns trigger language plpgsql set search_path = '' as $fn$
  declare v_title text; v_artist text;
  begin
    select t.title, t.artist into v_title, v_artist
    from public.tracks t where t.id = new.track_id and t.status = 'public';
    if not found then
      raise exception '公開中の楽曲だけ宣伝リンクを作成できます';
    end if;
    new.track_title := left(v_title, 200);
    new.artist := left(v_artist, 200);
    new.created_by := auth.uid();         -- 作成者は作成した本人（送られてきた値は使わない）
    new.created_at := now();
    return new;
  end $fn$;

  drop trigger if exists boost_links_guard on public.boost_links;
  create trigger boost_links_guard before insert on public.boost_links
    for each row execute function public.boost_links_guard();

  -- ===================================================================
  -- 9. アクセス権
  --    ・未ログイン（anon）：BOOSTのテーブルには一切アクセス不可
  --    ・ログイン会員（authenticated）：権限はあるが、RLSで管理者以外は0件・書き込み不可
  --    ・回数カウンター：誰も直接アクセス不可
  -- ===================================================================
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

  -- RLS を有効化（FORCE は付けない：記録用の関数は所有者として書き込むため）
  foreach v_tbl in array array['boost_links','boost_clicks','boost_posts','boost_post_attempts','boost_sns_accounts',
                               'boost_logs','boost_settings','boost_ai_usage','boost_rate_counters'] loop
    execute format('alter table public.%I enable row level security', v_tbl);
    execute format('alter table public.%I no force row level security', v_tbl);
  end loop;

  -- BOOSTテーブルのポリシーをすべて作り直す（以前の版や手作業で追加された緩いポリシーを残さない）
  for v_rec in select tablename, policyname from pg_policies
               where schemaname = 'public' and tablename like 'boost\_%' loop
    execute format('drop policy %I on public.%I', v_rec.policyname, v_rec.tablename);
  end loop;
  foreach v_tbl in array array['boost_links','boost_clicks','boost_posts','boost_post_attempts',
                               'boost_sns_accounts','boost_settings','boost_ai_usage'] loop
    execute format('create policy %I on public.%I as permissive for all to authenticated using (public.is_admin()) with check (public.is_admin())',
                   v_tbl || '_admin', v_tbl);
  end loop;
  -- 操作ログは本人名義でのみ追加可（なりすまし防止）
  create policy boost_logs_admin on public.boost_logs as permissive for all to authenticated
    using (public.is_admin()) with check (public.is_admin() and actor = auth.uid());
  -- boost_rate_counters：ポリシーなし（＝ログイン会員・未ログインとも読み書き不可）

  -- ===================================================================
  -- 10. クリックの記録（上限チェックと記録を「全部成功するか、全部取り消すか」で行う）
  --     ・3つのカウンター（全体1日2万回 → 全体1分300回 → 対象ごと1分60回）を順に「上限未満なら+1」し、
  --       最後にクリックを1件記録する。途中で上限に達したら、増やしたカウンターも含めて取り消す
  --     ・どの記録も必ず「全体1日」の行から順に確保するため、同時アクセスでも
  --       互いに待ち合って止まる（デッドロック）ことがなく、上限も超えない
  --     ・記録するのは「AIMUSEで現在公開中の楽曲」のクリックだけ（リンク・「聴く」共通の条件。
  --       非公開・削除された曲はカウンターも増やさず、何も記録しない）
  --     ・外部からは呼べない（下の2つの公開関数の中だけで使う）
  -- ===================================================================
  create or replace function public.boost_record_click(
    p_scope text, p_link uuid, p_track uuid, p_platform text, p_kind text)
  returns boolean
  language plpgsql security definer set search_path = ''
  as $fn$
  declare
    m timestamptz := date_trunc('minute', now());
    d timestamptz := date_trunc('day', now() at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
    v integer;
    minute_total integer;
  begin
    -- 宣伝の対象は公開中の楽曲だけ（boost_resolve_link・boost_record_listen 共通の条件）
    if p_track is null or not exists (select 1 from public.tracks t where t.id = p_track and t.status = 'public') then
      return false;
    end if;
    begin
      -- 全体：1日（日本時間）2万回
      insert into public.boost_rate_counters as c (scope, bucket, n) values ('all:day', d, 1)
      on conflict (scope, bucket) do update set n = c.n + 1 where c.n < 20000
      returning c.n into v;
      if v is null then raise exception using errcode = 'BST01', message = 'boost_limit'; end if;

      -- 全体：1分300回
      insert into public.boost_rate_counters as c (scope, bucket, n) values ('all:minute', m, 1)
      on conflict (scope, bucket) do update set n = c.n + 1 where c.n < 300
      returning c.n into minute_total;
      if minute_total is null then raise exception using errcode = 'BST01', message = 'boost_limit'; end if;

      -- 対象ごと（リンク／曲）：1分60回
      v := null;
      insert into public.boost_rate_counters as c (scope, bucket, n) values (p_scope, m, 1)
      on conflict (scope, bucket) do update set n = c.n + 1 where c.n < 60
      returning c.n into v;
      if v is null then raise exception using errcode = 'BST01', message = 'boost_limit'; end if;

      insert into public.boost_clicks (link_id, track_id, platform, kind) values (p_link, p_track, p_platform, p_kind);
    exception when sqlstate 'BST01' then
      return false;   -- 上限到達：このブロックの変更はすべて取り消し済み
    end;
    -- 古いカウンターの片付けはここでは行わない（クリック処理を常に軽く保つため。13-2. の関数で別に行う）
    return true;
  end $fn$;

  -- ===================================================================
  -- 11. 短縮リンクのクリック記録（/go/<code> から呼ばれる。ログイン不要）
  --     返すのは BOOST の宣伝ページのパス（/s/<楽曲ID>?src=<SNS>）だけ。外部URLは返さない
  --     リンク先の曲が非公開・削除済みなら記録しない（宣伝ページは「公開されていません」と表示し、
  --     AIMUSE のトップへ案内する。曲名などの情報は表示しない）
  -- ===================================================================
  create or replace function public.boost_resolve_link(p_code text, p_record boolean default true)
  returns text
  language plpgsql security definer set search_path = ''
  as $fn$
  declare l_id uuid; l_track uuid; l_platform text;
  begin
    if p_code is null or p_code !~ '^[A-Za-z0-9]{6,12}$' then return null; end if;
    select id, track_id, platform into l_id, l_track, l_platform from public.boost_links where code = p_code;
    if l_id is null or l_track is null then return null; end if;
    if p_record is true then
      perform public.boost_record_click('link:' || l_id::text, l_id, l_track, l_platform, 'link');
    end if;
    return '/s/' || l_track::text || case when l_platform in ('x', 'instagram', 'tiktok', 'youtube') then '?src=' || l_platform else '' end;
  end $fn$;

  -- ===================================================================
  -- 12. 宣伝ページの「AIMUSEで聴く」の記録（/out/<楽曲ID> から呼ばれる。ログイン不要）
  --     AIMUSEで公開中の曲だけ記録する（AIMUSEの楽曲は読むだけ）
  -- ===================================================================
  create or replace function public.boost_record_listen(p_track uuid, p_platform text)
  returns boolean
  language plpgsql security definer set search_path = ''
  as $fn$
  declare plat text := case when p_platform in ('x', 'instagram', 'tiktok', 'youtube') then p_platform else 'other' end;
  begin
    if p_track is null then return false; end if;
    -- 公開中かどうかは boost_record_click の中で、リンクのクリックと同じ条件で判定する
    return public.boost_record_click('listen:' || p_track::text, null, p_track, plat, 'listen');
  end $fn$;

  -- ===================================================================
  -- 13. AI生成の利用回数チェック（サーバー処理から管理者のログイン情報で呼ばれる）
  --     1日の上限（初期30回）を超えると allowed=false。管理者以外はエラー。
  -- ===================================================================
  create or replace function public.boost_ai_take_quota()
  returns json
  language plpgsql security definer set search_path = ''
  as $fn$
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
  end $fn$;

  -- ===================================================================
  -- 13-2. 古いカウンターの片付け（クリック処理とは別。管理者のみ）
  --     ・2日より前の行だけを、古い順に最大 p_limit 件（初期5000件・上限20000件）ずつ削除する
  --     ・削除するのは過去の行だけなので、いま記録中の行（今日・この1分）とぶつからない。
  --       他の処理が使用中の行は飛ばす（待たない）
  --     ・BOOSTアプリを管理者が開いたときに自動で呼ばれる。カウンターの行は記録の上限により
  --       1日あたり最大約2.2万行なので、しばらく開かなくても大きくはならない
  -- ===================================================================
  create or replace function public.boost_cleanup_counters(p_limit integer default 5000)
  returns integer
  language plpgsql security definer set search_path = ''
  as $fn$
  declare v_count integer;
  begin
    if not public.is_admin() then raise exception '管理者のみ利用できます'; end if;
    with old as (
      select c.ctid from public.boost_rate_counters c
      where c.bucket < now() - interval '2 days'
      order by c.bucket
      limit greatest(1, least(coalesce(p_limit, 5000), 20000))
      for update skip locked
    )
    delete from public.boost_rate_counters r using old where r.ctid = old.ctid;
    get diagnostics v_count = row_count;
    return v_count;
  end $fn$;

  -- ===================================================================
  -- 14. 以前の版（r3・r4）の内部関数の扱い
  --     ・本番に存在しなければ何もしない（初めて実行する場合はこちら）
  --     ・存在する場合は削除せず、「何もしない（常に false）」関数に置き換えて誰も実行できなくする
  --       理由：更新の瞬間に旧版の処理が実行中だと、削除した関数を呼んでエラーになるため
  --       （置き換えなら、実行中の旧処理は「記録しない」で正常に終わる）
  --     ・公開中のアプリ・サーバー処理はこれらを呼んでいない（呼ぶのは 11〜13 の3つだけ）
  -- ===================================================================
  if to_regprocedure('public.boost_click_allowed()') is not null then
    create or replace function public.boost_click_allowed() returns boolean
      language sql stable set search_path = '' as $fn$ select false $fn$;
    revoke all on function public.boost_click_allowed() from public, anon, authenticated, service_role;
  end if;
  if to_regprocedure('public.boost_click_gate(text)') is not null then
    create or replace function public.boost_click_gate(p_scope text) returns boolean
      language sql set search_path = '' as $fn$ select false $fn$;
    revoke all on function public.boost_click_gate(text) from public, anon, authenticated, service_role;
  end if;
  if to_regprocedure('public.boost_take_slot(text, timestamptz, integer)') is not null then
    create or replace function public.boost_take_slot(p_scope text, p_bucket timestamptz, p_limit integer) returns boolean
      language sql set search_path = '' as $fn$ select false $fn$;
    revoke all on function public.boost_take_slot(text, timestamptz, integer) from public, anon, authenticated, service_role;
  end if;

  -- ===================================================================
  -- 15. 関数の実行権限
  --     ・Supabase は新しい関数を自動で誰でも実行可能にするため、まず全員から外す
  --     ・未ログインで呼べるのは「クリック記録」の2つだけ
  -- ===================================================================
  revoke all on function public.boost_posts_touch() from public, anon, authenticated;
  revoke all on function public.boost_links_guard() from public, anon, authenticated;
  revoke all on function public.boost_record_click(text, uuid, uuid, text, text) from public, anon, authenticated;
  revoke all on function public.boost_resolve_link(text, boolean) from public, anon, authenticated;
  revoke all on function public.boost_record_listen(uuid, text) from public, anon, authenticated;
  revoke all on function public.boost_ai_take_quota() from public, anon, authenticated;
  revoke all on function public.boost_cleanup_counters(integer) from public, anon, authenticated;
  grant execute on function public.boost_cleanup_counters(integer) to authenticated;
  grant execute on function public.boost_resolve_link(text, boolean) to anon, authenticated;
  grant execute on function public.boost_record_listen(uuid, text) to anon, authenticated;
  grant execute on function public.boost_ai_take_quota() to authenticated;

  -- ===================================================================
  -- 16. 必須の確認（変更と同じ取引の中で実行）
  --     下の「最終確認」と同じ内容をここで検査し、NG が1件でもあれば例外を出して
  --     このブロックの変更をすべて取り消す（NGのまま変更が残ることはない）
  -- ===================================================================
  -- [CHECK-BEGIN]
  with
  tbl(name) as (values ('boost_ai_usage'), ('boost_clicks'), ('boost_links'), ('boost_logs'), ('boost_post_attempts'),
                       ('boost_posts'), ('boost_rate_counters'), ('boost_settings'), ('boost_sns_accounts')),
  fn(sig, anon_ok, auth_ok) as (values
    ('public.boost_resolve_link(text,boolean)',                true,  true),
    ('public.boost_record_listen(uuid,text)',                  true,  true),
    ('public.boost_ai_take_quota()',                           false, true),
    ('public.boost_record_click(text,uuid,uuid,text,text)',    false, false),
    ('public.boost_posts_touch()',                             false, false),
    ('public.boost_links_guard()',                             false, false),
    ('public.boost_cleanup_counters(integer)',                false, true)),
  checks as (
    select 1 as ord, 'RLS（有効/強制）' as 区分, t.name as 対象,
           coalesce((select c.relrowsecurity::text || '/' || c.relforcerowsecurity::text from pg_class c
                     where c.oid = to_regclass('public.' || t.name)), 'テーブルなし') as 状態,
           'true/false' as 期待
    from tbl t
    union all
    select 2, '未ログインの権限', t.name,
           case when to_regclass('public.' || t.name) is null then 'テーブルなし'
                when has_table_privilege('anon', to_regclass('public.' || t.name), 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
                  or has_any_column_privilege('anon', to_regclass('public.' || t.name), 'SELECT,INSERT,UPDATE,REFERENCES') then 'あり'
                else 'なし' end,
           'なし'
    from tbl t
    union all
    -- ポリシーの中身：名前:操作:許可型:ロール:USING=条件:CHECK=条件（スキーマ名・空白は除いて比較）
    select 3, 'ポリシーの中身', t.name,
           coalesce((select string_agg(p.policyname || ':' || p.cmd || ':' || p.permissive || ':' || array_to_string(p.roles, ',')
                                       || ':USING=' || coalesce(regexp_replace(p.qual, '\s+|public\.|auth\.', '', 'g'), '-')
                                       || ':CHECK=' || coalesce(regexp_replace(p.with_check, '\s+|public\.|auth\.', '', 'g'), '-'),
                                       ' | ' order by p.policyname)
                     from pg_policies p where p.schemaname = 'public' and p.tablename = t.name), 'なし'),
           case t.name
             when 'boost_rate_counters' then 'なし'
             when 'boost_logs' then 'boost_logs_admin:ALL:PERMISSIVE:authenticated:USING=is_admin():CHECK=(is_admin()AND(actor=uid()))'
             else t.name || '_admin:ALL:PERMISSIVE:authenticated:USING=is_admin():CHECK=is_admin()' end
    from tbl t
    union all
    select 4, '関数：未ログイン実行', f.sig,
           case when to_regprocedure(f.sig) is null then '関数なし'
                when has_function_privilege('anon', to_regprocedure(f.sig), 'EXECUTE') then '可' else '不可' end,
           case when f.anon_ok then '可' else '不可' end
    from fn f
    union all
    select 5, '関数：ログイン会員実行', f.sig,
           case when to_regprocedure(f.sig) is null then '関数なし'
                when has_function_privilege('authenticated', to_regprocedure(f.sig), 'EXECUTE') then '可' else '不可' end,
           case when f.auth_ok then '可' else '不可' end
    from fn f
    union all
    select 6, '関数：PUBLICへの付与', f.sig,
           case when to_regprocedure(f.sig) is null then '関数なし'
                when exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                             where p.oid = to_regprocedure(f.sig) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then 'あり'
                else 'なし' end,
           'なし'
    from fn f
    union all
    select 7, 'DEFINER関数の search_path', p.proname,
           coalesce((select c from unnest(p.proconfig) c where c like 'search_path=%'), '未設定'),
           'search_path=""'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'boost\_%' and p.prosecdef
    union all
    -- 記録用の関数（所有者の権限で動く）がBOOSTテーブルの所有者と同じであること
    select 8, '関数の所有者=テーブルの所有者', f.sig,
           case when to_regprocedure(f.sig) is null then '関数なし'
                when (select p.proowner from pg_proc p where p.oid = to_regprocedure(f.sig))
                   = (select c.relowner from pg_class c where c.oid = 'public.boost_clicks'::regclass) then '同じ' else '異なる' end,
           '同じ'
    from fn f
    union all
    -- 旧版（r3・r4）の関数が残っている場合：無効化済み（常に false・特権なし・誰も実行不可）であること
    select 9, '旧版の関数（無効化済みか）', p.oid::regprocedure::text,
           case when not p.prosecdef and regexp_replace(p.prosrc, '\s', '', 'g') = 'selectfalse'
                     and not has_function_privilege('anon', p.oid, 'EXECUTE')
                     and not has_function_privilege('authenticated', p.oid, 'EXECUTE') then '無効化済み' else '有効' end,
           '無効化済み'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('boost_click_allowed', 'boost_click_gate', 'boost_take_slot')
    union all
    select 10, '想定外のBOOST関数', p.oid::regprocedure::text, 'あり', 'なし'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'boost\_%'
      and p.proname not in ('boost_click_allowed', 'boost_click_gate', 'boost_take_slot')
      and p.oid not in (select to_regprocedure(sig) from fn where to_regprocedure(sig) is not null)
    union all
    -- トリガーが正しいテーブルで有効になっていること（公開曲のみ・作成者の自動設定を担う）
    select 11, 'トリガーが有効', tg.name,
           case when exists (select 1 from pg_trigger g where g.tgname = tg.name and g.tgrelid = to_regclass(tg.rel)
                               and g.tgfoid = to_regproc(tg.func) and g.tgenabled = 'O' and not g.tgisinternal) then '有効' else '無効または無し' end,
           '有効'
    from (values ('boost_links_guard', 'public.boost_links', 'public.boost_links_guard'),
                 ('boost_posts_touch', 'public.boost_posts', 'public.boost_posts_touch')) tg(name, rel, func)
    union all
    -- AIMUSE本体の保護（読み取りのみ。BOOSTの管理者判定がこれに依存する）
    select 12, 'AIMUSE：is_admin() の定義', 'public.is_admin()',
           case when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) = '065dbcd2c17f6a4da4ba7cc6b24dad9e'
                             and p.prosecdef and 'search_path=""' = any(p.proconfig)
                      from pg_proc p where p.oid = to_regprocedure('public.is_admin()')) then '構築SQLと一致' else '不一致' end,
           '構築SQLと一致'
    union all
    select 12, 'AIMUSE：is_admin の変更権限', r.role,
           case when has_column_privilege(r.role, 'public.profiles', 'is_admin', 'UPDATE')
                  or has_column_privilege(r.role, 'public.profiles', 'is_admin', 'INSERT') then 'あり' else 'なし' end,
           'なし'
    from (values ('anon'), ('authenticated'), ('public')) r(role)
    union all
    select 12, 'AIMUSE：管理者フラグ保護トリガー', 'profiles_protect_flags',
           case when exists (select 1 from pg_trigger g where g.tgrelid = 'public.profiles'::regclass and not g.tgisinternal
                               and g.tgfoid = to_regproc('public.protect_profile_flags') and g.tgenabled <> 'D'
                               and (g.tgtype & 19) = 19) then '有効' else '無効または無し' end,
           '有効'
    union all
    select 12, 'AIMUSE：管理者の人数', 'profiles.is_admin = true',
           case when (select count(*) from public.profiles where is_admin) >= 1 then '1人以上' else '0人' end,
           '1人以上'
  ),
  judged as (
    select ord, 区分, 対象, 状態, 期待, case when 状態 = 期待 then 'OK' else 'NG' end as 判定 from checks
  )
  -- [CHECK-END]
  select count(*) filter (where 判定 = 'NG'), count(*),
         string_agg(区分 || '［' || 対象 || '］' || 状態 || '（期待：' || 期待 || '）', ' ／ ') filter (where 判定 = 'NG')
    into v_ng, v_total, v_detail
  from judged;
  if v_ng > 0 then
    raise exception 'BOOSTの必須確認でNGが % 件あったため、すべての変更を取り消しました（データベースは実行前のままです）：%', v_ng, v_detail;
  end if;

  raise notice 'AIMUSE BOOST r9：設定が完了し、必須確認 % 項目すべて OK でした。', v_total;
end
$boost$;


-- =====================================================================
-- 最終確認の一覧表示（読み取りのみ）
--   上のブロックの最後で同じ確認を済ませ、NGなら全体を取り消しているため、
--   ここまで進んだ場合は「総合判定 OK」になります（念のための目視用）
--   ・9テーブルの RLS が有効か（FORCE なし）
--   ・未ログイン（anon）がBOOSTテーブルに一切の権限を持たないか
--   ・ポリシーの中身（操作種別・許可型・対象ロール・USING条件・WITH CHECK条件）が想定どおりか
--   ・関数ごとに、未ログイン・ログイン会員・全員（PUBLIC）が実行できるかが想定どおりか
--   ・SECURITY DEFINER 関数の search_path が固定されているか
--   ・関数とテーブルの所有者が同じか／旧版の関数が残っていれば無効化済みか／想定外のBOOST関数がないか
--   ・BOOSTのトリガーが有効か／AIMUSE本体の管理者判定と管理者フラグの保護が想定どおりか
-- =====================================================================
-- [CHECK-BEGIN]
with
tbl(name) as (values ('boost_ai_usage'), ('boost_clicks'), ('boost_links'), ('boost_logs'), ('boost_post_attempts'),
                     ('boost_posts'), ('boost_rate_counters'), ('boost_settings'), ('boost_sns_accounts')),
fn(sig, anon_ok, auth_ok) as (values
  ('public.boost_resolve_link(text,boolean)',                true,  true),
  ('public.boost_record_listen(uuid,text)',                  true,  true),
  ('public.boost_ai_take_quota()',                           false, true),
  ('public.boost_record_click(text,uuid,uuid,text,text)',    false, false),
  ('public.boost_posts_touch()',                             false, false),
  ('public.boost_links_guard()',                             false, false),
  ('public.boost_cleanup_counters(integer)',                false, true)),
checks as (
  select 1 as ord, 'RLS（有効/強制）' as 区分, t.name as 対象,
         coalesce((select c.relrowsecurity::text || '/' || c.relforcerowsecurity::text from pg_class c
                   where c.oid = to_regclass('public.' || t.name)), 'テーブルなし') as 状態,
         'true/false' as 期待
  from tbl t
  union all
  select 2, '未ログインの権限', t.name,
         case when to_regclass('public.' || t.name) is null then 'テーブルなし'
              when has_table_privilege('anon', to_regclass('public.' || t.name), 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
                or has_any_column_privilege('anon', to_regclass('public.' || t.name), 'SELECT,INSERT,UPDATE,REFERENCES') then 'あり'
              else 'なし' end,
         'なし'
  from tbl t
  union all
  -- ポリシーの中身：名前:操作:許可型:ロール:USING=条件:CHECK=条件（スキーマ名・空白は除いて比較）
  select 3, 'ポリシーの中身', t.name,
         coalesce((select string_agg(p.policyname || ':' || p.cmd || ':' || p.permissive || ':' || array_to_string(p.roles, ',')
                                     || ':USING=' || coalesce(regexp_replace(p.qual, '\s+|public\.|auth\.', '', 'g'), '-')
                                     || ':CHECK=' || coalesce(regexp_replace(p.with_check, '\s+|public\.|auth\.', '', 'g'), '-'),
                                     ' | ' order by p.policyname)
                   from pg_policies p where p.schemaname = 'public' and p.tablename = t.name), 'なし'),
         case t.name
           when 'boost_rate_counters' then 'なし'
           when 'boost_logs' then 'boost_logs_admin:ALL:PERMISSIVE:authenticated:USING=is_admin():CHECK=(is_admin()AND(actor=uid()))'
           else t.name || '_admin:ALL:PERMISSIVE:authenticated:USING=is_admin():CHECK=is_admin()' end
  from tbl t
  union all
  select 4, '関数：未ログイン実行', f.sig,
         case when to_regprocedure(f.sig) is null then '関数なし'
              when has_function_privilege('anon', to_regprocedure(f.sig), 'EXECUTE') then '可' else '不可' end,
         case when f.anon_ok then '可' else '不可' end
  from fn f
  union all
  select 5, '関数：ログイン会員実行', f.sig,
         case when to_regprocedure(f.sig) is null then '関数なし'
              when has_function_privilege('authenticated', to_regprocedure(f.sig), 'EXECUTE') then '可' else '不可' end,
         case when f.auth_ok then '可' else '不可' end
  from fn f
  union all
  select 6, '関数：PUBLICへの付与', f.sig,
         case when to_regprocedure(f.sig) is null then '関数なし'
              when exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                           where p.oid = to_regprocedure(f.sig) and a.grantee = 0 and a.privilege_type = 'EXECUTE') then 'あり'
              else 'なし' end,
         'なし'
  from fn f
  union all
  select 7, 'DEFINER関数の search_path', p.proname,
         coalesce((select c from unnest(p.proconfig) c where c like 'search_path=%'), '未設定'),
         'search_path=""'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'boost\_%' and p.prosecdef
  union all
  -- 記録用の関数（所有者の権限で動く）がBOOSTテーブルの所有者と同じであること
  select 8, '関数の所有者=テーブルの所有者', f.sig,
         case when to_regprocedure(f.sig) is null then '関数なし'
              when (select p.proowner from pg_proc p where p.oid = to_regprocedure(f.sig))
                 = (select c.relowner from pg_class c where c.oid = 'public.boost_clicks'::regclass) then '同じ' else '異なる' end,
         '同じ'
  from fn f
  union all
  -- 旧版（r3・r4）の関数が残っている場合：無効化済み（常に false・特権なし・誰も実行不可）であること
  select 9, '旧版の関数（無効化済みか）', p.oid::regprocedure::text,
         case when not p.prosecdef and regexp_replace(p.prosrc, '\s', '', 'g') = 'selectfalse'
                   and not has_function_privilege('anon', p.oid, 'EXECUTE')
                   and not has_function_privilege('authenticated', p.oid, 'EXECUTE') then '無効化済み' else '有効' end,
         '無効化済み'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('boost_click_allowed', 'boost_click_gate', 'boost_take_slot')
  union all
  select 10, '想定外のBOOST関数', p.oid::regprocedure::text, 'あり', 'なし'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'boost\_%'
    and p.proname not in ('boost_click_allowed', 'boost_click_gate', 'boost_take_slot')
    and p.oid not in (select to_regprocedure(sig) from fn where to_regprocedure(sig) is not null)
  union all
  -- トリガーが正しいテーブルで有効になっていること（公開曲のみ・作成者の自動設定を担う）
  select 11, 'トリガーが有効', tg.name,
         case when exists (select 1 from pg_trigger g where g.tgname = tg.name and g.tgrelid = to_regclass(tg.rel)
                             and g.tgfoid = to_regproc(tg.func) and g.tgenabled = 'O' and not g.tgisinternal) then '有効' else '無効または無し' end,
         '有効'
  from (values ('boost_links_guard', 'public.boost_links', 'public.boost_links_guard'),
               ('boost_posts_touch', 'public.boost_posts', 'public.boost_posts_touch')) tg(name, rel, func)
  union all
  -- AIMUSE本体の保護（読み取りのみ。BOOSTの管理者判定がこれに依存する）
  select 12, 'AIMUSE：is_admin() の定義', 'public.is_admin()',
         case when (select md5(btrim(regexp_replace(p.prosrc, '\s+', ' ', 'g'))) = '065dbcd2c17f6a4da4ba7cc6b24dad9e'
                           and p.prosecdef and 'search_path=""' = any(p.proconfig)
                    from pg_proc p where p.oid = to_regprocedure('public.is_admin()')) then '構築SQLと一致' else '不一致' end,
         '構築SQLと一致'
  union all
  select 12, 'AIMUSE：is_admin の変更権限', r.role,
         case when has_column_privilege(r.role, 'public.profiles', 'is_admin', 'UPDATE')
                or has_column_privilege(r.role, 'public.profiles', 'is_admin', 'INSERT') then 'あり' else 'なし' end,
         'なし'
  from (values ('anon'), ('authenticated'), ('public')) r(role)
  union all
  select 12, 'AIMUSE：管理者フラグ保護トリガー', 'profiles_protect_flags',
         case when exists (select 1 from pg_trigger g where g.tgrelid = 'public.profiles'::regclass and not g.tgisinternal
                             and g.tgfoid = to_regproc('public.protect_profile_flags') and g.tgenabled <> 'D'
                             and (g.tgtype & 19) = 19) then '有効' else '無効または無し' end,
         '有効'
  union all
  select 12, 'AIMUSE：管理者の人数', 'profiles.is_admin = true',
         case when (select count(*) from public.profiles where is_admin) >= 1 then '1人以上' else '0人' end,
         '1人以上'
),
judged as (
  select ord, 区分, 対象, 状態, 期待, case when 状態 = 期待 then 'OK' else 'NG' end as 判定 from checks
)
-- [CHECK-END]

select 0 as ord, '総合判定' as 区分, '全' || count(*) || '項目' as 対象,
       'NG ' || count(*) filter (where 判定 = 'NG') || '件' as 状態, 'NG 0件' as 期待,
       case when count(*) filter (where 判定 = 'NG') = 0 then 'OK' else 'NG' end as 判定
from judged
union all
select * from judged
order by ord, 対象;
