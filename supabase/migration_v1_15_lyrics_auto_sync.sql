-- =====================================================================
-- AIMUSE v1.15 歌詞の自動同期（AI：Cloudflare Workers AI の Whisper）（追加と、保存の関数1つの更新）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・楽曲・歌詞・同期の時刻・会員のデータは変更しません
--   ・追加：非公開の場所（aimuse_private）の表4つ、楽曲の表のトリガー1つ、関数
--   ・更新：lyrics_sync_save（同じ使い方のまま。AI が作った同期を人が保存し直したら「mixed」にするだけ）
--   ・適用した直後は「停止中」です。管理画面で「再開」するまで、AI の解析は一切行いません
--   ・何度実行しても壊れません。全体を BEGIN〜COMMIT で囲んでいます（途中でエラーなら全体を取り消し）
--   ・前提：v1.14（歌詞の同期）が適用済みであること。満たさない場合は何もせずに中止します
--   ・AIMUSE BOOST の表・関数には触れません
--
-- 仕組み
--   ・公開中の曲（承認済み）で歌詞と長さがそろうと、楽曲の表のトリガーが「解析待ち」に登録する（登録だけ。通信しない）
--   ・定期実行（cron_lyrics_align.sql）が5分ごとに Edge Function「lyrics-align」を呼び、1曲ずつ解析する
--       lyrics_align_claim  … 1曲だけ取り出す（同時に1曲だけ・その日の上限の内側だけ・使う量を先に予約）
--       lyrics_align_finish … 結果を「提案」として保存（同期の時刻そのものは書き換えない）
--       lyrics_align_fail   … 失敗の記録（再試行は最大3回まで。無料枠切れは翌日まで全体を止める）
--   ・提案は、投稿者（または運営）が編集画面で聞いて確かめ、「保存」したときだけ同期の時刻になる
--     （手動で合わせた同期は、投稿者本人の操作なしに置き換えない）
--   ・1日の上限（初期値 6,000ニューロン。Cloudflare の無料枠 10,000 とは別の安全余裕）。日付は世界標準時
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.lyrics_sync_save(uuid, jsonb)') is null or to_regclass('public.track_lyrics_sync') is null then
    raise exception 'v1.14 が未適用です。何も変更せずに中止しました。';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 表（非公開の場所。アプリからは直接読めない。関数経由だけ）
