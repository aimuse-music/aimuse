-- =====================================================================
-- AIMUSE v1.13 退会の受付スイッチを Edge Function からデータベースで確認する関数
--   ・account_deletion_gate(会員ID)：受け付けるなら null、受け付けないなら 'DELETION_DISABLED' / 'NOT_ALLOWED'
--   ・判定は account_request_deletion と同じ（account_deletion_mode と検証用の許可リスト）
--   ・service_role（Edge Function）だけが実行できます。データは変更しません
--   ・元に戻すとき：supabase/rollback/rollback_v1_13.sql
-- =====================================================================
begin;
create or replace function public.account_deletion_gate(p_user uuid)
returns text
language sql stable security definer set search_path = ''
as $$
  select case coalesce((select s.value from aimuse_private.settings s where s.key = 'account_deletion_mode'), 'off')
    when 'all' then null
    when 'testers' then case when exists (select 1 from aimuse_private.deletion_testers t where t.user_id = p_user)
                             then null else 'NOT_ALLOWED' end
    else 'DELETION_DISABLED' end;
$$;
revoke all on function public.account_deletion_gate(uuid) from public, anon, authenticated;
grant execute on function public.account_deletion_gate(uuid) to service_role;
commit;
