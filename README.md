# AIMUSE BOOST（Ver.0.2）

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
- `tests/security.test.mjs` … 自動セキュリティテスト（本番データには触れない。`node --test tests/security.test.mjs`）

## 読み取り専用モード（追加SQLを実行する前の状態）

`supabase/boost_schema.sql` を実行するまでは、BOOST は自動で「読み取り専用モード」になり、Supabase へは一切書き込みません。

- 使える：管理者ログイン、楽曲一覧、宣伝文の作成（テンプレート）、コピー・共有、楽曲ごとの宣伝ページ、AIMUSE全体の実数（会員数・新規登録・再生数）
- 使えない：投稿の保存・カレンダー、計測リンクとクリック数、操作履歴、AI利用回数の管理（AI生成そのものも上限管理ができないため停止）

## 安全のための設計

- ログインは AIMUSE の管理者（`profiles.is_admin = true`）のみ。BOOST 用テーブルはすべて RLS で管理者以外は読み書き不可
- AIMUSE の楽曲は **読み取りのみ**（公開済み = `status = 'public'` の曲だけ）
- APIキーなどの秘密情報はブラウザに出さない。AI は Cloudflare のバインディングで呼ぶため、APIキー自体が不要
- クリック記録に個人情報は保存しない（IPアドレス・端末情報なし）。SNSのプレビュー取得やロボットのアクセスは数えない
- 重複クリック対策：同じ端末から30分以内の再クリックは数えない。そのために中身が「1」だけのクッキーを、そのリンクのパスに限って30分だけ置く（個人・端末を識別する値は入れない）
- 宣伝の対象は AIMUSE で現在公開中（status = public）の楽曲だけ。リンク・投稿の作成もクリック記録も同じ条件で判定し、非公開・削除された曲のクリックは記録しない（宣伝ページは「公開されていません」と表示）
- 計測リンクの移動先は自サイトの宣伝ページ `/s/<楽曲ID>` に固定（任意のURLは保存できない。外部サイトへの転送に悪用されない）
- クリック記録の上限（対象ごと1分60回・全体1分300回・1日2万回）は `boost_rate_counters` の行を原子的に更新する方式。カウンター3つとクリック記録は「全部成功か全部取り消し」で、同時アクセスでも上限を超えず、カウンターと記録が常に一致する
- 追加SQLは変更と必須の確認（RLS・権限・ポリシー条件など）をすべて1つのDOブロックで行い（途中で失敗、または確認でNGなら全体が取り消される）、最初に構造チェックを行う。既存のBOOSTテーブルが想定外の構造なら何も変更せず中止する
- 操作履歴・エラーは `boost_logs` に記録（設定画面で確認）
- 自動投稿は未実装。SNS接続状況はすべて「未接続（手動投稿のみ）」と表示し、データベース側でも自動投稿を設定できないようにしている

## Cloudflare Pages の設定値

- Framework preset：None
- Build command：（空欄）
- Build output directory：`public`
- AIを使う場合：Settings → Bindings → Workers AI を追加（変数名 `AI`）
- 曲ページへ誘導する場合（AIMUSE に曲ページができてから）：Settings → Variables に `AIMUSE_TRACK_URL` を追加（例：`https://aimusemusic.com/#track={id}`）。AIMUSE と同じサイトの https URL 以外は無視される

## 計測できること・できないこと

| できる | 追加実装が必要 |
|---|---|
| 計測リンクのクリック数・「AIMUSEで聴く」の回数（SNS別・楽曲別・日/週/月別） | SNS経由の再生数・会員登録数（AIMUSE側でUTMを記録する機能が必要） |
| 投稿実績（「投稿済み」にした件数） | AIMUSEの曲ページへの直接移動（AIMUSE側に曲ページURLができたら `AIMUSE_TRACK_URL` を設定するだけ） |
| AIMUSE全体の会員数・新規登録数・公開曲数・再生数（実数） | SNS上のいいね・表示回数（各SNS公式APIが必要） |

架空の数値は表示しません。データがない場合は「まだありません」と表示します。

## 今後（Ver.0.2 以降の候補）

- AIMUSE に曲ページURL（例：`/#track=<id>`）と UTM 記録を追加（AIMUSE 本体の変更のため、事前に確認してから）。BOOST側は `AIMUSE_TRACK_URL` で受け入れ済み
- SNS公式APIでの自動投稿（`boost_post_attempts` と `idempotency_key` で重複防止・失敗記録・再試行に対応できる設計にしてある）
