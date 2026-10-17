-- =====================================================================
-- AIMUSE 元に戻す用SQL：v1.7 を取り消して v1.6 の状態に戻す（緊急時のみ・運営者の判断で実行）
-- 実行する前に：アプリ（GitHub）を v1.7 より前の版に戻しておくこと（新しい画面が古いDBで動かないように）
-- ・関数・トリガー・アクセスルールを v1.6 の内容に戻します
-- ・追加した列・表・索引・保存場所は、データを守るため削除しません（使われなくなるだけ）
-- ・フォロー一覧用の索引は残ります（あっても害はありません）
-- 何度実行しても壊れません
-- =====================================================================
do $$
begin
  if to_regprocedure('public.set_my_theme(jsonb)') is not null then
    raise exception 'v1.8 が有効です。先に rollback_v1_8.sql を実行してください。中止しました。';
  end if;
end $$;
create or replace function public.artist_follower_count(aid uuid)
returns integer
language sql stable security definer set search_path = ''
as $$
  select count(*)::integer from public.follows f where f.artist_id = aid;
$$;

drop function if exists public.my_following(timestamptz, uuid, integer);
drop function if exists public.public_artist_following(uuid, timestamptz, uuid, integer);
drop function if exists public.public_artist_followers(uuid, timestamptz, uuid, integer);
drop function if exists public.public_artist_follow_summary(uuid);
drop function if exists public.public_artist_of_user(uuid);
drop function if exists public.is_public_artist(uuid);
drop function if exists public.is_visible_member(uuid);
revoke all on function public.artist_follower_count(uuid) from public, anon, authenticated;
grant execute on function public.artist_follower_count(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
