# 本番に実際に適用したSQL（2026-10-18）

本番の Supabase SQL Editor で、この順に1回ずつ実行しました。どちらも成功し、最終確認は29項目すべて OK です。

1. `2026-10-18_1_migration_v1_6_profile_r2.sql` … v1.6 を BEGIN〜COMMIT で囲んだもの（中身は `../migration_v1_6_profile.sql` と同じ）
2. `2026-10-18_2_migration_v1_7_to_v1_10_combined.sql` … v1.7〜v1.10 を1本にまとめ、COMMIT 前に最終確認（29番は「受付 off・完全削除 off」のときだけ OK）

**もう一度実行する必要はありません。** 元に戻すときは `../rollback/` の SQL を新しい版から順に使います。
