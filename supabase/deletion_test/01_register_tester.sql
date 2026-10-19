-- =====================================================================
-- 退会テスト 1：専用テストアカウントを「検証用の許可リスト」に登録する（受付・完全削除のスイッチは off のまま）
-- ・対象は、表示名を「退会テスト用」にして会員登録したアカウントです（メールアドレスを書き換える必要はありません）
-- ・次の場合は何も変更せずに中止します：該当が1人でない／メール未確認／管理者／アーティスト・曲を持っている／
--   登録から7日を過ぎている／退会の申請が他の会員にある
-- ・結果に表示するのは、テスト用アカウントの会員ID（Edge Function の AIMUSE_DELETE_TESTERS に登録する値）だけです
-- ・受付を「テスト用アカウントだけ」にするのは、検証を始めるときの 01b_start_testers.sql です
-- =====================================================================
begin;
do $$
declare
  v_id uuid; v_n int;
begin
  select count(*) into v_n from auth.users u join public.profiles p on p.id = u.id where trim(p.display_name) = '退会テスト用';
  if v_n <> 1 then raise exception '中止：表示名「退会テスト用」の会員が1人ではありません（% 人）', v_n; end if;
  select u.id into v_id from auth.users u join public.profiles p on p.id = u.id where trim(p.display_name) = '退会テスト用';
  if (select email_confirmed_at from auth.users where id = v_id) is null then raise exception '中止：メールアドレスの確認が済んでいません（確認メールのリンクを開いてください）'; end if;
  if (select created_at from auth.users where id = v_id) < now() - interval '7 days' then raise exception '中止：登録から7日を過ぎたアカウントはテストに使えません'; end if;
  if exists (select 1 from public.profiles where id = v_id and is_admin) then raise exception '中止：管理者アカウントはテストに使えません'; end if;
  if exists (select 1 from public.artists where user_id = v_id) or exists (select 1 from public.tracks where user_id = v_id) then
    raise exception '中止：アーティストや曲を持つアカウントはテストに使えません';
  end if;
  if exists (select 1 from aimuse_private.account_deletions where user_id <> v_id and status in ('pending', 'processing', 'failed')) then
    raise exception '中止：ほかの会員の退会申請があります。テストを始める前に運営で確認してください';
  end if;
  insert into aimuse_private.deletion_testers (user_id, note) values (v_id, '退会の検証用') on conflict (user_id) do nothing;
  perform set_config('aimuse.tester', v_id::text, false);
end $$;
commit;
select current_setting('aimuse.tester', true) as "テスト用アカウントの会員ID（AIMUSE_DELETE_TESTERS に登録）",
       (select value from aimuse_private.settings where key = 'account_deletion_mode') as "受付（off のまま）",
       (select count(*) from aimuse_private.deletion_testers) as "許可リストの人数";
