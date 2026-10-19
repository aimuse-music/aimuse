-- =====================================================================
-- 退会テスト 4b：完全削除のテストの後片付け（受付は全員のまま・完全削除だけ off に戻す）
-- ・公開中（受付 all）にテストした場合はこちらを使います（04_finish_test.sql は受付も off にします）
-- ・あわせて Edge Functions → Secrets の AIMUSE_PURGE_ENABLED を削除してください（完全削除を有効化する場合はそのまま）
-- =====================================================================
begin;
update aimuse_private.settings set value = 'off' where key = 'account_purge_enabled';
delete from aimuse_private.deletion_testers;
commit;
select (select value from aimuse_private.settings where key = 'account_deletion_mode') as "受付（all のまま）",
       (select value from aimuse_private.settings where key = 'account_purge_enabled') as "完全削除（off）",
       (select count(*) from aimuse_private.deletion_testers) as "許可リストの人数";
