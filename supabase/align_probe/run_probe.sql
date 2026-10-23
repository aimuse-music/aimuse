-- =====================================================================
-- 歌詞の自動同期の検証：「おぼろ月」を1回解析する（結果は返すだけで、データベースの歌詞・同期は変更しません）
--   ・prompt：false＝歌詞の手がかりなし / true＝歌詞の先頭を手がかりとして渡す
--   ・1回あたり約200ニューロン（Cloudflare の無料枠は1日10,000）
--   ・結果は1〜2分後に、下の「結果を見る」SQL で確認します（合言葉は表示されません）
-- =====================================================================
select net.http_post(
  url := 'https://tqtrvjmjfthlrwwligmu.supabase.co/functions/v1/lyrics-align-probe',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-aimuse-probe-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'aimuse_align_probe_secret')),
  body := jsonb_build_object('track_id', (select id from public.tracks where title = 'おぼろ月' limit 1), 'prompt', false),
  timeout_milliseconds := 140000) as "受付番号";
-- 結果を見る：select status_code, content::jsonb from net._http_response where id = 受付番号;
