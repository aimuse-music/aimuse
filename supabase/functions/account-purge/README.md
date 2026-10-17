# account-purge（退会から30日後の完全削除）

**まだ本番には設定しないでください（運営者の承認後に行います）。**

## 何をするか
退会申請から30日を過ぎたアカウントを、次の順番で削除します。各手順はデータベース側で「処理番号」と「期限」を確認してから実行するため、同時に2回動いても同じ申請を二重に処理しません。

1. 対象を1件取り出す（`account_purge_claim`）
2. 音源・ジャケット・アイコン・背景画像を Storage から削除し、**実際に無くなったファイルだけ**を「削除済み」に記録（`account_purge_mark_files`）
3. ファイルがすべて無いことを確認してから、曲と削除記録（30日復元用）を削除（`account_purge_db`）
4. ログイン情報（会員）を削除（`auth.admin.deleteUser`）。プロフィール・アーティスト・お気に入り・フォロー・レビュー・通報は自動で消えます
5. 会員が実際に無いことを確認してから「完了」（`account_purge_finish`）

## 失敗したとき
- どの手順で失敗しても「完了」にはなりません。会員は非公開・操作不可のままです
- 失敗は `last_error` に記録し、**1時間後の実行で続きから**再開します（済んだ手順は飛ばします）
- 10回失敗すると `failed`（運営の確認待ち）になり、自動の再試行を止めます
- 確認待ちの一覧（SQL Editor）：
  `select id, status, attempts, last_error, requested_at from aimuse_private.account_deletions where status = 'failed';`
- 原因を直したあと、再開させる（SQL Editor）：
  `update aimuse_private.account_deletions set status = 'processing', attempts = 0, locked_until = null where id = '<id>';`

## 設定（承認後・パソコン不要の手順）
1. Supabase の管理画面 → Edge Functions → 新しい関数「account-purge」を作成し、`index.ts` と `purge.js` の2ファイルを貼り付けて公開
   （管理画面のエディタで2ファイルを扱えない場合は、`purge.js` の中身を `index.ts` に貼り付けて1ファイルにします）
2. Edge Functions → Secrets に `AIMUSE_PURGE_SECRET`（32文字以上のランダムな文字列）を登録
3. 関数の設定で「JWT の確認（Verify JWT）」をオフ（合言葉で守るため）
4. Integrations → Cron で1日1回、この関数を POST で呼び出す設定を作成し、ヘッダー `x-aimuse-purge-secret` に同じ合言葉を設定

管理用の秘密キー（service_role）は Supabase が関数の中にだけ自動で設定します。ブラウザ・GitHub・config.js には入れません。

## 費用の目安
1日1回の実行は、Edge Functions の無料枠（月50万回）・Cron（無料）の範囲内です。
