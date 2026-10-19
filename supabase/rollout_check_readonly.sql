-- =====================================================================
-- 退会機能の公開準備の確認（読み取り専用。何も変更しません）
-- ROLLOUT.md の各手順のあとに SQL Editor で実行し、「結果」がすべて OK か確認してください
-- =====================================================================
with s as (
  select coalesce((select value from aimuse_private.settings where key = 'account_deletion_mode'), '未設定') as mode,
         coalesce((select value from aimuse_private.settings where key = 'account_purge_enabled'), '未設定') as purge
),
cronjob as (
  select case when to_regclass('cron.job') is null then null
    else (xpath('/row/n/text()', query_to_xml(
      'select count(*) as n from cron.job where jobname = ''aimuse-account-purge'' and active and command like ''%/functions/v1/account-purge%''',
      false, true, '')))[1]::text::int end as n
),
checks(no, item, ok, detail) as (
  select 1, '手順1：v1.12（完全削除で再生記録も消す）が適用済み',
    position('play_events' in coalesce((select prosrc from pg_proc where oid = to_regprocedure('public.account_purge_db(uuid,uuid)')), '')) > 0,
    null
  union all
  select 2, '完全削除の関数はサーバー側（service_role）だけが実行できる',
    not has_function_privilege('anon', 'public.account_purge_db(uuid,uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.account_purge_db(uuid,uuid)', 'execute')
    and has_function_privilege('service_role', 'public.account_purge_db(uuid,uuid)', 'execute'),
    null
  union all
  select 9, '手順1：合言葉の照合の関数はサーバー側（service_role）だけが実行できる',
    to_regprocedure('public.purge_secret_matches(text)') is not null
    and not has_function_privilege('anon', 'public.purge_secret_matches(text)', 'execute')
    and not has_function_privilege('authenticated', 'public.purge_secret_matches(text)', 'execute')
    and has_function_privilege('service_role', 'public.purge_secret_matches(text)', 'execute'),
    null
  union all
  select 3, '手順4：1日1回の呼び出し（pg_cron）が登録済み',
    coalesce((select n from cronjob), 0) = 1,
    case when to_regclass('cron.job') is null then 'pg_cron が未導入' else (select n from cronjob)::text || '件' end
  union all
  select 4, '手順4：合言葉が金庫（Vault）にある（値は表示しません）',
    to_regclass('vault.secrets') is not null
    and (xpath('/row/n/text()', query_to_xml('select count(*) as n from vault.secrets where name = ''aimuse_purge_secret''', false, true, '')))[1]::text::int = 1,
    null
  union all
  select 10, '手順4：pg_net が Supabase 推奨の場所（extensions）にある',
    coalesce((select extnamespace = to_regnamespace('extensions') from pg_extension where extname = 'pg_net'), false),
    coalesce((select extnamespace::regnamespace::text from pg_extension where extname = 'pg_net'), 'pg_net が未導入')
  union all
  select 5, '受付・完全削除のスイッチ（検証中は「testers / off→on」、公開後は「all / on」）',
    (select mode from s) in ('off', 'testers', 'all') and (select purge from s) in ('off', 'on'),
    '受付=' || (select mode from s) || ' / 完全削除=' || (select purge from s)
  union all
  select 6, '検証用の許可リスト（testers のときは1人以上・管理者を含まない）',
    (select mode from s) <> 'testers'
    or ((select count(*) from aimuse_private.deletion_testers) >= 1
        and not exists (select 1 from aimuse_private.deletion_testers t join public.profiles p on p.id = t.user_id where p.is_admin)),
    (select count(*)::text || '人' from aimuse_private.deletion_testers)
  union all
  select 7, '失敗が続いて止まった退会処理がない',
    not exists (select 1 from aimuse_private.account_deletions where status = 'failed'),
    coalesce((select string_agg(status || ' ' || n, ' / ' order by status)
              from (select status, count(*) as n from aimuse_private.account_deletions group by status) x), '申請なし')
  union all
  select 8, '管理者は退会手続き中になっていない',
    not exists (select 1 from aimuse_private.account_deletions d join public.profiles p on p.id = d.user_id
                where p.is_admin and d.status in ('pending', 'processing', 'failed')),
    null
)
select no as "番号", item as "確認項目", case when ok then 'OK' else '要確認' end as "結果", coalesce(detail, '') as "詳細"
from checks order by no;
