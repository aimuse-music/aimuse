-- =====================================================================
-- 歌詞の自動同期の検証：「おぼろ月」（結果は返すだけ。歌詞・同期の時刻・楽曲は変更しません）
--   ・合言葉は金庫から読んで送るだけで、表示されません
--   ・A は設定の確認だけ（AI を使わない・無料枠を使わない）。B・C は1回あたり約200ニューロン（無料枠は1日10,000）
--   ・結果は1〜2分後に D で確認します
-- =====================================================================

-- A. 設定の確認（名前・形式・トークンが有効か）
select net.http_post(
  url := 'https://tqtrvjmjfthlrwwligmu.supabase.co/functions/v1/lyrics-align-probe',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-aimuse-probe-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'aimuse_align_probe_secret')),
  body := jsonb_build_object('check', true), timeout_milliseconds := 30000) as "受付番号A";

-- B. 解析（歌詞の手がかりなし）
-- select net.http_post(url := 'https://tqtrvjmjfthlrwwligmu.supabase.co/functions/v1/lyrics-align-probe',
--   headers := jsonb_build_object('Content-Type', 'application/json', 'x-aimuse-probe-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'aimuse_align_probe_secret')),
--   body := jsonb_build_object('track_id', (select id from public.tracks where title = 'おぼろ月' limit 1), 'prompt', false), timeout_milliseconds := 140000) as "受付番号B";

-- C. 解析（歌詞の先頭を手がかりに渡す）
-- （B の 'prompt', false を 'prompt', true に変えて実行）

-- D. 結果の確認（受付番号を入れる）
-- select status_code, content::jsonb - 'lines' - 'transcript_head' as "概要", content::jsonb -> 'checkpoints' as "確認する代表的な行"
-- from net._http_response where id = 受付番号;
