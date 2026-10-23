-- 歌詞の自動同期の検証の片付け：追加した関数3つと金庫の合言葉を外す（Edge Function「lyrics-align-probe」は Supabase の画面で削除）
-- ・金庫の合言葉も消します（何度実行しても同じ結果）
drop function if exists public.align_probe_secret_matches(text);
drop function if exists public.align_probe_track(uuid);
drop function if exists public.align_probe_is_admin(uuid);
delete from vault.secrets where name = 'aimuse_align_probe_secret';
select count(*) as "残った検証用の関数（0なら正常）" from pg_proc where pronamespace = 'public'::regnamespace and proname::text like 'align_probe%';
