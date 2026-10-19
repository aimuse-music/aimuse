-- AIMUSE v1.13 を元に戻す（受付スイッチの確認関数を外す。Edge Function は「準備中」を返すようになります。データは変更しません）
drop function if exists public.account_deletion_gate(uuid);
