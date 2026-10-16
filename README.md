# AIMUSE BOOST（Ver.0.1）

流れ：SNSの投稿 → 計測リンク `/go/…`（クリック記録）→ 宣伝ページ `/s/…` →「AIMUSEで聴く」`/out/…`（記録）→ aimusemusic.com

AIMUSE の宣伝・集客を支援する、運営者専用の管理アプリ。iPhone での操作を前提にしています。
AIMUSE 本体とは別のサイトとして公開し、データは AIMUSE と同じ Supabase プロジェクトに **追加のテーブルだけ** を作って保存します。

## 構成（無料枠のみ）

| 役割 | サービス | 費用 |
|---|---|---|
| 画面の公開・短縮リンク・AI呼び出し | Cloudflare Pages（Pages Functions） | 無料（Functions は1日10万リクエストまで） |
| ログイン・データ保存 | Supabase（AIMUSE と同じプロジェクト） | 無料（AIMUSE と枠を共有） |
| AI文章生成（任意） | Cloudflare Workers AI | 無料（1日1万ニューロンまで。無料プランでは超過しても課金されず、エラーで止まる） |
| コード保存 | GitHub | 無料 |

## フォルダ

- `public/` … 公開される画面（Cloudflare Pages の出力ディレクトリ）
  - `index.html` … アプリ本体（React + htm、ビルド不要）
  - `config.js` … 接続設定（Supabase の公開用キーと AIMUSE の公開URL）
  - `_headers` … セキュリティ用のHTTPヘッダー（検索エンジンに載せない設定を含む）
- `functions/` … サーバー処理（Cloudflare Pages Functions）
  - `go/[code].js` … SNSに載せる計測リンク `/go/xxxxxxx`。クリックを記録して宣伝ページへ移動
  - `s/[id].js` … 楽曲ごとの宣伝ページ `/s/<楽曲ID>`（誰でも閲覧可。SNSでジャケット付きのプレビューが出る）
  - `out/[id].js` … 宣伝ページの「AIMUSEで聴く」。記録してから aimusemusic.com へ移動（UTM付き）
  - `cover/[id].js` … 宣伝ページ・SNSプレビュー用のジャケット画像（公開中の曲のみ）
  - `api/status.js` … AIの接続状況（設定済みかどうかだけを返す）
  - `api/generate.js` … AI宣伝文の生成（管理者のみ・1日の上限あり）
- `lib/shared.js` … サーバー処理の共通部品
- `supabase/boost_schema.sql` … BOOST 用の追加SQL（AIMUSE の既存テーブルは変更しない）

## 安全のための設計

- ログインは AIMUSE の管理者（`profiles.is_admin = true`）のみ。BOOST 用テーブルはすべて RLS で管理者以外は読み書き不可
- AIMUSE の楽曲は **読み取りのみ**（公開済み = `status = 'public'` の曲だけ）
- APIキーなどの秘密情報はブラウザに出さない。AI は Cloudflare のバインディングで呼ぶため、APIキー自体が不要
- クリック記録に個人情報は保存しない（IPアドレス・端末情報・Cookieなし）。SNSのプレビュー取得やロボットのアクセスは数えない
- 操作履歴・エラーは `boost_logs` に記録（設定画面で確認）
- 自動投稿は未実装。SNS接続状況はすべて「未接続（手動投稿のみ）」と表示し、データベース側でも自動投稿を設定できないようにしている

## Cloudflare Pages の設定値

- Framework preset：None
- Build command：（空欄）
- Build output directory：`public`
- AIを使う場合：Settings → Bindings → Workers AI を追加（変数名 `AI`）

## 計測できること・できないこと

| できる | 追加実装が必要 |
|---|---|
| 計測リンクのクリック数・「AIMUSEで聴く」の回数（SNS別・楽曲別・日/週/月別） | SNS経由の再生数・会員登録数（AIMUSE側でUTMを記録する機能が必要） |
| 投稿実績（「投稿済み」にした件数） | AIMUSEの曲ページへの直接移動（AIMUSE側に曲ページURLが必要） |
| AIMUSE全体の会員数・新規登録数・公開曲数・再生数（実数） | SNS上のいいね・表示回数（各SNS公式APIが必要） |

架空の数値は表示しません。データがない場合は「まだありません」と表示します。

## 今後（Ver.0.2 以降の候補）

- AIMUSE に曲ページURL（例：`/#track=<id>`）と UTM 記録を追加（AIMUSE 本体の変更のため、事前に確認してから）
- SNS公式APIでの自動投稿（`boost_post_attempts` と `idempotency_key` で重複防止・失敗記録・再試行に対応できる設計にしてある）
