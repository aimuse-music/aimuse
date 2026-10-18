# 退会機能の公開手順（iPhone だけで行えます・すべて無料枠）

退会のしくみ（データベース側）は本番に適用済みです（v1.9 r4）。残りは次の手順です。各手順は運営者の承認後に行います。
Claude に Supabase を接続している場合、★の手順は Claude が代わりに実行できます。

**合言葉（秘密の値）は、誰も見ません。** 合言葉はデータベースの金庫（Vault）の中で自動的に作られます。完全削除の Edge Function は、
v1.12 の `purge_secret_matches` で金庫の値と照合します。チャット・SQL の結果・GitHub・Edge Function の設定画面のどこにも表示されません。
Edge Functions → Secrets に登録するのは、秘密ではない設定値（スイッチ・許可するサイト・テスト用の会員ID）だけです。

| 手順 | 内容 | 本番への影響 |
|---|---|---|
| ★1 | SQL Editor で `migration_v1_12_purge_play_events.sql` を実行 | 完全削除の関数を1つ差し替え（その会員が聴いた再生記録も消す）と、合言葉の照合の関数を追加。データは変わりません |
| ★2 | Edge Function `account-delete-request`（`index.ts`・`request.js`・`supa.js`）を公開。**Verify JWT はオフ** | 追加のみ。受付が off の間は、誰も申請できません |
| ★3 | Edge Function `account-purge`（`index.ts`・`purge.js`・`supa.js`）を公開。**Verify JWT はオフ** | 追加のみ。合言葉と停止スイッチがあるため、呼ばれても何も消しません |
| ★4 | SQL Editor で `cron_account_purge.sql` を実行（合言葉の作成と、1日1回の呼び出しの登録。結果には「1」が並ぶだけ） | `AIMUSE_PURGE_ENABLED` が無い間は何もしません |
| 5 | Edge Functions → Secrets に `AIMUSE_ALLOWED_ORIGINS` = `https://aimusemusic.com`、`AIMUSE_DELETE_MODE` = `testers` を登録 | 設定のみ |
| 6 | 専用テストアカウントで検証（下記） | テスト用アカウントだけが対象 |
| 7 | 全員に公開：Secrets の `AIMUSE_DELETE_MODE` = `all`、SQL で受付 `all`・完全削除 `on`、`config.js` の `accountDeletion: true` を main へ | 公開 |

各手順のあとは、`rollout_check_readonly.sql`（読み取り専用）で状態を確認できます。

## 手順6：専用テストアカウントでの検証（本番の会員には影響しません）
SQL はすべて `supabase/deletion_test/` にあります。どの SQL も、許可リスト以外の会員の申請があれば何も変更せずに中止します。

1. 専用テストアカウントを作る：アプリで会員登録し、確認メールのリンクを開く（管理者にはしない。NOCTERA は使わない）
2. `01_register_tester.sql`：1行目のメールアドレスを書き換えて実行 → 表示された会員ID を Secrets の `AIMUSE_DELETE_TESTERS` に登録
3. iPhone で `https://aimusemusic.com/#account-delete-test` を開き、テスト用アカウントでログイン → 設定 → 「アカウントを削除（退会）」→ パスワードを入れて申請
   - パスワードを間違えると申請できないこと、「退会手続き中」と表示されることを確認
4. 「退会を取り消す」→ 元に戻ることを確認 → もう一度申請
5. Secrets の `AIMUSE_PURGE_ENABLED` = `true` にしてから、`02_fast_forward_and_purge.sql` を実行
   - テスト用アカウントの申請だけを「30日を過ぎた」状態にし、完全削除を1回だけ呼び出します
6. 1〜2分後に `03_check.sql`：申請が `done`、会員数が1減る、NOCTERA の曲数は変わらない、応答が 200
7. テスト用アカウントでログインできないことを確認
8. `04_finish_test.sql` で受付・完全削除を off に戻す（公開する場合は手順7へ）

## すぐに止める方法
- 申請の受付を止める：`update aimuse_private.settings set value = 'off' where key = 'account_deletion_mode';`
- 完全削除を止める：`update aimuse_private.settings set value = 'off' where key = 'account_purge_enabled';`（または Secrets の `AIMUSE_PURGE_ENABLED` を削除）
- 1日1回の呼び出しを止める：`select cron.unschedule('aimuse-account-purge');`

## 守られていること（テスト済み）
- 本人確認：サーバーでパスワードを照合する（1時間に5回まで）。画面でも「同意」と「パスワード」が無いと押せない
- 最終確認：申請から30日間はいつでも取り消せる。期限を過ぎるまでは何も削除しない
- 管理者アカウントは申請できない（データベースと Edge Function の両方で拒否）
- 他の会員のデータは削除しない（他の会員のファイル・フォロー・再生記録・曲が残ることを確認）
- 申請中は、その会員の曲・プロフィール・プレイリスト・レビュー・フォローを公開画面から隠す
- 他の会員のプレイリストに入っていた退会者の曲は、完全削除のときに一覧から外れる（曲そのものが無くなるため）
