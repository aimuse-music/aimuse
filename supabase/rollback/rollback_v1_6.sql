-- =====================================================================
-- AIMUSE 元に戻す用SQL：v1.6 を取り消して v1.5 の状態に戻す（緊急時のみ・運営者の判断で実行）
-- 実行する前に：アプリ（GitHub）を v1.6 より前の版に戻しておくこと（新しい画面が古いDBで動かないように）
-- ・関数・トリガー・アクセスルールを v1.5 の内容に戻します
-- ・追加した列・表・索引・保存場所は、データを守るため削除しません（使われなくなるだけ）
-- ・アイコン・背景の保存場所（avatars）とその中の画像、profiles の画像の列、名前の変更履歴は残ります
-- ・avatars の画像は公開のまま残るため、必要なら運営が Storage 画面で個別に削除してください
-- 何度実行しても壊れません
-- =====================================================================
do $$
begin
  if to_regprocedure('public.my_following(timestamptz,uuid,integer)') is not null then
    raise exception 'v1.7 が有効です。先に rollback_v1_7.sql を実行してください。中止しました。';
  end if;
end $$;
drop policy if exists "aimuse avatars upload own" on storage.objects;
drop policy if exists "aimuse avatars select own" on storage.objects;
drop policy if exists "aimuse avatars delete own" on storage.objects;
drop policy if exists "aimuse avatars internal read" on storage.objects;
drop function if exists public.avatar_can_delete(text, text);
drop function if exists public.avatar_can_upload();
drop function if exists public.admin_artist_name_history(integer);
drop function if exists public.admin_set_artist_name(uuid, text);
drop function if exists public.admin_reset_profile_image(uuid, text);
drop function if exists public.public_artist_profiles(uuid[]);
drop function if exists public.rename_my_artist(uuid, text);
drop function if exists public.set_my_profile_image(text, text);
drop function if exists public.artist_name_clean(text);
drop function if exists public.artist_name_key(text);
notify pgrst, 'reload schema';
