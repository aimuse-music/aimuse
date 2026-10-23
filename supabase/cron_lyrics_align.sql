-- =====================================================================
-- AIMUSE 歌詞の自動同期（AI）を5分ごとに動かす設定（Supabase の無料機能 pg_cron・pg_net・Vault を使用）
-- ※ 本番導入の手順2（docs/lyrics-auto-sync-plan.md）で使います。v1.15 を適用してから実行してください
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・合言葉（64文字）をデータベースの金庫（Vault）に自動で作り、5分ごとに Edge Function「lyrics-align」を呼びます
--     （送るのは合言葉だけ。曲・会員の情報は送りません。合言葉は表示しません）
--   ・呼ばれても、管理画面で「再開」するまで（v1.15 の初期状態は停止中）、AI の解析は行いません
--   ・1回の呼び出しで解析するのは1曲だけ。1日の上限・同時に1曲・再試行の制限はデータベースの関数が守ります
--   ・何度実行しても、予定は1つだけです（同じ名前の予定を置き換えます）。合言葉は最初の1回だけ作ります
--   ・止めるとき：select cron.unschedule('aimuse-lyrics-align');
--   ・AIMUSE BOOST の表・関数には触れません
-- =====================================================================
begin;

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

do $$
begin
  if to_regprocedure('public.lyrics_align_secret_matches(text)') is null then
    raise exception '先に v1.15（migration_v1_15_lyrics_auto_sync.sql）を適用してください。何も変更せずに中止しました。';
  end if;
  if not exists (select 1 from vault.secrets where name = 'aimuse_align_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'aimuse_align_secret', 'AIMUSE lyrics-align の合言葉');
  end if;
end $$;

select cron.schedule(
  'aimuse-lyrics-align',
  '*/5 * * * *',   -- 5分ごと
  $job$
  select net.http_post(
    url := 'https://tqtrvjmjfthlrwwligmu.supabase.co/functions/v1/lyrics-align',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-aimuse-align-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'aimuse_align_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 140000);
  $job$
);

commit;

-- 結果の表示（合言葉そのものは表示しません）
select (select count(*) from cron.job where jobname = 'aimuse-lyrics-align' and active) as "5分ごとの予定（1なら正常）",
       (select count(*) from vault.secrets where name = 'aimuse_align_secret') as "金庫の合言葉（1なら正常）",
       (select paused from aimuse_private.lyrics_align_settings where id = 1) as "停止中（true なら、まだ解析しない）";
