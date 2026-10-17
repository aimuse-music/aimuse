// AIMUSE 退会の申請（Edge Function「account-delete-request」の処理本体）
// 本人確認は「ログイン時刻」ではなく、Supabase の正式な機能で毎回確認します。
//   ① 送られてきたログイン情報（JWT）を auth.getUser で確認 → 会員を特定（偽のログイン情報は通らない）
//   ② 1時間に5回までの制限を確認（account_reauth_allowed）
//   ③ 入力されたパスワードを signInWithPassword（正式なログイン機能）で照合
//      ・照合に使ったメールアドレスは①で特定した本人のもの（他人のメールアドレスは指定できない）
//      ・照合のために作られたログインは、すぐに終了（admin.signOut）
//      ・失敗は account_reauth_failed で記録
//   ④ 照合できた会員IDで account_request_deletion を呼ぶ（この関数は service_role 専用）
//   ⑤ ほかの端末のログインを終了（admin.signOut の others）
// 返す内容に、会員ID・メールアドレスは含めません。

export async function handleDeletionRequest({ admin, verifyPassword, userJwt, password }) {
  const reply = (status, body) => ({ status, body });
  if (!userJwt) return reply(401, { code: "LOGIN_REQUIRED", message: "ログインしてください" });

  const { data: got, error: userErr } = await admin.auth.getUser(userJwt);
  const user = got && got.user;
  if (userErr || !user || !user.id || !user.email) return reply(401, { code: "LOGIN_REQUIRED", message: "ログインし直してください" });

  if (typeof password !== "string" || password.length === 0 || password.length > 200) {
    return reply(400, { code: "PASSWORD_REQUIRED", message: "パスワードを入力してください" });
  }

  const { data: allowed, error: limitErr } = await admin.rpc("account_reauth_allowed", { p_user: user.id });
  if (limitErr) return reply(500, { code: "SERVER_ERROR", message: "申請できませんでした。時間をおいてお試しください" });
  if (allowed === false) return reply(429, { code: "TOO_MANY_ATTEMPTS", message: "パスワードの確認に続けて失敗したため、1時間ほど時間をおいてからお試しください" });

  const check = await verifyPassword(user.email, password);
  if (!check.ok || !check.userId || check.userId !== user.id) {
    if (check.temporaryJwt) await admin.auth.admin.signOut(check.temporaryJwt, "local").catch(() => {});
    if (check.rejected) {
      await admin.rpc("account_reauth_failed", { p_user: user.id });
      return reply(401, { code: "WRONG_PASSWORD", message: "パスワードが正しくありません" });
    }
    return reply(503, { code: "VERIFY_UNAVAILABLE", message: "本人確認ができませんでした。時間をおいてお試しください" });
  }
  // 照合のために作られたログインは使わないので終了
  if (check.temporaryJwt) await admin.auth.admin.signOut(check.temporaryJwt, "local").catch(() => {});

  const { data, error } = await admin.rpc("account_request_deletion", { p_user: user.id });
  if (error) {
    if (/管理者アカウント/.test(error.message || "")) return reply(403, { code: "ADMIN_ACCOUNT", message: "管理者アカウントは退会できません" });
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
