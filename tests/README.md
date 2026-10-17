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
