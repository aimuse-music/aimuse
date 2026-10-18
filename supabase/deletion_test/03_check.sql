-- =====================================================================
-- 退会テスト 3：結果の確認（読み取り専用）
-- ・テスト用アカウントの申請が done、ほかの会員の数が変わっていないことを確認します
-- =====================================================================
select
  (select coalesce(string_agg(status || coalesce('（' || left(last_error, 80) || '）', ''), ' / ' order by requested_at desc), '申請なし')
     from aimuse_private.account_deletions) as "退会の申請（新しい順）",
  (select count(*) from auth.users) as "会員数",
  (select count(*) from public.artists where lower(normalize(name, NFKC)) like '%noctera%') as "NOCTERA のアーティスト",
  (select count(*) from public.tracks t join public.artists a on a.id = t.artist_id where lower(normalize(a.name, NFKC)) like '%noctera%') as "NOCTERA の曲",
  (select count(*) from public.profiles where is_admin) as "管理者",
  (select value from aimuse_private.settings where key = 'account_deletion_mode') as "受付",
  (select value from aimuse_private.settings where key = 'account_purge_enabled') as "完全削除",
  (select count(*) from aimuse_private.deletion_testers) as "許可リストの人数（完全削除のあとは0）",
  (select status_code from net._http_response order by created desc limit 1) as "直近の呼び出しの応答（200なら正常）";
