# AIMUSE テスト（公開されません：Cloudflare Pages は public/ だけを公開）

## DB（Supabase と同じ役割・権限を再現した PostgreSQL 16）
- `db/supabase_env.sql` … anon / authenticated、auth.uid()、storage（owner_id 付き）の再現
- `db/seed.sql` / `db/seed_v17.sql` … テスト用の会員・曲・フォロー
- `db/attack.py`（v1.5 権限 63件）・`db/attack_v16.py`（プロフィール 77件）・`db/test_v17.py`（フォロー一覧 29件）・`db/test_v18.py`（カラーテーマ 17件）・`db/test_v19.py`（楽曲の削除・退会・取り消し期限との競合・受付スイッチと許可リスト・パスワード照合の同時送信（C4） 102件。v18 のDBをコピーして v1.9＋`seed_v19.sql` を入れて実行）・`db/test_v110.py`（レビューの投稿者名 9件）
- 手順：構築SQL → seed.sql → migration_v1_6 → migration_v1_7（→ seed_v17.sql）→ migration_v1_8 → migration_v1_9 → migration_v1_10 → 各テスト

## 画面（Playwright + Chromium、iPhone 13 / Pixel 7 の画面サイズ・タッチ操作）
- `ui/fake-profile.js` … Supabase の代わり（ルールは DB テストで検証済みのものを再現）
- `ui/test_profile.js`（53件）・`ui/test_follow.js`（24件）・`ui/test_guest.js`（24件）・`ui/test_theme.js`（カラーテーマ 46件）・`ui/test_delete.js`（楽曲の削除・退会 39件）・`ui/test_pwa.js`（ホーム画面に追加・オフライン・更新・ノッチ 24件。localhost で実際の Service Worker を動かす）・`ui/test_repeat.js`（リピート3種・シャッフル・プレーヤーの同期 15件。実際の音声で再生を進める）・`ui/test_flags.js`（機能スイッチ 16件）・`ui/test_contrast.js`（各画面の文字のコントラスト計測）
- `edge/test_account_request.mjs`（退会の申請・パスワード照合 17件）
- `edge/test_new_keys.mjs`（新しい形式のキー・受付スイッチ・許可リスト 27件。新しいキーの規則を再現した偽ゲートウェイ `fake_gateway.mjs` 越しに実際の HTTP で動かす）
- `edge/test_account_purge.mjs`（退会後の完全削除の処理本体 23件。ファイルの種類・保存先・途中失敗・600件超も確認。手元のPostgreSQLを service_role で呼び、Storage・会員削除は失敗も注入できる偽物）
- 実機（本物の iPhone Safari・Android Chrome）での確認は別途必要

## 公開前の監査（release/）
- `release/seed_prodlike.sql`・`release/audit_apply.py`（本番に近いデータで v1.6〜v1.10 の適用・元に戻す・再適用 23件）
- `release/check_readonly.py`（確認用SQLが読み取り専用であることの検査：文が1つ・書き込みの命令なし・標準の読み取り関数だけ・読み取り専用の取引で実行できる）
- `release/test_killswitch.js`（PWA の緊急停止）
- `db/test_v111.py`（プレイリスト 35件）・`ui/test_playlist.js`（プレイリストの画面 23件）
- `db/test_v112.py`（v1.12：退会の完全削除で、その会員が聴いた再生記録も消す 27件×PostgreSQL 17・15）・`ui/test_upload.js`（楽曲の投稿：入力チェック・確認・失敗時・申請 15件）
- 画面のテストの端末指定は `iphone` または `android`（それ以外の文字は iPhone 13 として動きます）
- `db/test_deletion_test_sql.py`（退会テスト用SQL 01・01b・02〜04：表示名「退会テスト用」のアカウントだけが対象・登録だけでは受付は off のまま・本番の会員を守る 19件×2）
- `db/test_prod_finish.py`（2026-10-19 本番作業の仕上げSQL：v1.12・pg_net の入れ直し・既存データが変わらない・中止の条件 15件×2。pg_net は `share/extension` に置いた同じ形の偽物で代用）・`edge/test_new_keys.mjs` の 3b（受付スイッチをデータベースで確認：v1.13 未適用・off・testers・all・権限 7件）・`edge/test_purge_caller.mjs`（完全削除の呼び出し元を金庫の合言葉で確認 7件）
- まとめて実行：`bash tests/run_all.sh`
- `ui/test_recovery.js`（パスワード再設定のリンクで開くと新しいパスワードの入力画面が出る・期限切れのリンクは理由を表示・通常の起動では出ない 14件×iPhone/Android。リンクの通知が読み込み直後に1回だけ届く本物の動きを fake-profile.js で再現）
- `db/test_v114.py`（v1.14 歌詞の同期：権限・本人と管理者だけ保存・形式の確認15種・見える範囲・歌詞が変わると要確認・退会手続き中・曲の削除・元に戻す 40件×PostgreSQL 17・15）
- `ui/test_lyrics_sync.js`（歌詞の同期：時刻どおりの表示・イントロ／間奏で進まない・見出し・一時停止・シーク・途中から・再生速度・自動スクロール・未同期は全文表示・編集画面（タップ記録・遅れ補正・0.1秒調整・全体調整・順番の確認・保存前の確認）・権限・v1.14 未適用 41件×iPhone/Android。20秒の実際の音声で再生）
- `db/test_v117.py`（v1.17 アクセス解析：再生数が今までの関数と同じ（14通り＋上限）・count_play・管理者と管理者の端末の除外・解析の失敗で再生数を落とさない・30分の重複防止・個人情報を残さない・水増し対策・権限・集計の正しさ（日本時間）・90日で削除・ランキング・呼び出しの上限・元に戻す・IPv6 は /64 単位 72件。テンプレート prod116 = v1.16 まで適用済み）
- `ui/test_analytics.js`（アクセス解析：未ログインの計測・再描画で送らない・再生は count_play だけ（未作成なら increment_plays に1回）・管理者のログイン中／ログアウト後は送らない・集計画面（カード・日別／月別・画面別・ランキング・大きな数・エラー表示）・ポリシーの記載・機能スイッチ 41件×iPhone/Android）
- この作業環境の React は v19 を esbuild でまとめたもの（`libs.js`。npm の公開サーバーに接続できないため）。main の画面テストで結果が同じことを確認済み
