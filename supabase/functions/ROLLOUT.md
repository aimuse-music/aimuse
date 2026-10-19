# 退会機能の公開手順（iPhone だけで行えます・すべて無料枠）

退会のしくみ（データベース側）は本番に適用済みです（v1.9 r4）。残りは次の手順です。各手順は運営者の承認後に行います。

**合言葉（秘密の値）は、誰も見ません。** 合言葉はデータベースの金庫（Vault）の中で自動的に作られます。完全削除の Edge Function は、
v1.12 の `purge_secret_matches` で金庫の値と照合します。チャット・SQL の結果・GitHub・Edge Function の設定画面のどこにも表示されません。
Edge Functions → Secrets に登録するのは、秘密ではない設定値（スイッチ・許可するサイト・テスト用の会員ID）だけです。

| 手順 | 内容 | 状態 |
|---|---|---|
| 1 | v1.12（完全削除で再生記録も消す・合言葉の照合）と pg_net の入れ直し：`prod_2026-10-19_finish.sql` | ✅ 2026-10-19 |
| 2 | Edge Function `account-delete-request`（Verify JWT オフ） | ✅ 2026-10-19 v2（受付スイッチをデータベースで確認） |
| 3 | Edge Function `account-purge`（Verify JWT オフ） | ✅ 2026-10-19 |
| 4 | `cron_account_purge.sql`：毎日 03:17 の呼び出し・金庫の合言葉 | ✅ 2026-10-19（停止中の応答 503 を確認） |
| 5 | v1.13 `migration_v1_13_deletion_gate.sql`：受付スイッチの確認関数（Edge Function の設定の代わり） | ✅ 2026-10-19 |
| 6 | 専用テストアカウント（表示名「退会テスト用」）で、申請・パスワード違い・取り消し・権限を確認 | ✅ 2026-10-19 |
| 7 | 受付を全員に：SQL で受付 `all`、PR「launch-switches」を main へ（`config.js` の `accountDeletion: true`・`pwa: true`） | 2026-10-19 |
| 8 | 完全削除を有効化：テスト用アカウントで `02`→`03` を実行して確認後、完全削除 `on` と Secrets の `AIMUSE_PURGE_ENABLED` = `true` | **運営者の承認待ち** |

**受付のスイッチはデータベースの1か所だけです**（`aimuse_private.settings` の `account_deletion_mode`：off / testers / all）。
Edge Function の Secrets の `AIMUSE_DELETE_MODE` は登録しません（登録した場合だけ、そちらが優先されます）。
`AIMUSE_ALLOWED_ORIGINS` も未設定のままで構いません（未設定なら `https://aimusemusic.com` だけを許可します）。
完全削除は、データベースの `account_purge_enabled` と Secrets の `AIMUSE_PURGE_ENABLED` の**両方**がオンのときだけ動きます。
各手順のあとは、`rollout_check_readonly.sql`（読み取り専用）で状態を確認できます。

## 完全削除の検証（手順8・運営者の承認後）
SQL はすべて `supabase/deletion_test/` にあります。どの SQL も、許可リスト以外の会員の申請があれば何も変更せずに中止します。

1. テスト用アカウント（表示名「退会テスト用」・許可リストに登録済み）で退会を申請（アプリの設定 →「アカウントを削除（退会）」）
2. Secrets の `AIMUSE_PURGE_ENABLED` = `true` にしてから、`02_fast_forward_and_purge.sql` を実行
   - テスト用アカウントの申請だけを「30日を過ぎた」状態にし、完全削除を1回だけ呼び出します
3. 1〜2分後に `03_check.sql`：申請が `done`、会員数が1減る、NOCTERA の曲数は変わらない、応答が 200
4. 公開を続ける場合は、完全削除 `on` のまま毎日の自動実行に任せます。止める場合は「すぐに止める方法」へ

## すぐに止める方法
- 申請の受付を止める：`update aimuse_private.settings set value = 'off' where key = 'account_deletion_mode';`（アプリの画面は「準備中」と表示します）
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
