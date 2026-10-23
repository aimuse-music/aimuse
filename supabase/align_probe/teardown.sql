-- 歌詞の自動同期の検証の片付け：照合の関数を外す（Edge Function「lyrics-align-probe」は Supabase の画面で削除）
-- ・金庫の合言葉は、関数を外すと使われなくなります（残っていても害はありません）
drop function if exists public.align_probe_secret_matches(text);
drop function if exists public.align_probe_track(uuid);
drop function if exists public.align_probe_is_admin(uuid);
