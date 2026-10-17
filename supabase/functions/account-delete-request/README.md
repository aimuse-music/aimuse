# account-delete-request（退会の申請：パスワードをサーバーで照合）

**まだ本番には設定しないでください（運営者の承認後に行います）。**

## 何をするか
アプリの退会画面で入力されたパスワードを、サーバー側で Supabase の正式なログイン機能（signInWithPassword）を使って照合し、本人と確認できたときだけ退会を申請します。

1. 送られてきたログイン情報（JWT）を `auth.getUser` で確認し、会員を特定（照合するメールアドレスは必ず本人のもの）
2. 1時間に5回までの制限を確認（`account_reauth_allowed`）
3. パスワードを照合。失敗は `account_reauth_failed` で記録。照合用に作られたログインはすぐ終了
4. `account_request_deletion`（service_role 専用）で申請。公開中・審査待ちの曲は非公開になり、ファイル一覧を記録
5. ほかの端末のログインを終了（`auth.admin.signOut(jwt, "others")`）

## 設定（承認後・パソコン不要）
1. Supabase 管理画面 → Edge Functions → 「account-delete-request」を作成し、`index.ts` と `request.js` を貼り付けて公開
2. 「Verify JWT（ログイン情報の確認）」は **オン** のまま
3. Secrets に `AIMUSE_ALLOWED_ORIGINS` = `https://aimusemusic.com`（Cloudflare のプレビューで試す場合はそのURLもカンマ区切りで追加）

## 実際の環境で確認が必要なこと（未確認）
- `SUPABASE_ANON_KEY` が関数に自動で設定されるか（新しい形式のキーのプロジェクトでも使えるか）
- パスワード違いのとき、Supabase が 400 番台を返すこと（返さない場合は「一時的な障害」として扱われ、回数に数えません）
- `auth.admin.signOut(jwt, "others")` で、ほかの端末のログインが終了すること
- Supabase 側のログイン回数制限（同じ送信元からの連続ログイン）に、通常の利用でかからないこと
