# 退会機能の公開手順（iPhone だけで行えます・すべて無料枠）

退会のしくみ（データベース側）は本番に適用済みです（v1.9 r4）。残りは次の手順です。
各手順は運営者の承認後に行います。Claude に Supabase を接続している場合、手順2〜3・5は Claude が代わりに実行できます。

| 手順 | 内容 | 本番への影響 |
|---|---|---|
| 1 | SQL Editor で `migration_v1_12_purge_play_events.sql` を実行 | 完全削除の関数を1つ差し替え（その会員が聴いた再生記録も消す）。データは変わりません |
| 2 | Edge Function `account-delete-request`（`index.ts`・`request.js`・`supa.js`）を公開。**Verify JWT はオフ** | 追加のみ。受付スイッチが off の間は誰も申請できません |
| 3 | Edge Function `account-purge`（`index.ts`・`purge.js`・`supa.js`）を公開。**Verify JWT はオフ** | 追加のみ。合言葉と停止スイッチがあるため、呼ばれても何も消しません |
| 4 | Edge Functions → Secrets：`AIMUSE_ALLOWED_ORIGINS` = `https://aimusemusic.com`、`AIMUSE_DELETE_MODE` = `testers`、`AIMUSE_DELETE_TESTERS` = テスト用アカウントの会員ID | 設定のみ |
| 5 | SQL Editor で `cron_account_purge.sql` を実行し、表示された合言葉を Secrets の `AIMUSE_PURGE_SECRET` に登録 | 1日1回の呼び出しを登録（`AIMUSE_PURGE_ENABLED` が無い間は何もしない） |
| 6 | テスト用アカウントだけで検証（下記） | テスト用アカウントだけが対象 |
| 7 | 全員に公開：Secrets の `AIMUSE_DELETE_MODE` = `all`、SQL で受付 `all`、`config.js` の `accountDeletion: true` を main へ | 公開 |

## 手順6：テスト用アカウントでの検証
1. テスト用アカウントを1つ作る（メール確認まで済ませる。管理者にはしない）
2. SQL Editor：
   ```sql
   insert into aimuse_private.deletion_testers (user_id, note)
   select id, '退会の検証用' from auth.users where email = 'テスト用のメールアドレス';
   update aimuse_private.settings set value = 'testers' where key = 'account_deletion_mode';
   ```
3. iPhone で `https://aimusemusic.com/#account-delete-test` を開き、テスト用アカウントでログイン →
   設定 → 「アカウントを削除（退会）」→ パスワードを入れて申請 → 「退会手続き中」と出ることを確認
4. 「退会を取り消す」で元に戻ること → もう一度申請
5. 完全削除の確認（30日待たずに確認する場合だけ）：
   ```sql
   update aimuse_private.account_deletions set purge_after = now() - interval '1 minute'
   where user_id = (select id from auth.users where email = 'テスト用のメールアドレス') and status = 'pending';
   update aimuse_private.settings set value = 'on' where key = 'account_purge_enabled';
   ```
   Secrets の `AIMUSE_PURGE_ENABLED` = `true` にして、翌日 03:17 の実行（または Edge Functions の画面からの手動実行）を待つ
6. 確認：`select status, last_error from aimuse_private.account_deletions order by requested_at desc limit 3;` が `done`

## すぐに止める方法
- 申請の受付を止める：`update aimuse_private.settings set value = 'off' where key = 'account_deletion_mode';`
- 完全削除を止める：`update aimuse_private.settings set value = 'off' where key = 'account_purge_enabled';`
- 1日1回の呼び出しを止める：`select cron.unschedule('aimuse-account-purge');`

## 守られていること（テスト済み）
- 本人確認：サーバーでパスワードを照合（1時間に5回まで）。画面でも「同意」と「パスワード」が無いと押せない
- 最終確認：申請から30日間はいつでも取り消せる。期限を過ぎるまでは何も削除しない
- 管理者アカウントは申請できない（データベースと Edge Function の両方で拒否）
- 他の会員のデータは削除しない（他の会員のファイル・フォロー・再生記録・曲は残ることを確認）
- 申請中は、その会員の曲・プロフィール・プレイリスト・レビュー・フォローを公開画面から隠す
- 他の会員のプレイリストに入っていた退会者の曲は、完全削除のときに一覧から外れる（曲そのものが無くなるため）
