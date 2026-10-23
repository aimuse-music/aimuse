# 歌詞の自動同期の検証（lyrics-align-probe）：本番に置く前の確認資料

## 何をするか
「おぼろ月」1曲の音源と歌詞を Cloudflare Workers AI（Whisper large-v3 turbo）で解析し、各行の歌い出しの時刻の推定を**返すだけ**。
データベースの歌詞・同期の時刻・楽曲には一切書き込みません（返した結果は約6時間で自動的に消える受け取り記録にだけ残ります）。

## 置くもの
| 種類 | 名前 | 内容 |
|---|---|---|
| Edge Function | `lyrics-align-probe`（`index.ts`・`probe.js`・`align.js`・`supa.js`、Verify JWT オフ） | 呼び出し元の確認 → 音源の取り出し → Workers AI → 歌詞との照合 → 結果を返す |
| データベース | `supabase/align_probe/setup.sql` | 金庫（Vault）の合言葉1つと、関数3つの追加のみ：照合 `align_probe_secret_matches`（true/false だけ）、曲の情報 `align_probe_track`（おぼろ月1曲だけ・公開中のときだけ。曲名・歌詞・保存場所・長さのみ）、管理者か `align_probe_is_admin`（true/false だけ）。どれも service_role だけ・読み取りだけ・SECURITY DEFINER・search_path は空。この DB では service_role に表の直接の読み取り権限が無いため（既存の権限は変えない） |
| 設定（Secrets） | `CF_ACCOUNT_ID`・`CF_AI_TOKEN` | 運営者が Supabase の画面で登録（チャット・GitHub・画面の結果には出ない） |

## 権限
- 呼び出せるのは、①金庫の合言葉を持つ SQL からの呼び出し（合言葉は表示されない）、②管理者のログイン情報だけ。会員・未ログインは 401/403
- 音源は非公開の保存場所から管理用のキーで取り出し、Cloudflare には音源と歌詞（手がかりを使う場合は先頭120文字）だけを送る
- Cloudflare のトークンは Workers AI の読み取り・編集だけの権限。返す内容・記録に含めない（テストで確認）
- ブラウザからは呼べない（CORS を返さない）

## 料金の上限
- Cloudflare の無料プラン：1日 10,000 ニューロンまで。超えると Cloudflare 側で失敗し（`FREE_LIMIT`）、**課金されない**
- 1回あたり約200ニューロン（4分18秒 × 46.63/分）。検証は3回程度（約600、1日の無料枠の6%）
- 10分を超える曲・20MB を超える音源は解析しない
- 注意：Cloudflare を有料の Workers Paid に切り替えると、無料枠を超えた分が自動で請求されます。検証中は無料プランのまま

## 元に戻す方法
1. Supabase の画面 → Edge Functions → `lyrics-align-probe` → 削除
2. SQL Editor で `supabase/align_probe/teardown.sql`（追加した関数3つと金庫の合言葉を外す。最後に 0 と出れば完了）
3. Cloudflare の画面 → My Profile → API Tokens → 作ったトークンを削除、Supabase の Secrets の `CF_AI_TOKEN`・`CF_ACCOUNT_ID` を削除

## テスト（作業環境）
- 照合（`tests/edge/test_align.mjs` 16件）：単語の時刻あり／発話単位のみ／認識されない行／間奏の誤認識／繰り返すサビ／空の結果／176行の曲（80ミリ秒）
- 処理本体（`tests/edge/test_align_probe.mjs` 43件）：呼び出し元の確認（管理者の確認は関数経由）・設定不足・曲・音源・無料枠切れ・トークン無効・時間切れ・トークンを返さない・書き込まない
- 準備の SQL（`tests/db/test_align_probe_sql.py` 20件×2）：PostgreSQL 17・15 で、表の権限・RLS が変わらないこと、ほかの曲・公開中でない曲は返らないこと、合言葉の照合（一致・不一致・短い）・曲の情報と管理者の確認（停止中の管理者は不可）・会員は実行できない・片付け（service_role の表の読み取り権限が無い本番と同じ状態で確認）

## 経緯
- 2026-10-24 1回目の配置：解析 B が `DB_ERROR`（曲の情報を表から直接読もうとして 403）。音源の取り出し・AI の解析の前に止まったため、Cloudflare の使用量は 0。読み取りだけの関数経由に修正（v2）
- 2026-10-24 解析 B（手がかりなし）・C（歌詞の先頭を手がかり）：無音の除去オンで 35／65行・34／65行。中盤（47〜86行目）がほぼ認識されない
- 2026-10-24 解析 D（無音の除去オフ・手がかりなし、v3）：65／65行すべて認識。AI の処理 27秒・約201ニューロン（見積もり）
