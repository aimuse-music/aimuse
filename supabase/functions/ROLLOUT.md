# 退会機能の公開手順（iPhone だけで行えます・すべて無料枠）

退会のしくみ（データベース側）は本番に適用済みです（v1.9 r4）。残りは次の手順です。各手順は運営者の承認後に行います。
Claude に Supabase を接続している場合、★の手順は Claude が代わりに実行できます。

**合言葉（秘密の値）は、誰も見ません。** 合言葉はデータベースの金庫（Vault）の中で自動的に作られます。完全削除の Edge Function は、
v1.12 の `purge_secret_matches` で金庫の値と照合します。チャット・SQL の結果・GitHub・Edge Function の設定画面のどこにも表示されません。
Edge Functions → Secrets に登録するのは、秘密ではない設定値（スイッチ・許可するサイト・テスト用の会員ID）だけです。

| 手順 | 内容 | 本番への影響 |
|---|---|---|
| ★1 ⏳ | v1.12：照合の関数 `purge_secret_matches` は 2026-10-19 に適用済み。残り（完全削除の手順に1行追加）は運営者が SQL Editor で `supabase/prod_2026-10-19_finish.sql` を実行（Claude の接続からは削除を含む変更を実行できないため） | 関数の差し替えのみ。データは変わりません |
| ★2 ✅ 2026-10-19 公開済み | Edge Function `account-delete-request`（`index.ts`・`request.js`・`supa.js`）を公開。**Verify JWT はオフ** | 追加のみ。受付が off の間は、誰も申請できません |
| ★3 ✅ 2026-10-19 公開済み | Edge Function `account-purge`（`index.ts`・`purge.js`・`supa.js`）を公開。**Verify JWT はオフ** | 追加のみ。合言葉と停止スイッチがあるため、呼ばれても何も消しません |
| ★4 ✅ 2026-10-19 設定済み | `cron_account_purge.sql`：pg_cron・pg_net の有効化、金庫の合言葉の作成、毎日 03:17 の呼び出しの登録。呼び出しの確認済み（正しい合言葉 → 「停止中」503、違う合言葉 → 403）。pg_net の場所（extensions）への入れ直しは ★1 の SQL に含む | `AIMUSE_PURGE_ENABLED` が無い間、完全削除のスイッチが off の間は何もしません |
| 5 | 専用テストアカウントを作る（表示名「退会テスト用」）→ ★`01_register_tester.sql`（許可リストに登録・受付は off のまま）→ ★Secrets の `AIMUSE_DELETE_TESTERS` に会員ID を登録 | 許可リストへの1行の追加のみ |
| 6 | 専用テストアカウントで検証（下記） | テスト用アカウントだけが対象 |
| 7 | 全員に公開：Secrets の `AIMUSE_DELETE_MODE` = `all`、SQL で受付 `all`・完全削除 `on`、PR「launch-switches」（`config.js` の `accountDeletion: true`・`pwa: true`）を main へ | 公開 |

`AIMUSE_ALLOWED_ORIGINS` は未設定のままで構いません（未設定なら `https://aimusemusic.com` だけを許可します）。
各手順のあとは、`rollout_check_readonly.sql`（読み取り専用）で状態を確認できます。

## 手順6：専用テストアカウントでの検証（本番の会員には影響しません）
SQL はすべて `supabase/deletion_test/` にあります。どの SQL も、許可リスト以外の会員の申請があれば何も変更せずに中止します。

1. ★`01b_start_testers.sql`（受付を「テスト用アカウントだけ」にする）と、Secrets の `AIMUSE_DELETE_MODE` = `testers`（運営者の承認後）
2. iPhone で `https://aimusemusic.com/#account-delete-test` を開き、テスト用アカウントでログイン → 設定 → 「アカウントを削除（退会）」→ パスワードを入れて申請
   - パスワードを間違えると申請できないこと、「退会手続き中」と表示されることを確認
3. 「退会を取り消す」→ 元に戻ることを確認 → もう一度申請
4. Secrets の `AIMUSE_PURGE_ENABLED` = `true` にしてから、`02_fast_forward_and_purge.sql` を実行（運営者の承認後）
   - テスト用アカウントの申請だけを「30日を過ぎた」状態にし、完全削除を1回だけ呼び出します
5. 1〜2分後に `03_check.sql`：申請が `done`、会員数が1減る、NOCTERA の曲数は変わらない、応答が 200
6. テスト用アカウントでログインできないことを確認
7. `04_finish_test.sql` で受付・完全削除を off に戻し、Secrets の `AIMUSE_PURGE_ENABLED` を削除（公開する場合は手順7へ）

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

## 元に戻す方法（Edge Function）
- Supabase の画面 → Edge Functions → 関数を選ぶ → 削除。関数が無くても、アプリは「準備中」と表示するだけで、他の機能には影響しません
