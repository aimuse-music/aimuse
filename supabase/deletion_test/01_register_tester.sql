-- =====================================================================
-- 退会テスト 1：専用テストアカウントを「検証用の許可リスト」に登録し、受付を「テスト用アカウントだけ」にする
-- ・下の 'テスト用のメールアドレス' を、専用テストアカウントのメールアドレスに書き換えてから実行してください
-- ・次の場合は何も変更せずに中止します：該当が1人でない／メール未確認／管理者／NOCTERA を持っている／
--   退会の申請が他の会員にある
-- ・結果に表示するのは、テスト用アカウントの会員ID（Edge Function の AIMUSE_DELETE_TESTERS に貼り付ける値）だけです
-- =====================================================================
begin;
do $$
declare
  v_email text := lower(trim('テスト用のメールアドレス'));
  v_id uuid; v_n int;
begin
  select count(*) into v_n from auth.users where lower(email) = v_email;
  if v_n <> 1 then raise exception '中止：このメールアドレスの会員が1人ではありません（% 人）', v_n; end if;
  select id into v_id from auth.users where lower(email) = v_email;
  if (select email_confirmed_at from auth.users where id = v_id) is null then raise exception '中止：メールアドレスの確認が済んでいません'; end if;
  if exists (select 1 from public.profiles where id = v_id and is_admin) then raise exception '中止：管理者アカウントはテストに使えません'; end if;
  if exists (select 1 from public.artists where user_id = v_id and lower(normalize(name, NFKC)) like '%noctera%') then raise exception '中止：NOCTERA を持つアカウントはテストに使えません'; end if;
  if exists (select 1 from aimuse_private.account_deletions where user_id <> v_id and status in ('pending', 'processing', 'failed')) then
    raise exception '中止：ほかの会員の退会申請があります。テストを始める前に運営で確認してください';
  end if;
  insert into aimuse_private.deletion_testers (user_id, note) values (v_id, '退会の検証用') on conflict (user_id) do nothing;
  update aimuse_private.settings set value = 'testers' where key = 'account_deletion_mode';
  perform set_config('aimuse.tester', v_id::text, false);
end $$;
commit;
select current_setting('aimuse.tester', true) as "テスト用アカウントの会員ID（AIMUSE_DELETE_TESTERS に貼り付け）",
       (select value from aimuse_private.settings where key = 'account_deletion_mode') as "受付",
       (select count(*) from aimuse_private.deletion_testers) as "許可リストの人数";
