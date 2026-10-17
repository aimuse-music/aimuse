// AIMUSE 退会後30日を過ぎたアカウントの完全削除（Edge Function「account-purge」の処理本体）
//
// 処理の順番（1件ずつ。各手順はデータベース側で処理番号と期限を確認してから実行）
//   ① account_purge_claim        … 期限を過ぎた申請を1件取り出す（同時に動いても同じ申請は取り出されない）
//   ② ファイルの削除             … 一覧を受け取り Storage から削除 → account_purge_mark_files（実際に無くなったものだけ記録）
//   ③ account_purge_db           … ファイルがすべて無いことを確認してから、曲と削除記録を削除
//   ④ auth.admin.deleteUser      … ログイン情報（会員）を削除。プロフィール・フォロー等は自動で消える
//   ⑤ account_purge_finish       … 会員が実際に消えたことを確認してから「完了」
// 途中で失敗したら account_purge_fail で記録し、次回の実行で続きから再開します（済んだ手順は飛ばす）。
// この処理は「管理用の秘密キー（service_role）」で動き、そのキーはサーバーの中だけで使います（ブラウザには渡しません）。

const MAX_ROUNDS = 50;           // ファイル一覧の取得回数の上限（1回最大500件）
const CHUNK = 100;               // Storage の削除は100件ずつ

export async function runPurge(sb, { maxJobs = 3, deadline = Date.now() + 100_000 } = {}) {
  const result = { processed: 0, done: 0, failed: 0, errors: [] };
  for (let i = 0; i < maxJobs && Date.now() < deadline; i++) {
    const { data, error } = await sb.rpc("account_purge_claim");
    if (error) throw new Error("claim: " + error.message);
    const job = Array.isArray(data) ? data[0] : null;
    if (!job) break;
    result.processed++;
    try {
      await purgeOne(sb, job, deadline);
      result.done++;
    } catch (e) {
      result.failed++;
      const msg = String((e && e.message) || e).slice(0, 500);
      result.errors.push(msg.split(":")[0]);   // 会員IDやファイル名は返さない
      await sb.rpc("account_purge_fail", { p_request: job.request_id, p_token: job.lock_token, p_error: msg });
    }
  }
  return result;
}

async function purgeOne(sb, job, deadline) {
  const args = { p_request: job.request_id, p_token: job.lock_token };
  const call = async (name, label) => {
    const { data, error } = await sb.rpc(name, args);
    if (error) throw new Error(label + ": " + error.message);
    return data;
  };

  // ② ファイル
  for (let round = 0; ; round++) {
    if (round >= MAX_ROUNDS) throw new Error("TOO_MANY_FILES: 次回の実行で続きから再開します");
    if (Date.now() > deadline) throw new Error("TIME_LIMIT: 次回の実行で続きから再開します");
    const files = (await call("account_purge_pending_files", "files")) || [];
    if (files.length === 0) break;
    const byBucket = new Map();
    for (const f of files) {
      if (!byBucket.has(f.bucket_id)) byBucket.set(f.bucket_id, []);
      byBucket.get(f.bucket_id).push(f.name);
    }
    for (const [bucket, names] of byBucket) {
      for (let i = 0; i < names.length; i += CHUNK) {
        const { error } = await sb.storage.from(bucket).remove(names.slice(i, i + CHUNK));
        if (error) throw new Error("storage: " + error.message);
      }
    }
    const marked = await call("account_purge_mark_files", "mark");
    if (!marked) throw new Error("STORAGE_NOT_DELETED: ファイルの削除を確認できませんでした");
  }

  // ③ データベース
  await call("account_purge_db", "db");

  // ④ ログイン情報（すでに無い場合は削除済みとして進む）
  const { error: authError } = await sb.auth.admin.deleteUser(job.user_id);
  if (authError && !(authError.status === 404 || /not.?found/i.test(authError.message || ""))) {
    throw new Error("auth: " + authError.message);
  }

  // ⑤ 完了（データベース側で会員が無いことを確認）
  await call("account_purge_finish", "finish");
}

// 秘密の合言葉の比較（長さ・内容の違いで処理時間が変わらないようにする）
export function sameSecret(a, b) {
  const x = new TextEncoder().encode(String(a || "")), y = new TextEncoder().encode(String(b || ""));
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] || 0) ^ (y[i] || 0);
  return diff === 0 && x.length > 0;
}
