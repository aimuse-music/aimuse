-- =====================================================================
-- AIMUSE 元に戻す用SQL：v1.10 を取り消して v1.9 の状態に戻す（緊急時のみ・運営者の判断で実行）
-- 実行する前に：アプリ（GitHub）を v1.10 より前の版に戻しておくこと（新しい画面が古いDBで動かないように）
-- ・関数・トリガー・アクセスルールを v1.9 の内容に戻します
-- ・追加した列・表・索引・保存場所は、データを守るため削除しません（使われなくなるだけ）
-- 何度実行しても壊れません
-- =====================================================================
create or replace function public.track_reviews(tid uuid)
returns table (id uuid, rating smallint, comment text, created_at timestamptz,
               updated_at timestamptz, reviewer_name text, is_mine boolean)
language sql stable security definer set search_path = ''
as $$
  select r.id, r.rating, r.comment, r.created_at, r.updated_at,
         coalesce(p.display_name, '会員'),
         (auth.uid() is not null and r.user_id = auth.uid())
  from public.reviews r
  join public.tracks t on t.id = r.track_id
  left join public.profiles p on p.id = r.user_id
  where r.track_id = tid
    and (t.status = 'public' or t.user_id = auth.uid() or public.is_admin())
    and not coalesce(p.is_banned, false)
    and not aimuse_private.is_withdrawing(r.user_id)
  order by r.created_at desc
  limit 200;
$$;

revoke all on function public.track_reviews(uuid) from public, anon, authenticated;
grant execute on function public.track_reviews(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