-- ---------------------------------------------------------------------
create table if not exists aimuse_private.lyrics_align_jobs (
  track_id uuid primary key references public.tracks(id) on delete cascade,
  state text not null check (state in ('waiting', 'queued', 'running', 'review', 'applied', 'dismissed', 'failed', 'skipped')),
  reason text not null default '',
  lyrics_hash text,
  attempts int not null default 0,
  next_try_at timestamptz not null default now(),
  token uuid,
  lease_until timestamptz,
  est_neurons int not null default 0,
  proposal jsonb,
  meta jsonb,
  review jsonb,
  last_error text,
  rerun boolean not null default false,
  requested_by uuid,
  queued_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists lyrics_align_jobs_pick on aimuse_private.lyrics_align_jobs (state, next_try_at);

create table if not exists aimuse_private.lyrics_align_budget (
  day date primary key,                 -- 世界標準時の日付（Cloudflare の無料枠の区切りと同じ）
  reserved int not null default 0,      -- 予約したニューロン（見積もり×1.2。失敗しても戻さない＝安全側）
  runs int not null default 0,
  ok int not null default 0,
  failed int not null default 0
);

create table if not exists aimuse_private.lyrics_align_settings (
  id int primary key default 1 check (id = 1),
  paused boolean not null default true,
  pause_reason text not null default 'initial',
  daily_cap int not null default 6000 check (daily_cap between 0 and 8000),
  auto_apply boolean not null default false,       -- 初期は false：結果はすべて確認待ち
  blocked_until timestamptz,                       -- Cloudflare が「無料枠切れ」と返したら翌日まで止める
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into aimuse_private.lyrics_align_settings (id) values (1) on conflict (id) do nothing;

create table if not exists aimuse_private.lyrics_align_requests (
  id bigserial primary key,
  user_id uuid not null,
  track_id uuid not null,
  at timestamptz not null default now()
);
create index if not exists lyrics_align_requests_user on aimuse_private.lyrics_align_requests (user_id, at);
create index if not exists lyrics_align_requests_track on aimuse_private.lyrics_align_requests (track_id, at);

revoke all on aimuse_private.lyrics_align_jobs, aimuse_private.lyrics_align_budget,
  aimuse_private.lyrics_align_settings, aimuse_private.lyrics_align_requests from public, anon, authenticated, service_role;
revoke all on sequence aimuse_private.lyrics_align_requests_id_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 内部の関数（非公開の場所。アプリからは呼べない）
-- ---------------------------------------------------------------------
-- 時刻を付けられる行の数（空行・見出しを除く）
create or replace function aimuse_private.lyrics_text_count(p_lyrics text[])
returns int
language sql immutable set search_path = ''
as $$ select count(*)::int from unnest(coalesce(p_lyrics, '{}'::text[])) l where btrim(l) <> '' and not public.lyrics_is_heading(l) $$;

-- 解析できる曲か（できなければ理由を返す）
create or replace function aimuse_private.lyrics_align_ineligible(p_t public.tracks)
returns text
language sql stable set search_path = ''
as $$
  select case
    when p_t.status <> 'public' then 'not_public'
    when aimuse_private.lyrics_text_count(p_t.lyrics) = 0 then 'no_lyrics'
    when coalesce(p_t.duration, 0) <= 0 then 'no_duration'
    when p_t.duration > 600 then 'too_long'
    when coalesce(p_t.audio_size, 0) > 20971520 then 'too_large'
    else null end
$$;

-- 同期の時刻の検証と整形（v1.14 の lyrics_sync_save と同じ規則。人の保存も AI の結果も、同じ規則を通す）
create or replace function aimuse_private.lyrics_sync_check(p_t public.tracks, p_lines jsonb)
returns jsonb
language plpgsql stable set search_path = ''
as $$
declare
  v_limit numeric;
  v_item jsonb;
  v_i int; v_ts numeric; v_te numeric;
  v_prev_i int := -1; v_prev_t numeric := 0; v_prev_e numeric := null;
  v_out jsonb := '[]'::jsonb;
  v_line text;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'BAD_DATA: 形式が正しくありません'; end if;
  if jsonb_array_length(p_lines) > 1000 then raise exception 'BAD_DATA: 行が多すぎます'; end if;
  v_limit := case when p_t.duration > 0 then p_t.duration + 30 else 3600 end;
  for v_item in select x from jsonb_array_elements(p_lines) as x loop
    if jsonb_typeof(v_item) <> 'object'
       or exists (select 1 from jsonb_object_keys(v_item) k where k not in ('i', 't', 'e')) then
      raise exception 'BAD_DATA: 形式が正しくありません';
    end if;
    if coalesce(jsonb_typeof(v_item->'i'), '') <> 'number' or (v_item->>'i') !~ '^\d{1,4}$' then raise exception 'BAD_DATA: 行番号が正しくありません'; end if;
    v_i := (v_item->>'i')::int;
    if v_i >= coalesce(cardinality(p_t.lyrics), 0) then raise exception 'BAD_DATA: 行番号が歌詞の範囲外です'; end if;
    v_line := p_t.lyrics[v_i + 1];
    if v_line is null or btrim(v_line) = '' or public.lyrics_is_heading(v_line) then
      raise exception 'BAD_DATA: 空行・見出しには時刻を付けられません（%行目）', v_i + 1;
    end if;
    if v_i <= v_prev_i then raise exception 'BAD_DATA: 行の順番が正しくありません'; end if;
    if coalesce(jsonb_typeof(v_item->'t'), '') <> 'number' then raise exception 'BAD_DATA: 時刻が正しくありません'; end if;
    v_ts := round((v_item->>'t')::numeric, 2);
    if v_ts < 0 or v_ts > v_limit then raise exception 'BAD_DATA: 時刻が曲の長さの範囲外です（%行目）', v_i + 1; end if;
    if v_ts < v_prev_t or (v_prev_e is not null and v_ts < v_prev_e) then
      raise exception 'BAD_DATA: 時刻が前の行より前になっています（%行目）', v_i + 1;
    end if;
    v_te := null;
    if v_item ? 'e' and jsonb_typeof(v_item->'e') <> 'null' then
      if jsonb_typeof(v_item->'e') <> 'number' then raise exception 'BAD_DATA: 歌い終わりの時刻が正しくありません'; end if;
      v_te := round((v_item->>'e')::numeric, 2);
      if v_te <= v_ts or v_te > v_limit then raise exception 'BAD_DATA: 歌い終わりの時刻が正しくありません（%行目）', v_i + 1; end if;
    end if;
    v_out := v_out || jsonb_build_array(case when v_te is null then jsonb_build_object('i', v_i, 't', v_ts)
                                             else jsonb_build_object('i', v_i, 't', v_ts, 'e', v_te) end);
    v_prev_i := v_i; v_prev_t := v_ts; v_prev_e := v_te;
  end loop;
  return v_out;
end;
$$;

-- 数値を取り出す（範囲外・形式違いは既定値）
create or replace function aimuse_private.jnum(p jsonb, p_key text, p_lo numeric, p_hi numeric, p_def numeric)
returns numeric
language sql immutable set search_path = ''
as $$
  select case when jsonb_typeof(p->p_key) = 'number' and (p->>p_key)::numeric between p_lo and p_hi then (p->>p_key)::numeric else p_def end
$$;

-- 解析待ちに登録する（重複しない。手動の同期がある曲は、本人が頼んだとき以外は解析しない）
--   戻り値：queued / waiting / skipped / running / duplicate / not_public / not_found
create or replace function aimuse_private.lyrics_align_enqueue(p_track uuid, p_reason text, p_force boolean, p_by uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_t public.tracks;
  v_j aimuse_private.lyrics_align_jobs;
  v_has_job boolean;
  v_has_sync boolean;
  v_h text;
  v_bad text;
  v_state text;
  v_reason text;
begin
  select * into v_t from public.tracks t where t.id = p_track;
  if not found then return 'not_found'; end if;
  select * into v_j from aimuse_private.lyrics_align_jobs j where j.track_id = p_track for update;
  v_has_job := found;
  v_h := public.lyrics_hash(v_t.lyrics);
  if v_has_job and v_j.state = 'running' then
    update aimuse_private.lyrics_align_jobs set rerun = true, updated_at = now() where track_id = p_track;
    return 'running';
  end if;
  v_bad := aimuse_private.lyrics_align_ineligible(v_t);
  if v_bad = 'not_public' then
    if v_has_job and v_j.state in ('queued', 'waiting') then
      update aimuse_private.lyrics_align_jobs set state = 'skipped', reason = 'not_public', updated_at = now() where track_id = p_track;
    end if;
    return 'not_public';
  end if;
  if v_bad in ('no_lyrics', 'no_duration') then v_state := 'waiting'; v_reason := v_bad;
  elsif v_bad is not null then v_state := 'skipped'; v_reason := v_bad;
  else
    select exists (select 1 from public.track_lyrics_sync s where s.track_id = p_track and s.lyrics_hash = v_h) into v_has_sync;
    if v_has_sync and not p_force then v_state := 'skipped'; v_reason := 'has_sync';
    elsif v_has_job and not p_force and v_j.lyrics_hash = v_h and v_j.state in ('queued', 'review', 'applied', 'dismissed', 'failed') then
      return 'duplicate';
    else v_state := 'queued'; v_reason := left(coalesce(p_reason, ''), 40);
    end if;
  end if;
  if v_has_job and v_j.state = v_state and v_j.reason = v_reason and v_j.lyrics_hash = v_h and v_state <> 'queued' then
    return 'duplicate';
  end if;
  insert into aimuse_private.lyrics_align_jobs as j (track_id, state, reason, lyrics_hash, attempts, next_try_at, proposal, meta, review,
                                                       last_error, rerun, requested_by, queued_at, updated_at)
  values (p_track, v_state, v_reason, v_h, 0, now(), null, null, null, null, false, p_by, now(), now())
  on conflict (track_id) do update
    set state = excluded.state, reason = excluded.reason, lyrics_hash = excluded.lyrics_hash, attempts = 0, next_try_at = now(),
        proposal = case when excluded.state = 'queued' then null else j.proposal end,
        meta = case when excluded.state = 'queued' then null else j.meta end,
        last_error = null, rerun = false, token = null, lease_until = null,
        requested_by = excluded.requested_by, queued_at = now(), updated_at = now();
  return v_state;
end;
$$;

-- 楽曲の表のトリガー：承認・歌詞の変更・長さの登録で、解析待ちに登録（失敗しても投稿・承認は止めない）
create or replace function aimuse_private.lyrics_align_on_track()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  begin
    if new.status = 'public' then
      if tg_op = 'INSERT' then
        perform aimuse_private.lyrics_align_enqueue(new.id, 'approved', false, null);
      elsif old.status is distinct from new.status then
        perform aimuse_private.lyrics_align_enqueue(new.id, 'approved', false, null);
      elsif old.lyrics is distinct from new.lyrics then
        perform aimuse_private.lyrics_align_enqueue(new.id, 'lyrics_changed', false, null);
      elsif old.duration is distinct from new.duration then
        perform aimuse_private.lyrics_align_enqueue(new.id, 'duration', false, null);
      end if;
    elsif tg_op = 'UPDATE' and old.status = 'public' then
      perform aimuse_private.lyrics_align_enqueue(new.id, 'hidden', false, null);
    end if;
  exception when others then
    raise warning 'lyrics_align_on_track: %', sqlerrm;
  end;
  return null;
end;
$$;
create or replace trigger tracks_lyrics_align
  after insert or update of status, lyrics, duration on public.tracks
  for each row execute function aimuse_private.lyrics_align_on_track();

-- 呼び出した人がその曲に対してできること：owner（投稿者本人で書き込みできる会員）/ admin / null
create or replace function aimuse_private.lyrics_align_role(p_track uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case
    when auth.uid() is null then null
    when public.is_admin() then 'admin'
    when exists (select 1 from public.tracks t where t.id = p_track and t.user_id = auth.uid()) and public.is_active_member() then 'owner'
    else null end
$$;

-- 人が直した量（AI の提案との時刻の差）：比べた行・直した行・差の中央値と最大
create or replace function aimuse_private.lyrics_align_review_stats(p_proposal jsonb, p_saved jsonb)
returns jsonb
language sql immutable set search_path = ''
as $$
  with p as (select (x->>'i')::int i, (x->>'t')::numeric t from jsonb_array_elements(coalesce(p_proposal, '[]'::jsonb)) x),
       s as (select (x->>'i')::int i, (x->>'t')::numeric t from jsonb_array_elements(coalesce(p_saved, '[]'::jsonb)) x),
       d as (select abs(s.t - p.t) a from s join p using (i))
  select jsonb_build_object(
    'compared', (select count(*) from d),
    'changed', (select count(*) from d where a >= 0.05),
    'median_abs', (select round(coalesce(percentile_cont(0.5) within group (order by a), 0)::numeric, 2) from d),
    'p90_abs', (select round(coalesce(percentile_cont(0.9) within group (order by a), 0)::numeric, 2) from d),
    'max_abs', (select round(coalesce(max(a), 0), 2) from d),
    'within_05', (select count(*) from d where a <= 0.5),
    'added', (select count(*) from s where not exists (select 1 from p where p.i = s.i)),
    'removed', (select count(*) from p where not exists (select 1 from s where s.i = p.i)))
$$;

revoke all on function aimuse_private.lyrics_text_count(text[]), aimuse_private.lyrics_align_ineligible(public.tracks),
  aimuse_private.lyrics_sync_check(public.tracks, jsonb), aimuse_private.jnum(jsonb, text, numeric, numeric, numeric),
  aimuse_private.lyrics_align_enqueue(uuid, text, boolean, uuid), aimuse_private.lyrics_align_on_track(),
  aimuse_private.lyrics_align_role(uuid), aimuse_private.lyrics_align_review_stats(jsonb, jsonb)
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 同期の保存（v1.14 と同じ使い方。AI が作った同期を人が保存し直したら mixed にする＝以後 AI は置き換えない）
-- ---------------------------------------------------------------------
create or replace function public.lyrics_sync_save(p_track uuid, p_lines jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_t public.tracks;
  v_out jsonb;
  v_src text := 'manual';
  v_h text;
begin
  if not public.is_active_member() then
    raise exception 'NOT_ALLOWED: 同期を保存できるのは、ログイン中の会員だけです';
  end if;
  select * into v_t from public.tracks t where t.id = p_track for update;
  if not found then raise exception 'NOT_FOUND: 楽曲が見つかりません'; end if;
  if v_t.user_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'NOT_ALLOWED: 歌詞の同期を変更できるのは、投稿者本人と運営だけです';
  end if;
  v_out := aimuse_private.lyrics_sync_check(v_t, p_lines);
  v_h := public.lyrics_hash(v_t.lyrics);
  if exists (select 1 from public.track_lyrics_sync s where s.track_id = p_track and s.source in ('auto', 'mixed') and s.lyrics_hash = v_h) then
    v_src := 'mixed';
  end if;
  insert into public.track_lyrics_sync as s (track_id, lines, source, lyrics_hash, updated_by, updated_at)
  values (p_track, v_out, v_src, v_h, auth.uid(), now())
  on conflict (track_id) do update
    set lines = excluded.lines, source = excluded.source, lyrics_hash = excluded.lyrics_hash,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('count', jsonb_array_length(v_out), 'updated_at', now(), 'source', v_src);
end;
$$;
revoke all on function public.lyrics_sync_save(uuid, jsonb) from public, anon;
grant execute on function public.lyrics_sync_save(uuid, jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 解析する側（Edge Function「lyrics-align」だけ。service_role だけが実行できる）
-- ---------------------------------------------------------------------
create or replace function public.lyrics_align_secret_matches(p_secret text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v text;
begin
  if p_secret is null or char_length(p_secret) < 32 or to_regclass('vault.decrypted_secrets') is null then return false; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1' into v using 'aimuse_align_secret';
  return v is not null and char_length(v) >= 32 and v = p_secret;
end;
$$;

-- 1曲だけ取り出す（停止中・無料枠切れで止めている間・解析中の曲がある間・その日の上限を超える場合は取り出さない）
create or replace function public.lyrics_align_claim()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_st aimuse_private.lyrics_align_settings;
  v_j aimuse_private.lyrics_align_jobs;
  v_t public.tracks;
  v_b aimuse_private.lyrics_align_budget;
  v_day date := (now() at time zone 'utc')::date;
  v_bad text;
  v_h text;
  v_est int;
  v_tok uuid;
  v_n int := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended('aimuse_lyrics_align', 0));
  select * into v_st from aimuse_private.lyrics_align_settings where id = 1 for update;
  -- 解析中のまま止まったもの（10分以上）：試行1回として数え、30分後に再試行（3回目で打ち切り）
  update aimuse_private.lyrics_align_jobs
     set state = case when attempts + 1 >= 3 then 'failed' else 'queued' end,
         reason = case when attempts + 1 >= 3 then 'gave_up' else reason end,
         attempts = attempts + 1, last_error = 'STALLED', token = null, lease_until = null,
         next_try_at = now() + interval '30 minutes', updated_at = now()
   where state = 'running' and lease_until < now();
  if v_st.paused then return jsonb_build_object('status', 'paused', 'reason', v_st.pause_reason); end if;
  if v_st.blocked_until is not null and v_st.blocked_until > now() then
    return jsonb_build_object('status', 'blocked', 'until', v_st.blocked_until);
  end if;
  if exists (select 1 from aimuse_private.lyrics_align_jobs where state = 'running') then
    return jsonb_build_object('status', 'busy');
  end if;
  loop
    v_n := v_n + 1;
    if v_n > 20 then return jsonb_build_object('status', 'idle'); end if;
    select * into v_j from aimuse_private.lyrics_align_jobs j
     where j.state = 'queued' and j.next_try_at <= now()
     order by j.next_try_at, j.queued_at limit 1 for update skip locked;
    if not found then return jsonb_build_object('status', 'idle'); end if;
    select * into v_t from public.tracks t where t.id = v_j.track_id;
    v_bad := aimuse_private.lyrics_align_ineligible(v_t);
    if v_bad is not null then
      update aimuse_private.lyrics_align_jobs
         set state = case when v_bad in ('no_lyrics', 'no_duration') then 'waiting' else 'skipped' end, reason = v_bad, updated_at = now()
       where track_id = v_j.track_id;
      continue;
    end if;
    v_h := public.lyrics_hash(v_t.lyrics);
    -- 登録した後に手動の同期が保存された曲は、本人が頼んだとき以外は解析しない
    if v_j.requested_by is null and exists (select 1 from public.track_lyrics_sync s where s.track_id = v_t.id and s.lyrics_hash = v_h) then
      update aimuse_private.lyrics_align_jobs set state = 'skipped', reason = 'has_sync', lyrics_hash = v_h, updated_at = now() where track_id = v_t.id;
      continue;
    end if;
    v_est := ceil(v_t.duration / 60.0 * 46.63 * 1.2)::int;
    insert into aimuse_private.lyrics_align_budget (day) values (v_day) on conflict (day) do nothing;
    select * into v_b from aimuse_private.lyrics_align_budget where day = v_day for update;
    if v_b.reserved + v_est > v_st.daily_cap then
      return jsonb_build_object('status', 'daily_cap', 'reserved', v_b.reserved, 'cap', v_st.daily_cap);
    end if;
    update aimuse_private.lyrics_align_budget set reserved = reserved + v_est, runs = runs + 1 where day = v_day;
    v_tok := gen_random_uuid();
    update aimuse_private.lyrics_align_jobs
       set state = 'running', token = v_tok, lease_until = now() + interval '10 minutes', started_at = now(),
           est_neurons = v_est, lyrics_hash = v_h, rerun = false, updated_at = now()
     where track_id = v_t.id;
    return jsonb_build_object('status', 'claimed', 'track_id', v_t.id, 'token', v_tok, 'title', v_t.title,
      'lyrics', to_jsonb(v_t.lyrics), 'audio_path', v_t.audio_path, 'duration', v_t.duration,
      'audio_size', coalesce(v_t.audio_size, 0), 'est_neurons', v_est);
  end loop;
end;
$$;

-- 結果を保存（提案として。auto_apply が true で品質の確認に通り、手動の同期が無いときだけ同期の時刻にもする）
create or replace function public.lyrics_align_finish(p_track uuid, p_token uuid, p_lines jsonb, p_meta jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_j aimuse_private.lyrics_align_jobs;
  v_t public.tracks;
  v_st aimuse_private.lyrics_align_settings;
  v_day date := (now() at time zone 'utc')::date;
  v_h text;
  v_out jsonb;
  v_text int; v_matched int; v_ratio numeric; v_ok boolean;
  v_meta jsonb;
  v_state text := 'review';
  v_sync_src text;
begin
  -- 行を固定する順番は「楽曲 → 解析待ち」（トリガー・採用の関数と同じ順。行き詰まりを防ぐ）
  select * into v_t from public.tracks t where t.id = p_track for update;
  select * into v_j from aimuse_private.lyrics_align_jobs where track_id = p_track for update;
  if not found or v_j.state <> 'running' or v_j.token is distinct from p_token then
    return jsonb_build_object('status', 'stale');
  end if;
  v_h := public.lyrics_hash(v_t.lyrics);
  if v_h <> v_j.lyrics_hash or v_j.rerun then
    -- 解析中に歌詞が変わった：結果を捨てて、新しい歌詞で解析待ちへ（試行回数は増やさない）
    update aimuse_private.lyrics_align_jobs
       set state = 'queued', reason = 'lyrics_changed', lyrics_hash = v_h, token = null, lease_until = null,
           next_try_at = now(), rerun = false, proposal = null, meta = null, updated_at = now()
     where track_id = p_track;
    return jsonb_build_object('status', 'requeued');
  end if;
  begin
    v_out := aimuse_private.lyrics_sync_check(v_t, p_lines);
  exception when others then
    update aimuse_private.lyrics_align_jobs
       set state = 'failed', reason = 'bad_result', last_error = 'BAD_RESULT', token = null, lease_until = null,
           finished_at = now(), updated_at = now()
     where track_id = p_track;
    update aimuse_private.lyrics_align_budget set failed = failed + 1 where day = v_day;
    return jsonb_build_object('status', 'bad_result');
  end;
  v_text := aimuse_private.lyrics_text_count(v_t.lyrics);
  v_matched := least(aimuse_private.jnum(p_meta, 'matched_lines', 0, 100000, 0)::int, v_text);
  v_ratio := case when v_text > 0 then v_matched::numeric / v_text else 0 end;
  -- 品質：照合率 60%以上・時刻の検査（Edge Function 側）に通る・時刻のある行が 60%以上
  v_ok := coalesce((p_meta->>'quality_ok')::boolean, false) is true
          and v_ratio >= 0.6 and jsonb_array_length(v_out) >= ceil(v_text * 0.6);
  v_meta := jsonb_build_object(
    'lyrics_hash', v_h,
    'text_lines', v_text, 'matched_lines', v_matched, 'ratio', round(v_ratio, 3), 'quality_ok', v_ok,
    'reasons', coalesce((select jsonb_agg(r) from (select x #>> '{}' r from jsonb_array_elements(case when jsonb_typeof(p_meta->'reasons') = 'array' then p_meta->'reasons' else '[]'::jsonb end) x
                         where jsonb_typeof(x) = 'string' and (x #>> '{}') ~ '^[a-z_]{1,32}$' limit 10) q), '[]'::jsonb),
    'est', coalesce((select jsonb_agg((x #>> '{}')::int) from (select x from jsonb_array_elements(case when jsonb_typeof(p_meta->'est') = 'array' then p_meta->'est' else '[]'::jsonb end) x
                         where jsonb_typeof(x) = 'number' and (x #>> '{}') ~ '^\d{1,4}$' limit 1000) q), '[]'::jsonb),
    'max_est_run', aimuse_private.jnum(p_meta, 'max_est_run', 0, 1000, 0),
    'ai_ms', aimuse_private.jnum(p_meta, 'ai_ms', 0, 600000, 0),
    'words', aimuse_private.jnum(p_meta, 'words', 0, 100000, 0),
    'granularity', case when p_meta->>'granularity' in ('word', 'segment', 'none') then p_meta->>'granularity' else 'none' end,
    'vad_filter', coalesce((p_meta->>'vad_filter')::boolean, false),
    'analyzed_at', now());
  select * into v_st from aimuse_private.lyrics_align_settings where id = 1;
  select s.source into v_sync_src from public.track_lyrics_sync s where s.track_id = p_track;
  if v_st.auto_apply and v_ok and (v_sync_src is null or v_sync_src = 'auto') then
    insert into public.track_lyrics_sync as s (track_id, lines, source, lyrics_hash, updated_by, updated_at)
    values (p_track, v_out, 'auto', v_h, null, now())
    on conflict (track_id) do update
      set lines = excluded.lines, source = excluded.source, lyrics_hash = excluded.lyrics_hash, updated_by = null, updated_at = now()
      where s.source = 'auto';
    v_state := 'applied';
  end if;
  update aimuse_private.lyrics_align_jobs
     set state = v_state, reason = case when v_state = 'applied' then 'auto_applied' else case when v_ok then 'ready' else 'low_quality' end end,
         proposal = v_out, meta = v_meta, review = case when v_state = 'applied' then jsonb_build_object('auto', true) else review end,
         token = null, lease_until = null, last_error = null, finished_at = now(), updated_at = now()
   where track_id = p_track;
  update aimuse_private.lyrics_align_budget set ok = ok + 1 where day = v_day;
  return jsonb_build_object('status', v_state, 'count', jsonb_array_length(v_out), 'quality_ok', v_ok, 'ratio', round(v_ratio, 3));
end;
$$;

-- 失敗の記録（再試行は合計3回まで。無料枠切れ・トークン無効は全体を止める）
create or replace function public.lyrics_align_fail(p_track uuid, p_token uuid, p_code text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_j aimuse_private.lyrics_align_jobs;
  v_code text := case when p_code ~ '^[A-Z_]{1,40}$' then p_code else 'UNKNOWN' end;
  v_day date := (now() at time zone 'utc')::date;
  v_until timestamptz;
  v_a int;
  v_res text;
begin
  select * into v_j from aimuse_private.lyrics_align_jobs where track_id = p_track for update;
  if not found or v_j.state <> 'running' or v_j.token is distinct from p_token then
    return jsonb_build_object('status', 'stale');
  end if;
  update aimuse_private.lyrics_align_budget set failed = failed + 1 where day = v_day;
  if v_code = 'FREE_LIMIT' then
    -- Cloudflare の無料枠切れ：翌日（世界標準時 0時5分）まで、すべての解析を止める（試行回数に数えない）
    v_until := ((v_day + 1)::timestamp + interval '5 minutes') at time zone 'utc';
    update aimuse_private.lyrics_align_settings set blocked_until = v_until, updated_at = now() where id = 1;
    update aimuse_private.lyrics_align_jobs set state = 'queued', next_try_at = v_until, last_error = v_code,
           token = null, lease_until = null, updated_at = now() where track_id = p_track;
    v_res := 'blocked';
  elsif v_code in ('AI_AUTH', 'NOT_CONFIGURED') then
    -- トークン・設定の問題：運営者が直して「再開」するまで、すべて止める
    update aimuse_private.lyrics_align_settings set paused = true, pause_reason = lower(v_code), updated_at = now() where id = 1;
    update aimuse_private.lyrics_align_jobs set state = 'queued', next_try_at = now(), last_error = v_code,
           token = null, lease_until = null, updated_at = now() where track_id = p_track;
    v_res := 'paused';
  elsif v_code in ('AUDIO_TOO_LARGE', 'TOO_LONG', 'NO_LYRICS', 'UNKNOWN_DURATION', 'NOT_FOUND', 'NOT_PUBLIC') then
    update aimuse_private.lyrics_align_jobs set state = 'skipped', reason = lower(v_code), last_error = v_code,
           token = null, lease_until = null, finished_at = now(), updated_at = now() where track_id = p_track;
    v_res := 'skipped';
  else
    v_a := v_j.attempts + 1;
    if v_a >= 3 then
      update aimuse_private.lyrics_align_jobs set state = 'failed', reason = 'gave_up', attempts = v_a, last_error = v_code,
             token = null, lease_until = null, finished_at = now(), updated_at = now() where track_id = p_track;
      v_res := 'failed';
    else
      update aimuse_private.lyrics_align_jobs set state = 'queued', attempts = v_a, last_error = v_code,
             next_try_at = now() + case when v_a = 1 then interval '30 minutes' else interval '2 hours' end,
             token = null, lease_until = null, updated_at = now() where track_id = p_track;
      v_res := 'retry';
    end if;
  end if;
  return jsonb_build_object('status', v_res);
end;
$$;

-- ---------------------------------------------------------------------
-- 投稿者・運営（アプリから）
-- ---------------------------------------------------------------------
-- 状態と提案（本人と運営だけ）。提案は今の歌詞で作ったものだけを返す
create or replace function public.lyrics_align_status(p_track uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_role text := aimuse_private.lyrics_align_role(p_track);
  v_j aimuse_private.lyrics_align_jobs;
  v_t public.tracks;
  v_h text;
  v_cur boolean;
  v_src text;
  v_paused boolean;
  v_used_track int; v_used_user int;
begin
  if v_role is null then raise exception 'NOT_ALLOWED: この曲の情報は見られません'; end if;
  select * into v_t from public.tracks t where t.id = p_track;
  v_h := public.lyrics_hash(v_t.lyrics);
  select s.source into v_src from public.track_lyrics_sync s where s.track_id = p_track and s.lyrics_hash = v_h;
  select (paused or coalesce(blocked_until > now(), false)) into v_paused from aimuse_private.lyrics_align_settings where id = 1;
  select count(*) into v_used_track from aimuse_private.lyrics_align_requests r where r.track_id = p_track and r.at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc';
  select count(*) into v_used_user from aimuse_private.lyrics_align_requests r where r.user_id = auth.uid() and r.at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc';
  select * into v_j from aimuse_private.lyrics_align_jobs j where j.track_id = p_track;
  if not found then
    return jsonb_build_object('state', 'none', 'sync_source', v_src, 'paused', v_paused, 'role', v_role,
      'requests_left', greatest(0, least(2 - v_used_track, case when v_role = 'admin' then 2 else 5 - v_used_user end)));
  end if;
  v_cur := v_j.proposal is not null and v_j.meta is not null and v_j.meta->>'lyrics_hash' = v_h;
  return jsonb_build_object(
    'state', v_j.state, 'reason', v_j.reason, 'last_error', v_j.last_error, 'attempts', v_j.attempts,
    'next_try_at', v_j.next_try_at, 'queued_at', v_j.queued_at, 'finished_at', v_j.finished_at,
    'proposal', case when v_cur then v_j.proposal end,
    'meta', case when v_cur then v_j.meta - 'lyrics_hash' end,
    'review', v_j.review,
    'sync_source', v_src, 'paused', v_paused, 'role', v_role,
    'requests_left', greatest(0, least(2 - v_used_track, case when v_role = 'admin' then 2 else 5 - v_used_user end)));
end;
$$;

-- 自分の曲の状態の一覧（マイページの表示用）
create or replace function public.lyrics_align_my_states()
returns table (track_id uuid, state text, has_proposal boolean)
language sql stable security definer set search_path = ''
as $$
  select j.track_id, j.state,
         (j.proposal is not null and j.meta->>'lyrics_hash' = public.lyrics_hash(t.lyrics))
  from aimuse_private.lyrics_align_jobs j
  join public.tracks t on t.id = j.track_id
  where auth.uid() is not null and t.user_id = auth.uid();
$$;

-- 「AI で作り直す」（本人か運営。1曲1日2回・1人1日5回まで。結果は提案として届き、今の同期はそのまま）
create or replace function public.lyrics_align_request(p_track uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text := aimuse_private.lyrics_align_role(p_track);
  v_day timestamptz := date_trunc('day', now() at time zone 'utc') at time zone 'utc';
  v_res text;
begin
  if v_role is null then raise exception 'NOT_ALLOWED: AI の解析を頼めるのは、投稿者本人と運営だけです'; end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_lyrics_align_req:' || auth.uid()::text, 0));
  if (select count(*) from aimuse_private.lyrics_align_requests r where r.track_id = p_track and r.at >= v_day) >= 2 then
    raise exception 'LIMIT: この曲の AI 解析は、1日2回までです';
  end if;
  if v_role <> 'admin' and (select count(*) from aimuse_private.lyrics_align_requests r where r.user_id = auth.uid() and r.at >= v_day) >= 5 then
    raise exception 'LIMIT: AI 解析の依頼は、1日5回までです';
  end if;
  v_res := aimuse_private.lyrics_align_enqueue(p_track, 'requested', true, auth.uid());
  if v_res = 'queued' then
    insert into aimuse_private.lyrics_align_requests (user_id, track_id) values (auth.uid(), p_track);
  end if;
  return jsonb_build_object('result', v_res);
end;
$$;

-- AI の提案を採用して保存（本人か運営。編集画面で直した時刻を渡すこともできる）
--   ・手を加えずに保存 → source = auto、直して保存 → mixed
--   ・投稿者が手動で合わせた同期は、運営でも置き換えられない（本人の操作が必要）
--   ・人が直した量（AI との時刻の差）を記録する（精度の確認用）
create or replace function public.lyrics_align_apply(p_track uuid, p_lines jsonb default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_role text := aimuse_private.lyrics_align_role(p_track);
  v_j aimuse_private.lyrics_align_jobs;
  v_t public.tracks;
  v_h text;
  v_out jsonb;
  v_src text;
  v_stats jsonb;
begin
  if v_role is null then raise exception 'NOT_ALLOWED: 歌詞の同期を変更できるのは、投稿者本人と運営だけです'; end if;
  select * into v_t from public.tracks t where t.id = p_track for update;
  v_h := public.lyrics_hash(v_t.lyrics);
  select * into v_j from aimuse_private.lyrics_align_jobs j where j.track_id = p_track for update;
  if not found or v_j.proposal is null or v_j.state not in ('review', 'applied', 'dismissed') or coalesce(v_j.meta->>'lyrics_hash', '') <> v_h then
    raise exception 'NO_PROPOSAL: 今の歌詞に対する AI の提案がありません';
  end if;
  if v_t.user_id is distinct from auth.uid() and exists (
       select 1 from public.track_lyrics_sync s where s.track_id = p_track and s.source in ('manual', 'mixed')
          and s.lyrics_hash = v_h and jsonb_array_length(s.lines) > 0) then
    raise exception 'NOT_ALLOWED: 投稿者が手動で合わせた同期は、投稿者本人の操作なしに置き換えられません';
  end if;
  v_out := aimuse_private.lyrics_sync_check(v_t, coalesce(p_lines, v_j.proposal));
  v_src := case when v_out = v_j.proposal then 'auto' else 'mixed' end;
  insert into public.track_lyrics_sync as s (track_id, lines, source, lyrics_hash, updated_by, updated_at)
  values (p_track, v_out, v_src, v_h, auth.uid(), now())
  on conflict (track_id) do update
    set lines = excluded.lines, source = excluded.source, lyrics_hash = excluded.lyrics_hash,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  v_stats := aimuse_private.lyrics_align_review_stats(v_j.proposal, v_out)
             || jsonb_build_object('by', v_role, 'at', now(), 'source', v_src);
  update aimuse_private.lyrics_align_jobs set state = 'applied', reason = 'reviewed', review = v_stats, updated_at = now()
   where track_id = p_track;
  return jsonb_build_object('count', jsonb_array_length(v_out), 'source', v_src, 'review', v_stats);
end;
$$;

-- 提案を使わない（本人か運営。今の同期・歌詞の表示はそのまま）
create or replace function public.lyrics_align_dismiss(p_track uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_role text := aimuse_private.lyrics_align_role(p_track);
begin
  if v_role is null then raise exception 'NOT_ALLOWED: この操作は、投稿者本人と運営だけです'; end if;
  update aimuse_private.lyrics_align_jobs set state = 'dismissed', reason = 'dismissed_by_' || v_role, updated_at = now()
   where track_id = p_track and state = 'review';
  return jsonb_build_object('ok', found);
end;
$$;

-- ---------------------------------------------------------------------
-- 運営（管理画面）
-- ---------------------------------------------------------------------
create or replace function public.admin_align_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_st aimuse_private.lyrics_align_settings;
  v_b aimuse_private.lyrics_align_budget;
  v_day date := (now() at time zone 'utc')::date;
begin
  if not public.is_admin() then raise exception 'NOT_ALLOWED: 運営だけが使えます'; end if;
  select * into v_st from aimuse_private.lyrics_align_settings where id = 1;
  select * into v_b from aimuse_private.lyrics_align_budget where day = v_day;
  return jsonb_build_object(
    'settings', jsonb_build_object('paused', v_st.paused, 'pause_reason', v_st.pause_reason, 'daily_cap', v_st.daily_cap,
                                   'auto_apply', v_st.auto_apply, 'blocked_until', v_st.blocked_until),
    'today', jsonb_build_object('day', v_day, 'reserved', coalesce(v_b.reserved, 0), 'runs', coalesce(v_b.runs, 0),
                                'ok', coalesce(v_b.ok, 0), 'failed', coalesce(v_b.failed, 0)),
    'counts', coalesce((select jsonb_object_agg(state, n) from (select state, count(*) n from aimuse_private.lyrics_align_jobs group by state) c), '{}'::jsonb),
    'accuracy', (select jsonb_build_object('songs', count(*),
                   'median_abs', round(coalesce(percentile_cont(0.5) within group (order by (j.review->>'median_abs')::numeric), 0)::numeric, 2),
                   'max_abs', round(coalesce(max((j.review->>'max_abs')::numeric), 0), 2))
                 from aimuse_private.lyrics_align_jobs j where j.review ? 'median_abs'),
    'jobs', coalesce((select jsonb_agg(x order by x->>'updated_at' desc) from (
        select jsonb_build_object('track_id', j.track_id, 'title', t.title, 'artist', t.artist, 'state', j.state, 'reason', j.reason,
          'last_error', j.last_error, 'attempts', j.attempts, 'next_try_at', j.next_try_at, 'finished_at', j.finished_at,
          'ratio', j.meta->'ratio', 'quality_ok', j.meta->'quality_ok', 'review', j.review, 'updated_at', j.updated_at) x
        from aimuse_private.lyrics_align_jobs j join public.tracks t on t.id = j.track_id
        order by j.updated_at desc limit 200) q), '[]'::jsonb));
end;
$$;

create or replace function public.admin_align_set_paused(p_paused boolean)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'NOT_ALLOWED: 運営だけが使えます'; end if;
  update aimuse_private.lyrics_align_settings
     set paused = coalesce(p_paused, true), pause_reason = case when coalesce(p_paused, true) then 'admin' else '' end,
         updated_at = now(), updated_by = auth.uid()
   where id = 1;
  return jsonb_build_object('paused', coalesce(p_paused, true));
end;
$$;

create or replace function public.admin_align_set_cap(p_cap int)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'NOT_ALLOWED: 運営だけが使えます'; end if;
  if p_cap is null or p_cap < 0 or p_cap > 8000 then raise exception 'BAD_DATA: 1日の上限は 0〜8,000 の範囲で指定してください'; end if;
  update aimuse_private.lyrics_align_settings set daily_cap = p_cap, updated_at = now(), updated_by = auth.uid() where id = 1;
  return jsonb_build_object('daily_cap', p_cap);
end;
$$;

-- 1曲を解析待ちに（最初の「おぼろ月」の確認用。手動の同期がある曲は対象外）
create or replace function public.admin_align_enqueue(p_track uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'NOT_ALLOWED: 運営だけが使えます'; end if;
  return jsonb_build_object('result', aimuse_private.lyrics_align_enqueue(p_track, 'admin', false, null));
end;
$$;

-- 公開中の既存曲をまとめて解析待ちに（手動の同期がある曲・同じ歌詞で解析済みの曲は対象外＝重複しない）
create or replace function public.admin_align_enqueue_existing()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare r record; v_res text; v_out jsonb := '{}'::jsonb;
begin
  if not public.is_admin() then raise exception 'NOT_ALLOWED: 運営だけが使えます'; end if;
  for r in select t.id from public.tracks t where t.status = 'public' order by t.approved_at nulls last, t.created_at loop
    v_res := aimuse_private.lyrics_align_enqueue(r.id, 'existing', false, null);
    v_out := jsonb_set(v_out, array[v_res], to_jsonb(coalesce((v_out->>v_res)::int, 0) + 1));
  end loop;
  return v_out;
end;
$$;

-- 打ち切った曲をもう一度（運営の判断。試行回数を0に戻す）
create or replace function public.admin_align_retry(p_track uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_admin() then raise exception 'NOT_ALLOWED: 運営だけが使えます'; end if;
  if not exists (select 1 from aimuse_private.lyrics_align_jobs j where j.track_id = p_track and j.state in ('failed', 'skipped', 'dismissed')) then
    raise exception 'BAD_DATA: 打ち切り・対象外・不採用の曲だけ、やり直せます';
  end if;
  return jsonb_build_object('result', aimuse_private.lyrics_align_enqueue(p_track, 'admin_retry', true, auth.uid()));
end;
$$;

-- ---------------------------------------------------------------------
-- 実行できる人
-- ---------------------------------------------------------------------
revoke all on function public.lyrics_align_secret_matches(text), public.lyrics_align_claim(),
  public.lyrics_align_finish(uuid, uuid, jsonb, jsonb), public.lyrics_align_fail(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.lyrics_align_secret_matches(text), public.lyrics_align_claim(),
  public.lyrics_align_finish(uuid, uuid, jsonb, jsonb), public.lyrics_align_fail(uuid, uuid, text) to service_role;

revoke all on function public.lyrics_align_status(uuid), public.lyrics_align_my_states(), public.lyrics_align_request(uuid),
  public.lyrics_align_apply(uuid, jsonb), public.lyrics_align_dismiss(uuid), public.admin_align_overview(),
  public.admin_align_set_paused(boolean), public.admin_align_set_cap(int), public.admin_align_enqueue(uuid),
  public.admin_align_enqueue_existing(), public.admin_align_retry(uuid)
  from public, anon;
grant execute on function public.lyrics_align_status(uuid), public.lyrics_align_my_states(), public.lyrics_align_request(uuid),
  public.lyrics_align_apply(uuid, jsonb), public.lyrics_align_dismiss(uuid), public.admin_align_overview(),
  public.admin_align_set_paused(boolean), public.admin_align_set_cap(int), public.admin_align_enqueue(uuid),
  public.admin_align_enqueue_existing(), public.admin_align_retry(uuid)
  to authenticated;

commit;
