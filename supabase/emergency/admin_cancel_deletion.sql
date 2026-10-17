-- =====================================================================
-- 【緊急時のみ・運営者が SQL Editor で実行】退会申請を運営が取り消す
-- 使う場面：v1.9 を元に戻す必要があるのに退会手続き中の会員がいる／本人が取り消せない事情がある、など
-- ・下の 'ここにメールアドレス' を対象の会員のメールアドレスに置き換えてから実行
-- ・取り消し期間中（pending）、または失敗で止まった（failed）申請だけが対象
-- ・ファイルの削除が1件でも始まっていたら、何も変更せずに中止（曲を公開に戻すと音源が無い状態になるため）
-- ・処理中（processing）の場合は、先に定期実行（Cron）を止めて、10分以上待ってから実行
-- ・申請時に非公開にした曲を元の状態に戻す（本人の取り消しと同じ）
-- =====================================================================
do $$
declare
  v_user uuid;
  v_req aimuse_private.account_deletions%rowtype;
  v_item jsonb;
  v_n integer := 0;
begin
  select u.id into v_user from auth.users u where lower(u.email) = lower('ここにメールアドレス');
  if v_user is null then raise exception '会員が見つかりません'; end if;
  perform pg_advisory_xact_lock(hashtextextended('aimuse_account:' || v_user::text, 0));
  select * into v_req from aimuse_private.account_deletions d
   where d.user_id = v_user and d.status in ('pending', 'processing', 'failed') for update;
  if not found then raise exception '取り消せる退会申請がありません'; end if;
  if v_req.status = 'processing' and v_req.locked_until > now() then
    raise exception '削除処理が動いています。定期実行（Cron）を止めて、10分以上待ってから実行してください';
  end if;
  if exists (select 1 from aimuse_private.account_deletion_files f where f.request_id = v_req.id and f.deleted_at is not null)
     or v_req.db_done_at is not null then
    raise exception 'ファイルまたはデータの削除が始まっているため、元に戻せません。削除を完了させてください';
  end if;
  update aimuse_private.account_deletions
     set status = 'canceled', canceled_at = now(), lock_token = null, locked_until = null, last_error = '運営が取り消し'
   where id = v_req.id;
  for v_item in select * from jsonb_array_elements(v_req.hidden_tracks) loop
    update public.tracks set status = v_item->>'status'
     where id = (v_item->>'id')::uuid and user_id = v_user and status = 'hidden';
    v_n := v_n + 1;
  end loop;
  delete from aimuse_private.account_deletion_files where request_id = v_req.id;
  raise notice '取り消しました（元に戻した曲：% 曲）', v_n;
end $$;
