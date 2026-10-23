-- AIMUSE v1.16 を元に戻す（自動で採用する機能を外し、lyrics_align_finish を v1.15 の形に戻す）
--   ・自動で採用する設定はオフに戻します。保存済みの同期の時刻・提案はそのまま残します
begin;
update aimuse_private.lyrics_align_settings set auto_apply = false where id = 1;
drop function if exists public.admin_align_set_auto(boolean);
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
  v_ok := coalesce(p_meta->'quality_ok' = 'true'::jsonb, false)
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
    'vad_filter', coalesce(p_meta->'vad_filter' = 'true'::jsonb, false),
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
revoke all on function public.lyrics_align_finish(uuid, uuid, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.lyrics_align_finish(uuid, uuid, jsonb, jsonb) to service_role;
commit;
