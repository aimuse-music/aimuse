-- =====================================================================
-- AIMUSE 退会の完全削除を1日1回動かす設定（Supabase の無料機能 pg_cron・pg_net・Vault を使用）
-- ※ 退会機能を公開する手順（supabase/functions/ROLLOUT.md）の「手順5」で使います。それ以前には実行しないでください
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・合言葉（64文字）をデータベースの金庫（Vault）に自動で作り、毎日 03:17（日本時間）に
--     Edge Function「account-purge」を呼び出します（会員ID・メールアドレスは送りません）
--   ・合言葉は表示しません。Edge Function は v1.12 の purge_secret_matches で金庫の合言葉と照合するため、
--     人が見たり、どこかに書き写したりする必要はありません（先に v1.12 を適用してください）
--   ・何度実行しても、予定は1つだけです（同じ名前の予定を置き換えます）。合言葉は最初の1回だけ作ります
--   ・止めるとき：select cron.unschedule('aimuse-account-purge');
--   ・AIMUSE BOOST の表・関数には触れません
-- =====================================================================
begin;   -- 途中で中止したときは、拡張機能の追加も含めて全体を取り消す

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;   -- Supabase 推奨の場所

do $$
begin
  if to_regprocedure('public.purge_secret_matches(text)') is null then
    raise exception '先に v1.12（migration_v1_12_purge_play_events.sql）を適用してください。何も変更せずに中止しました。';
  end if;
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

commit;

-- 結果の表示（合言葉そのものは表示しません）
select (select count(*) from cron.job where jobname = 'aimuse-account-purge' and active) as "1日1回の予定（1なら正常）",
       (select count(*) from vault.secrets where name = 'aimuse_purge_secret') as "金庫の合言葉（1なら正常）",
       to_regprocedure('public.purge_secret_matches(text)') is not null as "v1.12 の照合関数";
