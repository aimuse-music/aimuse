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
- `supabase/migration_v1_6_profile.sql`（v1.6）… プロフィール編集の追加SQL（追加のみ・再実行可。構築SQLの後に実行）
- `supabase/migration_v1_7_follow_lists.sql`（v1.7）… フォロワー・フォロー中一覧の追加SQL（追加のみ・再実行可。v1.6 の後に実行）
- `supabase/production_checks.sql`（r5）… 本番環境の確認用SQL（読み取り専用・23項目。v1.7 実行後の状態を確認）

## データの扱い

- 楽曲の公開範囲：審査で承認された曲（status = public）だけが誰でも閲覧・再生可能。審査待ち・却下・非公開の曲は投稿者本人と管理者のみ閲覧可能
- 投稿：ログイン会員のみ。音源は `audio` バケット、ジャケット画像は `covers` バケットの「会員ID/楽曲ID.拡張子」に保存
- 音源・画像は非公開バケット。アプリは期限付きURL（署名付きURL・1時間）で再生する。公開中の曲は誰でも、それ以外は投稿者本人と管理者だけがURLを発行できる
- 再生数：実際に音声が30秒流れたら1回（30秒未満の曲は長さの半分）。一時停止・シーク・読み込み待ち・再生失敗・短時間のスキップは入れない（画面側の `makeListenMeter`）。そのうえで、同じ人×同じ曲は1時間に1回まで（ログイン中は会員ID、未ログインはIPアドレスのハッシュで判定）。再生記録は2日で削除
- 乱用防止：審査待ちは1人10曲まで、保存ファイルは1人200個まで
- 審査・通報対応・公開切替・削除：管理者（profiles.is_admin = true）のみ
- 安全な削除：公開中の曲は削除不可（先に非公開）。削除内容は30日間 aimuse_private.track_deletions に保存され、管理者が admin_restore_track で復元可能。音源・画像は即時削除せず、30日後に孤立ファイルとして整理
- お気に入り・フォロー：Supabase の favorites / follows に会員ごと（user_id = auth.uid()）に保存。RLSで本人の行だけ取得・追加・削除できる。フォロワー数は artist_follower_count で人数のみ取得
- 公開版の更新：`public/index.html` の `const BUILD = "..."` を公開のたびに変更する。開いたままの古い画面は、ログイン・ログアウト時やアプリに戻ったとき（再生中を除く）に自動で最新版へ読み込み直される
- 架空のデータは入れていない

## プロフィール編集（v1.6）

- マイページ →「プロフィールを編集」：アイコン・背景画像（切り抜き・拡大縮小）、表示名、アーティスト名、自己紹介
- 画像は端末内で JPEG に変換・縮小（アイコン 512×512、背景 1500×500）。撮影場所などの情報は残らない
- 保存先は公開の保存場所 `avatars`（本人フォルダのみ・1人4ファイル・2MBまで・JPEG/PNG/WebP）
- 保存の順番：新しい画像を保存 → `set_my_profile_image` で設定 → 成功後に古い画像を削除（失敗しても既存の画像は残る）
- 他の人に見えるのはアーティスト名・アイコン・背景・自己紹介（`public_artist_profiles` は公開中の曲があるアーティストの画像の場所だけを返す）。表示名は本人と管理者のみ
- アーティスト名の変更は `rename_my_artist`（禁止語・他の会員と同じ名前・見えない文字は不可、24時間に3回まで、履歴を `aimuse_private.artist_name_history` に保存）
- 管理者：アーティストページで画像を初期化、管理者画面「名義変更」で履歴の確認と元の名前への変更

## フォロワー・フォロー中一覧（v1.7）

- アーティストページの「フォロワー」「フォロー中」、マイページの「フォロー」「フォロワー」をタップで一覧（30件ずつ・「さらに表示」）
- 名前・アイコンが出るのは公開中の曲があるアーティストだけ。リスナーは人数のみ（会員ID・表示名・アイコンは返さない）
- 利用停止中の会員は一覧にも人数にも含めない（判定は is_visible_member に集約。退会手続き中の除外もここに追加予定）
- 未ログインでも閲覧可、フォロー操作はログインが必要。新しいテーブルは作らず既存の follows を使用

## はじめての方への案内（第3段階）

- ホームの「AIMUSEへようこそ！」は、未ログインで、閉じていない端末だけに表示（一度ログインした端末では表示しない）
- 「使い方」ページはログイン不要（`/#guide`）。ログイン画面・マイページ下部・案内から開ける
- 聴く・探すは登録不要。お気に入り・フォロー・投稿のときだけログインを案内（会員登録は無料と表示）

## 規約・ポリシー（草案）

- 利用規約・プライバシーポリシー・楽曲投稿・著作権ガイドラインは `public/index.html` の `LEGAL_DOCS` に記載（法律専門家による確認前の草案）
- 画面上で色付き表示される「【要確認：…】」は、正式公開までに確定させる項目
- ログイン画面（新規登録・パスワード再設定を含む）とマイページの下部から閲覧可能。ログイン不要
- 直接開くURL：`/#terms`（利用規約）・`/#privacy`（プライバシーポリシー）・`/#guidelines`（投稿ガイドライン）
- 実装やデータの扱いを変更したら、プライバシーポリシーの記載も合わせて更新する

## アクセス解析（v1.17・管理者のみ）

- 管理者画面 →「アクセス解析」：今日・昨日・過去7日・過去30日の訪問者（推計）・表示数・再生数、日別（30日）・月別（12か月）の推移、画面別の表示数、楽曲別の再生ランキング（7日・30日・90日・全期間）
- すべて Supabase の中で集計（外部の解析サービスは使わない・無料枠内）。SQL：`supabase/migration_v1_17_analytics.sql`、元に戻す：`supabase/rollback/rollback_v1_17.sql`、確認：`supabase/v1_17_check_readonly.sql`、手順：`docs/analytics-rollout.md`
- 訪問者は端末のブラウザが作る匿名ID（localStorage `aimuse.vid`）で数える推計値。記録は匿名IDを秘密の値で変換した値・画面の種類・日時だけ（会員ID・メール・IPは保存しない）
- 管理者の除外：ログイン中の管理者は数えない。管理者でログインした端末は `aimuse.adminDevice` を記録し、サーバー側の除外リストにも入れる（それまでの分も集計から外れる）
- 表示数：同じ端末×同じ種類の画面は30分に1回。水増し対策：接続元ごとに1時間600件・新しい匿名ID 30個まで、1端末1日200件まで（接続元の変換値は2時間で削除）
- 再生数：アプリは `count_play` を呼ぶ（数え方は `increment_plays` と同じ。未作成のときだけ `increment_plays`）。数えたときだけ日別の集計に1を足す（管理者の再生は日別に入れない）。公開中の再生数（tracks.plays）の数え方は変更なし
- 生の記録は90日で削除し、日別・月別の集計値だけを残す（pg_cron で毎日 0:20、管理画面を開いたときにも集計）
- 停止：`config.js` の `features.analytics` を false（画面の表示を送らない）、または `aimuse_private.settings` の `analytics_enabled` を off（サーバー側で記録しない）

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
