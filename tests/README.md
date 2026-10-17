# AIMUSE テスト（公開されません：Cloudflare Pages は public/ だけを公開）

## DB（Supabase と同じ役割・権限を再現した PostgreSQL 16）
- `db/supabase_env.sql` … anon / authenticated、auth.uid()、storage（owner_id 付き）の再現
- `db/seed.sql` / `db/seed_v17.sql` … テスト用の会員・曲・フォロー
- `db/attack.py`（v1.5 権限 63件）・`db/attack_v16.py`（プロフィール 77件）・`db/test_v17.py`（フォロー一覧 29件）・`db/test_v18.py`（カラーテーマ 17件）・`db/test_v19.py`（楽曲の削除・退会 80件。v18 のDBをコピーして v1.9＋`seed_v19.sql` を入れて実行）
- 手順：構築SQL → seed.sql → migration_v1_6 → migration_v1_7（→ seed_v17.sql）→ migration_v1_8 → migration_v1_9 → 各テスト

## 画面（Playwright + Chromium、iPhone 13 / Pixel 7 の画面サイズ・タッチ操作）
- `ui/fake-profile.js` … Supabase の代わり（ルールは DB テストで検証済みのものを再現）
- `ui/test_profile.js`（53件）・`ui/test_follow.js`（24件）・`ui/test_guest.js`（24件）・`ui/test_theme.js`（カラーテーマ 46件）・`ui/test_delete.js`（楽曲の削除・退会 38件）・`ui/test_contrast.js`（各画面の文字のコントラスト計測）
- `edge/test_account_purge.mjs`（退会後の完全削除の処理本体 15件。手元のPostgreSQLを service_role で呼び、Storage・会員削除は失敗も注入できる偽物）
- 実機（本物の iPhone Safari・Android Chrome）での確認は別途必要
