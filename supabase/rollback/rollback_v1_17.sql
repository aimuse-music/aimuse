-- AIMUSE v1.17 を元に戻す（アクセス解析の表・関数・毎日の集計を外し、increment_plays を v1.5 と同じ中身に戻す）
--   楽曲・会員・再生数（tracks.plays）・再生記録（play_events）は変更しません。アクセス解析の記録と集計値は消えます
begin;
-- 再生数の関数を v1.5 の中身に戻す（権限は変わりません）
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

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$select cron.unschedule(jobid) from cron.job where jobname = 'aimuse-analytics-maintain'$q$;
  end if;
end $$;
drop function if exists public.admin_analytics_ranking(integer, integer);
drop function if exists public.admin_analytics();
drop function if exists public.count_play(uuid, uuid);
drop function if exists public.analytics_exclude_device(uuid);
drop function if exists public.analytics_track(uuid, text);
drop function if exists aimuse_private.analytics_maintain(boolean);
drop function if exists aimuse_private.analytics_note_play(uuid, uuid);
drop function if exists aimuse_private.play_count_core(uuid);
drop function if exists aimuse_private.analytics_ip_bucket();
drop function if exists aimuse_private.analytics_vid_hash(uuid);
drop table if exists aimuse_private.analytics_plays_daily;
drop table if exists aimuse_private.analytics_monthly;
drop table if exists aimuse_private.analytics_daily;
drop table if exists aimuse_private.analytics_rate_ids;
drop table if exists aimuse_private.analytics_rate;
drop table if exists aimuse_private.analytics_excluded;
drop table if exists aimuse_private.analytics_views;
delete from aimuse_private.settings
where key in ('analytics_salt','analytics_enabled','analytics_started','analytics_raw_from','analytics_last_maintain');
commit;
