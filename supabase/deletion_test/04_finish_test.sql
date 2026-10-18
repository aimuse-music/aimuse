-- =====================================================================
-- 退会テスト 4：テストの後片付け（受付と完全削除を止める。公開するときは ROLLOUT.md の手順7で on にします）
-- =====================================================================
begin;
update aimuse_private.settings set value = 'off' where key = 'account_deletion_mode';
update aimuse_private.settings set value = 'off' where key = 'account_purge_enabled';
delete from aimuse_private.deletion_testers;
commit;
select (select value from aimuse_private.settings where key = 'account_deletion_mode') as "受付",
       (select value from aimuse_private.settings where key = 'account_purge_enabled') as "完全削除",
       (select count(*) from aimuse_private.deletion_testers) as "許可リストの人数";
