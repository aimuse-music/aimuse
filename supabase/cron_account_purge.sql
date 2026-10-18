-- =====================================================================
-- AIMUSE 退会の完全削除を1日1回動かす設定（Supabase の無料機能 pg_cron・pg_net・Vault を使用）
-- ※ 退会機能を公開する手順（supabase/functions/ROLLOUT.md）の「手順5」で使います。それ以前には実行しないでください
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・合言葉（32文字以上）をデータベースの金庫（Vault）に自動で作り、毎日 03:17（日本時間）に
--     Edge Function「account-purge」を呼び出します（会員ID・メールアドレスは送りません）
--   ・実行後に表示される合言葉を、Edge Functions → Secrets の AIMUSE_PURGE_SECRET に登録してください
--   ・何度実行しても、予定は1つだけです（同じ名前の予定を置き換えます）。合言葉は最初の1回だけ作ります
--   ・止めるとき：select cron.unschedule('aimuse-account-purge');
--   ・AIMUSE BOOST の表・関数には触れません
-- =====================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'aimuse_purge_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'aimuse_purge_secret', 'AIMUSE account-purge の合言葉');
  end if;
end $$;

select cron.schedule(
  'aimuse-account-purge',
  '17 18 * * *',   -- 毎日 18:17（世界標準時）＝ 03:17（日本時間）
  $job$
  select net.http_post(
    url := 'https://tqtrvjmjfthlrwwligmu.supabase.co/functions/v1/account-purge',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-aimuse-purge-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'aimuse_purge_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 110000);
  $job$
);

-- 合言葉の表示（この1行だけを Edge Function の Secrets に貼り付けます。ほかの人に見せないでください）
select decrypted_secret as "AIMUSE_PURGE_SECRET に登録する値" from vault.decrypted_secrets where name = 'aimuse_purge_secret';
