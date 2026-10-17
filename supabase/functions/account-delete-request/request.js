// AIMUSE 退会の申請（Edge Function「account-delete-request」の処理本体）
// 本人確認は「ログイン時刻」ではなく、Supabase の正式な機能で毎回確認します。
//   ① 送られてきたログイン情報（JWT）を Supabase の認証サーバーで確認 → 会員を特定（偽のログイン情報は通らない。公開用キーだけでは通らない）
//   ①' 受付のスイッチと許可リストを確認（この関数の設定。データベース側でも同じ確認をする）
//   ② 1時間に5回までの枠を1つ予約（account_reauth_begin。会員ごとに1件ずつ処理するので、同時に送られても5回を超えない）
//   ③ 入力されたパスワードを signInWithPassword（正式なログイン機能）で照合
//      ・照合に使ったメールアドレスは①で特定した本人のもの（他人のメールアドレスは指定できない）
//      ・照合のために作られたログインは、すぐに終了（admin.signOut）
//      ・結果は account_reauth_end で記録（失敗は回数に残す。成功・一時的な障害は予約を消して数えない）
//   ④ 照合できた会員IDで account_request_deletion を呼ぶ（この関数は service_role 専用）
//   ⑤ ほかの端末のログインを終了（admin.signOut の others）
// 返す内容に、会員ID・メールアドレスは含めません。

// 受付のスイッチ（この関数の設定）：off＝誰も申請できない（初期値）/ testers＝許可リストの会員IDだけ / all＝全員
//   データベース側にも同じスイッチと許可リストがあり、両方が許可したときだけ申請できる
export function deletionGate(mode, testers, userId) {
  const m = String(mode || "off").trim();
  if (m === "all") return null;
  if (m === "testers") {
    const list = String(testers || "").split(",").map((x) => x.trim().toLowerCase()).filter(Boolean);
    return list.includes(String(userId).toLowerCase()) ? null : { status: 403, body: { code: "NOT_ALLOWED", message: "アカウントの削除（退会）は、現在準備中です" } };
  }
  return { status: 403, body: { code: "DELETION_DISABLED", message: "アカウントの削除（退会）は、現在準備中です" } };
}

export async function handleDeletionRequest({ admin, verifyPassword, userJwt, password, mode = "off", testers = "" }) {
  const reply = (status, body) => ({ status, body });
  if (!userJwt) return reply(401, { code: "LOGIN_REQUIRED", message: "ログインしてください" });

  const { data: got, error: userErr } = await admin.auth.getUser(userJwt);
  const user = got && got.user;
  if (userErr || !user || !user.id || !user.email) return reply(401, { code: "LOGIN_REQUIRED", message: "ログインし直してください" });

  // 受付のスイッチ（パスワードを照合する前に判定。対象外の会員の試行回数は使わない）
  const gate = deletionGate(mode, testers, user.id);
  if (gate) return gate;

  if (typeof password !== "string" || password.length === 0 || password.length > 200) {
    return reply(400, { code: "PASSWORD_REQUIRED", message: "パスワードを入力してください" });
  }

  const { data: attempt, error: limitErr } = await admin.rpc("account_reauth_begin", { p_user: user.id });
  if (limitErr) return reply(500, { code: "SERVER_ERROR", message: "申請できませんでした。時間をおいてお試しください" });
  if (!attempt) return reply(429, { code: "TOO_MANY_ATTEMPTS", message: "パスワードの確認に続けて失敗したため、1時間ほど時間をおいてからお試しください" });

  // 照合中に処理が止まった場合、予約は「失敗」として残る（回数を少なく数える側には倒れない）
  let check;
  try { check = await verifyPassword(user.email, password); } catch (_) { check = { ok: false, rejected: false }; }
  const failed = !check.ok || !check.userId || check.userId !== user.id;
  await admin.rpc("account_reauth_end", { p_attempt: attempt, p_failed: failed && check.rejected !== false });
  if (failed) {
    if (check.temporaryJwt) await admin.auth.admin.signOut(check.temporaryJwt, "local").catch(() => {});
    if (check.rejected) return reply(401, { code: "WRONG_PASSWORD", message: "パスワードが正しくありません" });
    return reply(503, { code: "VERIFY_UNAVAILABLE", message: "本人確認ができませんでした。時間をおいてお試しください" });
  }
  // 照合のために作られたログインは使わないので終了
  if (check.temporaryJwt) await admin.auth.admin.signOut(check.temporaryJwt, "local").catch(() => {});

  const { data, error } = await admin.rpc("account_request_deletion", { p_user: user.id });
  if (error) {
    if (/管理者アカウント/.test(error.message || "")) return reply(403, { code: "ADMIN_ACCOUNT", message: "管理者アカウントは退会できません" });
    if (/DELETION_DISABLED/.test(error.message || "")) return reply(403, { code: "DELETION_DISABLED", message: "アカウントの削除（退会）は、現在準備中です" });
    if (/NOT_ALLOWED/.test(error.message || "")) return reply(403, { code: "NOT_ALLOWED", message: "アカウントの削除（退会）は、現在準備中です" });
    return reply(500, { code: "SERVER_ERROR", message: "申請できませんでした。時間をおいてお試しください" });
  }
  const row = Array.isArray(data) ? data[0] : data;

  // ほかの端末のログインを終了（失敗しても申請は有効。手続き中の操作はデータベース側で拒否される）
  await admin.auth.admin.signOut(userJwt, "others").catch(() => {});

  return reply(200, { status: row && row.status, purge_after: row && row.purge_after });
}

// 呼び出し元の確認：許可したサイトからの呼び出しだけに CORS を返す
export function corsHeaders(origin, allowed) {
  const ok = !!origin && allowed.includes(origin);
  return {
    ...(ok ? { "Access-Control-Allow-Origin": origin, "Vary": "Origin" } : {}),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}
