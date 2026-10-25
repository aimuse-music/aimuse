# アクセス解析（v1.17）本番導入の手順

本番の変更は、運営者の承認後に行います。順番は **SQL → 画面（main への反映）** です。
画面は SQL が未実行でも今までどおり動き（再生数は従来の `increment_plays` で数える）、画面の表示は送りません。

## 0. 事前の確認（読み取り専用）
1. Supabase → SQL Editor で `supabase/v1_17_check_readonly.sql` を実行する
2. 10番の「公開中の再生数の合計」をメモする（1〜8 はまだ NG で正常）

## 1. SQL の実行（本番データベースの変更）
1. `supabase/migration_v1_17_analytics.sql` の内容を確認する（いつもどおり ChatGPT でも確認）
2. SQL Editor に全文を貼り付けて実行する（追加のみ・何度実行しても同じ結果）
3. もう一度 `supabase/v1_17_check_readonly.sql` を実行し、1〜11 がすべて OK、10番の再生数の合計が 0. と同じことを確認する

## 2. 画面の反映
1. プライバシーポリシーの改定日（`public/index.html` の `PRIVACY_ANALYTICS_DATE`）を公開する日に合わせる
2. 開発ブランチ `analytics` の Pull Request を main にマージする（Cloudflare Pages が自動で公開）

## 3. 動作の確認
1. 管理者でログイン → マイページ → 管理者画面 →「アクセス解析」が開き、エラーが出ないこと（最初はすべて0）
2. 管理者でログインしたことがない端末（例：別のブラウザのプライベートモード）で aimusemusic.com を開き、ホーム・検索を表示する
3. 管理者画面の「最新の状態に更新」を押し、今日の表示数・訪問者（推計）が増えていること
4. 管理者の端末で画面を移動しても数が増えないこと

## 止める・元に戻す
- 画面の表示の送信だけ止める：`public/config.js` の `analytics: false`（main に反映）
- サーバー側で記録を止める：`update aimuse_private.settings set value = 'off' where key = 'analytics_enabled';`
- すべて元に戻す：`supabase/rollback/rollback_v1_17.sql`（解析の記録と集計値は消えます。楽曲・会員・再生数は変わりません）→ main の変更を戻す

## 無料枠の目安
- データベース：1日1,000表示で、生の記録（90日）が約30MB（索引を含む）、集計値は年に数十KB（無料枠 500MB）
- 通信：1回の表示で約1KBの送信。API の呼び出し回数に無料枠の上限はありません（Supabase 無料プラン）
- Cloudflare Pages：配信するファイルが少し大きくなるだけ（追加の処理なし）
