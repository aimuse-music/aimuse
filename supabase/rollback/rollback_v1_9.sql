-- =====================================================================
-- AIMUSE 元に戻す用SQL：v1.9 を取り消して v1.8 の状態に戻す（緊急時のみ・運営者の判断で実行）
-- 実行する前に：アプリ（GitHub）を v1.9 より前の版に戻しておくこと（新しい画面が古いDBで動かないように）
-- ・関数・トリガー・アクセスルールを v1.8 の内容に戻します
-- ・追加した列・表・索引・保存場所は、データを守るため削除しません（使われなくなるだけ）
-- ・退会手続き中の会員がいる場合は、何も変更せずに中止します
-- ・本人が削除した曲の記録（30日間の復元用）は残り、これまでどおり運営が復元できます
-- 何度実行しても壊れません
-- =====================================================================
do $$
begin
  if to_regclass('aimuse_private.account_deletions') is not null
     and exists (select 1 from aimuse_private.account_deletions where status in ('pending', 'processing', 'failed')) then
    raise exception '退会手続き中の会員がいるため中止しました。先に個別の対応（取り消し・完了）が必要です。';
  end if;
  if to_regprocedure('public.track_reviews(uuid)') is not null
     and position('public_artist_of_user' in pg_get_functiondef('public.track_reviews(uuid)'::regprocedure)) > 0 then
    raise exception 'v1.10 が有効です。先に rollback_v1_10.sql を実行してください。中止しました。';
  end if;
end $$;

create or replace function public.is_active_member()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null
     and exists (select 1 from auth.users u
                 where u.id = auth.uid() and u.email_confirmed_at is not null)
     and not coalesce((select p.is_banned from public.profiles p where p.id = auth.uid()), true);
$$;

create or replace function public.is_visible_member(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles p where p.id = p_user and not p.is_banned);
$$;

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
  order by r.created_at desc
  limit 200;
$$;

create or replace function public.track_rating_summary(tid uuid)
returns table (average numeric, total integer)
language sql stable security definer set search_path = ''
as $$
  select round(avg(r.rating)::numeric, 1), count(*)::integer
  from public.reviews r
  join public.tracks t on t.id = r.track_id
  left join public.profiles p on p.id = r.user_id
  where r.track_id = tid and t.status = 'public' and not coalesce(p.is_banned, false);
$$;

drop trigger if exists tracks_block_withdrawing on public.tracks;
drop trigger if exists profiles_block_withdrawing on public.profiles;
drop function if exists public.delete_my_track(uuid);
drop function if exists public.account_request_deletion(uuid);
drop function if exists public.account_reauth_allowed(uuid);
drop function if exists public.account_reauth_failed(uuid);
drop function if exists public.cancel_my_account_deletion();
drop function if exists public.my_account_deletion();
drop function if exists public.account_purge_claim();
drop function if exists public.account_purge_pending_files(uuid, uuid);
drop function if exists public.account_purge_mark_files(uuid, uuid);
drop function if exists public.account_purge_db(uuid, uuid);
drop function if exists public.account_purge_finish(uuid, uuid);
drop function if exists public.account_purge_fail(uuid, uuid, text);
drop function if exists aimuse_private.purge_lease(uuid, uuid);
drop function if exists aimuse_private.collect_account_files(uuid, uuid);
drop function if exists aimuse_private.tracks_block_withdrawing();
drop function if exists aimuse_private.profiles_block_withdrawing();
drop function if exists aimuse_private.is_withdrawing(uuid);
-- 権限は v1.5 / v1.7 と同じ
revoke all on function public.is_active_member() from public, anon, authenticated;
grant execute on function public.is_active_member() to anon, authenticated;
revoke all on function public.is_visible_member(uuid) from public, anon, authenticated;
revoke all on function public.track_reviews(uuid) from public, anon, authenticated;
grant execute on function public.track_reviews(uuid) to anon, authenticated;
revoke all on function public.track_rating_summary(uuid) from public, anon, authenticated;
grant execute on function public.track_rating_summary(uuid) to anon, authenticated;
notify pgrst, 'reload schema';
