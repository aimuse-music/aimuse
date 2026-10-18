-- =====================================================================
-- AIMUSE v1.12 退会の完全削除で「その会員が聴いた再生記録」も消す／完全削除の呼び出しの合言葉を金庫（Vault）で確認
-- Supabase の SQL Editor に全文を貼り付けて、1回実行してください。
--   ・前提：v1.9 r4（退会）と v1.11（プレイリスト）を実行済みであること。満たさなければ何も変更せずに中止します
--   ・変更するのは account_purge_db（30日後の完全削除のデータ削除の手順）だけです。引数・戻り値・権限は同じです
--   ・追加した処理：public.play_events のうち viewer_key = 'u:会員ID' の行（その会員が聴いた記録）を削除
--     （ハムハムの手作業の削除で見つかった残り。曲の再生数 tracks.plays は変わりません）
--   ・追加：purge_secret_matches（完全削除の Edge Function が、呼び出しの合言葉をデータベースの金庫と照合するための関数。
--     service_role だけが実行でき、合言葉そのものは返しません）。合言葉は人が見たり書き写したりする必要がありません
--   ・既存のデータは変更しません。退会の受付・完全削除のスイッチ（off）もそのままです
--   ・何度実行しても同じ結果になります。全体を BEGIN〜COMMIT で囲んでいます
--   ・AIMUSE BOOST の表・関数には触れません
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.account_purge_db(uuid,uuid)') is null or to_regprocedure('public.account_reauth_begin(uuid)') is null then
    raise exception 'v1.9 r4（退会）が未適用です。何も変更せずに中止しました。';
  end if;
  if to_regclass('public.playlists') is null then
    raise exception 'v1.11（プレイリスト）が未適用です。何も変更せずに中止しました。';
  end if;
end $$;

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
  -- v1.12：この会員が聴いた再生記録（重複を数えないための目印。曲の再生数 plays は変わりません）
  delete from public.play_events where viewer_key = 'u:' || v_user::text;
  update aimuse_private.account_deletions set db_done_at = coalesce(db_done_at, now()) where id = p_request;
end;
$$;

revoke all on function public.account_purge_db(uuid, uuid) from public, anon, authenticated;
grant execute on function public.account_purge_db(uuid, uuid) to service_role;

-- 完全削除の呼び出しの合言葉の照合（合言葉は Vault の aimuse_purge_secret。cron_account_purge.sql が作成）
--   ・一致すれば true。金庫に合言葉が無い・32文字未満・不一致なら false。合言葉そのものは返さない
create or replace function public.purge_secret_matches(p_secret text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v text;
begin
  if p_secret is null or char_length(p_secret) < 32 or to_regclass('vault.decrypted_secrets') is null then
    return false;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 order by created_at desc limit 1'
    into v using 'aimuse_purge_secret';
  return v is not null and char_length(v) >= 32 and v = p_secret;
end;
$$;
revoke all on function public.purge_secret_matches(text) from public, anon, authenticated;
grant execute on function public.purge_secret_matches(text) to service_role;

commit;
