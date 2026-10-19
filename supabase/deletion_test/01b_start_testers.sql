-- =====================================================================
-- 退会テスト 1b：検証を始める（受付を「許可リストのテスト用アカウントだけ」にする）※運営者の承認後に実行
-- ・次の場合は何も変更せずに中止します：許可リストが空／許可リストに管理者・アーティストを持つ会員がいる／
--   許可リスト以外の会員の退会申請がある
-- ・Edge Functions → Secrets の AIMUSE_DELETE_MODE も testers にします（両方が testers のときだけ申請できます）
-- ・完全削除のスイッチ（account_purge_enabled）は off のままです
-- =====================================================================
begin;
do $$
begin
  if not exists (select 1 from aimuse_private.deletion_testers) then raise exception '中止：許可リストが空です（先に 01_register_tester.sql）'; end if;
  if exists (select 1 from aimuse_private.deletion_testers t join public.profiles p on p.id = t.user_id where p.is_admin)
     or exists (select 1 from aimuse_private.deletion_testers t join public.artists a on a.user_id = t.user_id) then
    raise exception '中止：許可リストに管理者またはアーティストを持つ会員がいます';
  end if;
  if exists (select 1 from aimuse_private.account_deletions d where d.status in ('pending', 'processing', 'failed')
             and d.user_id not in (select user_id from aimuse_private.deletion_testers)) then
    raise exception '中止：許可リスト以外の会員の退会申請があります';
  end if;
  update aimuse_private.settings set value = 'testers' where key = 'account_deletion_mode';
end $$;
commit;
select (select value from aimuse_private.settings where key = 'account_deletion_mode') as "受付",
       (select value from aimuse_private.settings where key = 'account_purge_enabled') as "完全削除（off のまま）",
       (select count(*) from aimuse_private.deletion_testers) as "許可リストの人数";
