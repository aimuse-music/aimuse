# AIMUSE

AIで制作された楽曲だけを集めた音楽配信サービス。

## 構成（すべて無料プランで運用）

| 役割 | サービス |
|---|---|
| 会員ログイン・データベース・音源/画像保存 | Supabase（Auth / Postgres / Storage） |
| コード保存 | GitHub |
| 公開（ホスティング） | Cloudflare Pages |

## フォルダ

- `public/` … 公開されるサイト本体（Cloudflare Pages の出力ディレクトリ）
  - `index.html` … アプリ本体（React + htm、ビルド不要）
  - `config.js` … Supabase の接続設定（Project URL と公開用キー）
  - `_headers` … Cloudflare Pages 用のHTTPヘッダー設定
- `supabase/aimuse_schema.sql`（v1.5 最終版 r2）… テーブル・アクセスルール（RLS）・Storageバケットの構築SQL（会員・アーティスト・楽曲・お気に入り・フォロー・レビュー・通報）
- `supabase/production_checks.sql`（r3）… 本番環境の確認用SQL（読み取り専用・19項目）

## データの扱い

- 楽曲の公開範囲：審査で承認された曲（status = public）だけが誰でも閲覧・再生可能。審査待ち・却下・非公開の曲は投稿者本人と管理者のみ閲覧可能
- 投稿：ログイン会員のみ。音源は `audio` バケット、ジャケット画像は `covers` バケットの「会員ID/楽曲ID.拡張子」に保存
- 音源・画像は非公開バケット。アプリは期限付きURL（署名付きURL・1時間）で再生する。公開中の曲は誰でも、それ以外は投稿者本人と管理者だけがURLを発行できる
- 再生数：同じ人×同じ曲は1時間に1回まで（ログイン中は会員ID、未ログインはIPアドレスのハッシュで判定）。再生記録は2日で削除
- 乱用防止：審査待ちは1人10曲まで、保存ファイルは1人200個まで
- 審査・通報対応・公開切替・削除：管理者（profiles.is_admin = true）のみ
- 安全な削除：公開中の曲は削除不可（先に非公開）。削除内容は30日間 aimuse_private.track_deletions に保存され、管理者が admin_restore_track で復元可能。音源・画像は即時削除せず、30日後に孤立ファイルとして整理
- お気に入り・フォローは現在アプリでは端末内（localStorage）に保存（DB側のテーブルは用意済み）
- 架空のデータは入れていない

## 管理者の設定

最初の管理者は、会員登録後に Supabase の SQL で設定する：

```sql
update public.profiles set is_admin = true
where id = (select id from auth.users where email = '管理者のメールアドレス');
```

## Cloudflare Pages の設定値

- Framework preset：None
- Build command：（空欄）
- Build output directory：`public`

## Supabase の認証設定

Authentication → URL Configuration の Site URL と Redirect URLs に、公開URL（例：`https://aimuse.pages.dev`）を登録する（確認メール・パスワード再設定のリンク先になる）。

## 無料プランの主な上限（2026年10月時点）

- Supabase Free：プロジェクト2つまで、DB 500MB、ファイル保存 1GB、1ファイル50MBまで、転送量 5GB/月、1週間アクセスがないと一時停止
- Cloudflare Pages Free：ビルド 500回/月、1ファイル 25MiB まで

## 削除した楽曲の復元（SQL Editor）

```sql
select * from public.admin_list_deleted_tracks();          -- 30日以内に削除した曲の一覧
select public.admin_restore_track('deletion_id をここに');   -- 復元（非公開の状態で戻ります）
```
