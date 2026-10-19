# account-delete-request（退会の申請：パスワードをサーバーで照合）

**まだ本番には設定しないでください（運営者の承認後に行います）。**

## 何をするか
アプリの退会画面で入力されたパスワードを、サーバー側で照合し、本人と確認できたときだけ退会を申請します。

1. 送られてきたログイン情報（JWT）を、Supabase の認証サーバー（`/auth/v1/user`）で確認して会員を特定（公開用キーだけの呼び出しは何もしない）
2. 受付スイッチを確認：通常はデータベースの `account_deletion_mode`（v1.13 の `account_deletion_gate`。off＝誰も申請できない／testers＝許可リストの会員だけ／all＝全員。確認できないときは受け付けない）。Secrets に `AIMUSE_DELETE_MODE` を登録した場合だけ、そちらを優先
3. 1時間に5回までの枠を1つ予約（`account_reauth_begin`。同時に送られても5回を超えない。結果は `account_reauth_end` で記録）
4. パスワードを Supabase の正式なログイン機能（`/auth/v1/token`）で照合。照合用のログインはすぐ終了
5. `account_request_deletion`（秘密キー専用）で申請。**データベース側でも**受付スイッチと許可リストを確認
6. ほかの端末のログインを終了（`/auth/v1/logout?scope=others`）

## キー（新しい形式に対応）
- Supabase が自動で設定する `SUPABASE_SECRET_KEYS`・`SUPABASE_PUBLISHABLE_KEYS`（JSON。`default` を使用）を読みます。無い場合は旧形式の `SUPABASE_SERVICE_ROLE_KEY`・`SUPABASE_ANON_KEY`
- 新しい形式のキーは `apikey` ヘッダーだけで送ります（`Authorization` に入れると拒否されるため）
- 外部のライブラリは使いません（`supa.js` が Supabase の公開 API を直接呼びます。account-purge と同じ内容）

## 設定（承認後・パソコン不要）
1. Supabase 管理画面 → Edge Functions → 「account-delete-request」を作成し、`index.ts`・`request.js`・`supa.js` を貼り付けて公開
2. 関数の設定で **「Enforce JWT verification（Verify JWT）」をオフ**（新しい形式のキーでは使えないため。本人確認は関数の中で行う）
3. Secrets：登録は不要です（許可するサイトは未設定なら `https://aimusemusic.com`、受付はデータベースのスイッチに従う）
4. データベース側のスイッチ（SQL Editor）：
   ```sql
   -- 検証を始めるとき（テスト用アカウントだけ）
   insert into aimuse_private.deletion_testers (user_id, note)
   select id, 'テスト用' from auth.users where email = 'テスト用のメールアドレス';
   update aimuse_private.settings set value = 'testers' where key = 'account_deletion_mode';
   -- すぐに止めるとき
   update aimuse_private.settings set value = 'off' where key = 'account_deletion_mode';
   ```

## 実際の環境で確認が必要なこと（未確認）
- 新しい形式の秘密キーで、`/rest/v1/rpc`・`/auth/v1/admin` が使えること（偽のゲートウェイでは確認済み）
- パスワード違いのとき 400 番台が返ること、`/logout?scope=others` でほかの端末のログインが終了すること
