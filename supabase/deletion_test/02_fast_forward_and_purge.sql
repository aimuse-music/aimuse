-- =====================================================================
-- 退会テスト 2：テスト用アカウントの「30日」を今すぐ過ぎたことにして、完全削除を1回だけ動かす
-- ・前提：テスト用アカウントで退会を申請済み（アプリで「退会手続き中」と表示されている）
-- ・対象は「検証用の許可リスト」の会員の申請だけです。次の場合は何も変更せずに中止します：
--   許可リスト以外の会員の申請がある／対象が1件でない／対象が管理者
-- ・完全削除のスイッチを on にして、Edge Function「account-purge」を1回呼び出します（合言葉は金庫から読み、表示しません）
-- ・Edge Functions → Secrets の AIMUSE_PURGE_ENABLED を true にしてから実行してください
-- ・1〜2分後に 03_check.sql で結果を確認します
-- =====================================================================
begin;
do $$
declare v_n int;
begin
  if exists (select 1 from aimuse_private.account_deletions d
             where d.status in ('pending', 'processing', 'failed')
               and d.user_id not in (select user_id from aimuse_private.deletion_testers)) then
    raise exception '中止：許可リスト以外の会員の退会申請があります。本番の会員を守るため、テストを中止しました';
  end if;
  if exists (select 1 from aimuse_private.account_deletions d join public.profiles p on p.id = d.user_id
             where p.is_admin and d.status in ('pending', 'processing', 'failed')) then
    raise exception '中止：管理者の申請が含まれています';
  end if;
  update aimuse_private.account_deletions d set purge_after = now() - interval '1 minute'
   where d.status = 'pending' and d.user_id in (select user_id from aimuse_private.deletion_testers);
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception '中止：対象の申請が1件ではありません（% 件）。テスト用アカウントで退会を申請してから実行してください', v_n; end if;
  update aimuse_private.settings set value = 'on' where key = 'account_purge_enabled';
end $$;
commit;
-- 完全削除を1回だけ呼び出す（毎日の予定と同じ内容。合言葉は表示されません）
select net.http_post(
  url := 'https://tqtrvjmjfthlrwwligmu.supabase.co/functions/v1/account-purge',
  headers := jsonb_build_object('Content-Type', 'application/json',
    'x-aimuse-purge-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'aimuse_purge_secret')),
  body := '{}'::jsonb, timeout_milliseconds := 110000) is not null as "呼び出しを送信しました（1〜2分後に 03_check.sql）";
