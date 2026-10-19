#!/bin/bash
# 公開前の自動テストをまとめて実行（この作業環境用）。結果の要約だけを表示します
# 使い方：bash tests/run_all.sh
cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd); H=/tmp/claude-0/h; P="psql -h /home/pgtest/pg -p 55432 -U postgres -X -q -v ON_ERROR_STOP=1"
bash /opt/pgx/start_all.sh 2>/dev/null
sum(){ grep -E "合計|基準未満" | tail -1; }
echo "== データベース"
echo "v1.9 退会など: $(python3 tests/db/test_v19.py 2>&1 | sum)"
echo "v1.10 レビュー名: $(python3 tests/db/test_v110.py 2>&1 | sum)"
echo "v1.11 プレイリスト: $(python3 tests/db/test_v111.py 2>&1 | sum)"
echo "v1.12 再生記録・合言葉の照合: $(python3 tests/db/test_v112.py 2>&1 | sum)"
echo "本番作業の仕上げSQL: $(python3 tests/db/test_prod_finish.py 2>&1 | sum)"
echo "退会テスト用SQL: $(python3 tests/db/test_deletion_test_sql.py 2>&1 | sum)"
echo "== Edge Function"
for d in e_req e_keys e_purge; do $P -d postgres -c "drop database if exists $d" -c "create database $d template v18" >/dev/null 2>&1
  $P -d $d -f supabase/migration_v1_9_delete.sql >/dev/null 2>&1; $P -d $d -f /home/pgtest/seed_v19.sql >/dev/null 2>&1
  $P -d $d -c "update aimuse_private.settings set value='all' where key='account_deletion_mode'; update aimuse_private.settings set value='on' where key='account_purge_enabled';" >/dev/null 2>&1; done
$P -d e_purge -f supabase/migration_v1_10_review_names.sql >/dev/null 2>&1; $P -d e_purge -f supabase/migration_v1_11_playlists.sql >/dev/null 2>&1; $P -d e_purge -f supabase/migration_v1_12_purge_play_events.sql >/dev/null 2>&1
echo "退会の申請: $(node tests/edge/test_account_request.mjs e_req 2>&1 | sum)"
echo "新しい形式のキー: $(node tests/edge/test_new_keys.mjs e_keys 2>&1 | sum)"
echo "呼び出し元の確認: $(node tests/edge/test_purge_caller.mjs 2>&1 | sum)"
echo "完全削除（v1.12 適用後）: $(node tests/edge/test_account_purge.mjs e_purge 2>&1 | sum)"
for d in e_req e_keys e_purge; do $P -d postgres -c "drop database if exists $d" >/dev/null 2>&1; done
echo "== 画面（iPhone 13 / Android）"
mkdir -p $H/out; cp tests/ui/*.js $H/; cd $H
for t in test_guest test_profile test_follow test_theme test_delete test_playlist test_repeat test_upload; do for d in iphone android; do echo "$t [$d]: $(timeout 600 node $t.js $ROOT/public/index.html $d out 2>&1 | sum)"; done; done
for d in iphone android; do echo "test_flags [$d]: $(timeout 600 node test_flags.js $ROOT/public $d 2>&1 | sum)"; echo "test_pwa [$d]: $(timeout 600 node test_pwa.js $ROOT/public $d out 2>&1 | sum)"; echo "test_contrast [$d]: $(timeout 600 node test_contrast.js $ROOT/public/index.html $d out 2>&1 | sum)"; done
