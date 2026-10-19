-- =====================================================================
-- AIMUSE 2026-10-19 本番作業の仕上げ（SQL Editor に全文を貼り付けて、1回だけ実行してください）
--   1. v1.12 の適用：完全削除の手順（account_purge_db）に「その会員が聴いた再生記録も消す」を1行追加
--      （Claude の接続からは「削除を含む変更」を実行できないため、ここだけ運営者が実行します）
--   2. pg_net（定期実行の送信の仕組み）を Supabase 推奨の場所（extensions）に入れ直す
--      ・送信待ちが0件のときだけ行います。毎日の予定（aimuse-account-purge）と金庫の合言葉はそのまま残ります
--   ・既存の会員・楽曲・再生数・フォロー・プレイリストは変更しません。退会の受付・完全削除のスイッチは off のままです
--   ・何度実行しても同じ結果になります。途中で中止したときは全体を取り消します
--   ・元に戻すとき：supabase/rollback/rollback_v1_12.sql
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


-- 2. pg_net を extensions に入れ直す（すでに extensions にあれば何もしない）
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_net' and extnamespace = 'public'::regnamespace) then
    if (select count(*) from net.http_request_queue) <> 0 then
      raise exception '中止：送信待ちの呼び出しがあります。数分後にもう一度実行してください（何も変更していません）';
    end if;
    drop extension pg_net;
  end if;
  create extension if not exists pg_net with schema extensions;
end $$;

-- 安全の確認：スイッチが off のままであること
do $$
begin
  if (select value from aimuse_private.settings where key = 'account_deletion_mode') <> 'off'
     or (select value from aimuse_private.settings where key = 'account_purge_enabled') <> 'off' then
    raise exception '中止：退会の受付・完全削除のスイッチが off ではありません（何も変更していません）';
  end if;
end $$;
commit;

-- 結果（すべて true なら完了。合言葉は表示しません）
select position('play_events' in (select prosrc from pg_proc where oid = 'public.account_purge_db(uuid,uuid)'::regprocedure)) > 0 as "1_v1.12 適用済み",
       (select extnamespace = 'extensions'::regnamespace from pg_extension where extname = 'pg_net') as "2_pg_net の場所",
       (select count(*) = 1 from cron.job where jobname = 'aimuse-account-purge' and active) as "3_毎日の予定",
       (select count(*) = 1 from vault.secrets where name = 'aimuse_purge_secret') as "4_金庫の合言葉",
       (select value = 'off' from aimuse_private.settings where key = 'account_purge_enabled') as "5_完全削除は off のまま";
