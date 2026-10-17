-- =====================================================================
-- AIMUSE 元に戻す用SQL：v1.8 を取り消して v1.7 の状態に戻す（緊急時のみ・運営者の判断で実行）
-- 実行する前に：アプリ（GitHub）を v1.8 より前の版に戻しておくこと（新しい画面が古いDBで動かないように）
-- ・関数・トリガー・アクセスルールを v1.7 の内容に戻します
-- ・追加した列・表・索引・保存場所は、データを守るため削除しません（使われなくなるだけ）
-- ・保存済みのテーマ（profiles.theme）は残ります
-- 何度実行しても壊れません
-- =====================================================================
do $$
begin
  if to_regprocedure('public.account_purge_claim()') is not null then
    raise exception 'v1.9 が有効です。先に rollback_v1_9.sql を実行してください。中止しました。';
  end if;
end $$;
drop function if exists public.set_my_theme(jsonb);
notify pgrst, 'reload schema';
