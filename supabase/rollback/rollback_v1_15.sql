-- AIMUSE v1.15 を元に戻す（AI の歌詞自動同期の表・関数・トリガーを外し、lyrics_sync_save を v1.14 の形に戻す）
--   ・楽曲・歌詞は変更しません。同期の時刻（track_lyrics_sync）もそのまま残します
--     （AI が作った同期を消したい場合だけ、最後のコメントの1行を別に実行）
--   ・定期実行を入れている場合は、先に cron_lyrics_align.sql の「止めるとき」の1行を実行
begin;
drop trigger if exists tracks_lyrics_align on public.tracks;
drop function if exists public.admin_align_retry(uuid);
drop function if exists public.admin_align_enqueue_existing();
drop function if exists public.admin_align_enqueue(uuid);
drop function if exists public.admin_align_set_cap(int);
drop function if exists public.admin_align_set_paused(boolean);
drop function if exists public.admin_align_overview();
drop function if exists public.lyrics_align_dismiss(uuid);
drop function if exists public.lyrics_align_apply(uuid, jsonb);
drop function if exists public.lyrics_align_request(uuid);
drop function if exists public.lyrics_align_my_states();
drop function if exists public.lyrics_align_status(uuid);
drop function if exists public.lyrics_align_fail(uuid, uuid, text);
drop function if exists public.lyrics_align_finish(uuid, uuid, jsonb, jsonb);
drop function if exists public.lyrics_align_claim();
drop function if exists public.lyrics_align_secret_matches(text);
drop function if exists aimuse_private.lyrics_align_on_track();
drop function if exists aimuse_private.lyrics_align_enqueue(uuid, text, boolean, uuid);
drop function if exists aimuse_private.lyrics_align_role(uuid);
drop function if exists aimuse_private.lyrics_align_review_stats(jsonb, jsonb);
drop function if exists aimuse_private.jnum(jsonb, text, numeric, numeric, numeric);
drop table if exists aimuse_private.lyrics_align_requests;
drop table if exists aimuse_private.lyrics_align_settings;
drop table if exists aimuse_private.lyrics_align_budget;
drop table if exists aimuse_private.lyrics_align_jobs;

-- lyrics_sync_save を v1.14 と同じ動き（常に manual）に戻す
create or replace function public.lyrics_sync_save(p_track uuid, p_lines jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_t public.tracks;
  v_out jsonb;
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
  insert into public.track_lyrics_sync as s (track_id, lines, source, lyrics_hash, updated_by, updated_at)
  values (p_track, v_out, 'manual', public.lyrics_hash(v_t.lyrics), auth.uid(), now())
  on conflict (track_id) do update
    set lines = excluded.lines, source = excluded.source, lyrics_hash = excluded.lyrics_hash,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('count', jsonb_array_length(v_out), 'updated_at', now());
end;
$$;
revoke all on function public.lyrics_sync_save(uuid, jsonb) from public, anon;
grant execute on function public.lyrics_sync_save(uuid, jsonb) to authenticated, service_role;
-- 検証の関数（lyrics_sync_check・lyrics_text_count・lyrics_align_ineligible）は lyrics_sync_save が使うため残します（害はありません）
commit;
-- AI が作った同期（手を加えていないもの）も消す場合だけ：
-- delete from public.track_lyrics_sync where source = 'auto';
