-- =====================================================================
-- AIMUSE v1.10 レビューの投稿者名を「公開用の名前」に変更（追加のみ）
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：v1.5〜v1.9 を実行済みであること。満たさなければ何も変更せずに中止します
--   ・これまで：レビュー一覧（track_reviews）が、本人と運営だけに見せる約束の「表示名」を返していました
--   ・これから：公開中の曲があるアーティストの方は「アーティスト名」、それ以外の方は「リスナー」と返します
--     （表示名・メールアドレス・会員IDは返しません。引数・戻り値の形・権限は従来どおり）
--   ・既存のデータは変更・削除しません。何度実行しても壊れません
--   ・AIMUSE BOOST が使う関数・表は変更しません
-- =====================================================================

do $$
begin
  if to_regprocedure('public.account_purge_claim()') is null
     or to_regprocedure('public.public_artist_of_user(uuid)') is null then
    raise exception '先に v1.7（フォロー一覧）と v1.9（削除・退会）を実行してください。中止しました。';
  end if;
end $$;

create or replace function public.track_reviews(tid uuid)
returns table (id uuid, rating smallint, comment text, created_at timestamptz,
               updated_at timestamptz, reviewer_name text, is_mine boolean)
language sql stable security definer set search_path = ''
as $$
  select r.id, r.rating, r.comment, r.created_at, r.updated_at,
         coalesce((select a.name from public.artists a where a.id = public.public_artist_of_user(r.user_id)), 'リスナー'),
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

-- =====================================================================
-- 完了
-- =====================================================================
