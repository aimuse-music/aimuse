-- =====================================================================
-- v1.17 アクセス解析の確認（読み取り専用。何も変更しません）
-- migration_v1_17_analytics.sql の実行後に SQL Editor で実行し、「結果」がすべて OK か確認してください
-- （実行前に流すと 1〜8 は NG になります。10 の再生数の合計は、実行の前後で同じになることを確認してください）
-- =====================================================================
with fn(name, sig) as (values
  ('analytics_track',        'public.analytics_track(uuid,text)'),
  ('count_play',             'public.count_play(uuid,uuid)'),
  ('analytics_exclude_device','public.analytics_exclude_device(uuid)'),
  ('admin_analytics',        'public.admin_analytics()'),
  ('admin_analytics_ranking','public.admin_analytics_ranking(integer,integer)'),
  ('analytics_maintain',     'aimuse_private.analytics_maintain(boolean)'),
  ('analytics_note_play',    'aimuse_private.analytics_note_play(uuid,uuid)'),
  ('play_count_core',        'aimuse_private.play_count_core(uuid)'),
  ('analytics_vid_hash',     'aimuse_private.analytics_vid_hash(uuid)'),
  ('analytics_ip_bucket',    'aimuse_private.analytics_ip_bucket()')
),
f as (
  select name, to_regprocedure(sig) as oid,
         coalesce(has_function_privilege('anon', to_regprocedure(sig), 'execute'), false) as anon_x,
         coalesce(has_function_privilege('authenticated', to_regprocedure(sig), 'execute'), false) as auth_x
  from fn
),
t(name) as (values ('analytics_views'),('analytics_excluded'),('analytics_rate'),('analytics_rate_ids'),
                   ('analytics_daily'),('analytics_monthly'),('analytics_plays_daily')),
tt as (
  select t.name, c.oid, c.relrowsecurity as rls,
         case when c.oid is null then false
              else has_table_privilege('anon', c.oid, 'select,insert,update,delete')
                or has_table_privilege('authenticated', c.oid, 'select,insert,update,delete') end as api
  from t left join pg_class c on c.relname = t.name
       and c.relnamespace = (select oid from pg_namespace where nspname = 'aimuse_private')
),
cronjob as (
  select case when to_regclass('cron.job') is null then null
    else (xpath('/row/n/text()', query_to_xml(
      'select count(*) as n from cron.job where jobname = ''aimuse-analytics-maintain'' and active and command like ''%analytics_maintain%''',
      false, true, '')))[1]::text::int end as n
),
checks(no, item, ok, detail) as (
  select 1, '解析の表が7つある（aimuse_private）',
    (select count(oid) from tt) = 7, (select count(oid)::text || '/7' from tt)
  union all
  select 2, '解析の表はアクセスルール有効・アプリから直接読み書きできない',
    (select bool_and(coalesce(rls, false) and not api) from tt), null
  union all
  select 3, '新しい関数が10個ある',
    (select count(oid) from f) = 10, (select count(oid)::text || '/10' from f)
  union all
  select 4, '未ログインで実行できる新しい関数は analytics_track・count_play だけ',
    (select string_agg(name, ',' order by name) from f where anon_x) = 'analytics_track,count_play',
    (select string_agg(name, ',' order by name) from f where anon_x)
  union all
  select 5, '集計の関数は会員（ログイン中）だけが呼べる（中で管理者か確認）',
    (select bool_and(auth_x and not anon_x) from f where name in ('admin_analytics','admin_analytics_ranking','analytics_exclude_device')), null
  union all
  select 6, '内部の関数はアプリから呼べない',
    (select bool_and(oid is not null and not anon_x and not auth_x) from f where name in ('analytics_maintain','analytics_note_play','play_count_core','analytics_vid_hash','analytics_ip_bucket')), null
  union all
  select 7, '解析の設定（秘密の値・記録オン・計測開始日）',
    coalesce((select length(value) = 64 from aimuse_private.settings where key = 'analytics_salt'), false)
    and coalesce((select value = 'on' from aimuse_private.settings where key = 'analytics_enabled'), false)
    and exists (select 1 from aimuse_private.settings where key = 'analytics_started'),
    (select value from aimuse_private.settings where key = 'analytics_started')
  union all
  select 8, '毎日の集計（aimuse-analytics-maintain）が登録済み',
    coalesce((select n from cronjob), 0) = 1, coalesce((select n::text from cronjob), 'pg_cron なし')
  union all
  select 9, '既存の再生数の関数（increment_plays）は今までどおり未ログイン・会員が実行できる',
    coalesce(has_function_privilege('anon', to_regprocedure('public.increment_plays(uuid)'), 'execute'), false)
    and coalesce(has_function_privilege('authenticated', to_regprocedure('public.increment_plays(uuid)'), 'execute'), false), null
  union all
  select 10, '参考：公開中の再生数の合計（実行の前後で同じこと）・楽曲数',
    true, (select coalesce(sum(plays), 0)::text || '回 / ' || count(*)::text || '曲' from public.tracks)
  union all
  select 11, 'aimuse_private は今までどおりアプリから使えない',
    not has_schema_privilege('anon', 'aimuse_private', 'USAGE') and not has_schema_privilege('authenticated', 'aimuse_private', 'USAGE'), null
)
select no as "番号", item as "確認項目", case when ok then 'OK' else 'NG' end as "結果", coalesce(detail, '') as "詳細"
from checks order by no;
