-- =====================================================================
-- AIMUSE v1.12 を元に戻す（account_purge_db を v1.9 r4 の内容に戻し、合言葉の照合の関数を外す。データは変更しません）
-- =====================================================================
begin;
create or replace function public.account_purge_db(p_request uuid, p_token uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid := aimuse_private.purge_lease(p_request, p_token);
begin
  perform aimuse_private.collect_account_files(p_request, v_user);
  if exists (select 1 from aimuse_private.account_deletion_files f
             where f.request_id = p_request and f.deleted_at is null
               and exists (select 1 from storage.objects o where o.bucket_id = f.bucket_id and o.name = f.name)) then
    raise exception 'FILES_REMAIN: 削除されていないファイルがあります';
  end if;
  update aimuse_private.account_deletion_files set deleted_at = coalesce(deleted_at, now()) where request_id = p_request;
  update aimuse_private.account_deletions set files_done_at = coalesce(files_done_at, now()) where id = p_request;

  update public.tracks set status = 'hidden' where user_id = v_user and status = 'public';
  delete from public.tracks where user_id = v_user;
  delete from aimuse_private.track_deletions where track->>'user_id' = v_user::text;
  update aimuse_private.track_deletions d
     set reviews = coalesce((select jsonb_agg(e) from jsonb_array_elements(d.reviews) e
                             where e->>'user_id' is distinct from v_user::text), '[]'::jsonb)
   where d.reviews @> jsonb_build_array(jsonb_build_object('user_id', v_user::text));
  delete from aimuse_private.reauth_failures where user_id = v_user;
  update aimuse_private.account_deletions set db_done_at = coalesce(db_done_at, now()) where id = p_request;
end;
$$;

revoke all on function public.account_purge_db(uuid, uuid) from public, anon, authenticated;
grant execute on function public.account_purge_db(uuid, uuid) to service_role;
drop function if exists public.purge_secret_matches(text);
commit;
