// AIMUSE Edge Functions 用の小さな Supabase 接続部品（account-delete-request と account-purge で同じ内容）
// ・Supabase の新しい形式のキー（sb_publishable_… / sb_secret_…）と、旧形式（anon / service_role の JWT）の両方に対応
// ・新しい形式のキーは「apikey」ヘッダーだけで送る（Authorization に入れると "Invalid JWT" で拒否されるため）
// ・管理用の秘密キーは、この関数の中だけで使い、利用者には返さない。公開用キーを管理用として使うことはしない
// ・ライブラリに頼らず、Supabase の公開 API（REST・Storage・Auth）を直接呼ぶ

const isJwt = (k) => typeof k === "string" && k.split(".").length === 3 && k.startsWith("eyJ");

// 環境変数からキーを選ぶ。新しい形式（JSON の辞書。"default" を優先）→ 1つだけの形式 → 旧形式 の順
export function resolveKeys(getEnv) {
  const fromJson = (name) => {
    const raw = getEnv(name);
    if (!raw) return null;
    try {
      const obj = JSON.parse(raw);
      if (obj && typeof obj === "object") return obj["default"] || Object.values(obj).find((v) => typeof v === "string") || null;
    } catch (_) { /* 形式が違う場合は使わない */ }
    return null;
  };
  const secret = fromJson("SUPABASE_SECRET_KEYS") || getEnv("SUPABASE_SECRET_KEY") || getEnv("SUPABASE_SERVICE_ROLE_KEY") || null;
  const publishable = fromJson("SUPABASE_PUBLISHABLE_KEYS") || getEnv("SUPABASE_PUBLISHABLE_KEY") || getEnv("SUPABASE_ANON_KEY") || null;
  const url = (getEnv("SUPABASE_URL") || "").replace(/\/+$/, "") || null;
  // 公開用キーを管理用として使わない（設定の取り違えを防ぐ）
  const secretOk = !!secret && !secret.startsWith("sb_publishable_");
  return { url, secret: secretOk ? secret : null, publishable: publishable || null };
}

// キーをヘッダーに載せる。新しい形式は apikey だけ。旧形式（JWT）は従来どおり Authorization にも載せる
export function keyHeaders(key) {
  return isJwt(key) ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key };
}

async function call(fetchImpl, url, init) {
  let res;
  try { res = await fetchImpl(url, init); }
  catch (e) { return { data: null, error: { status: 0, message: "network: " + (e && e.message || e) } }; }
  const text = await res.text();
  let body = null;
  try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
  if (!res.ok) {
    const message = (body && (body.message || body.msg || body.error_description || body.error)) || text || `HTTP ${res.status}`;
    return { data: null, error: { status: res.status, message: String(message), code: body && body.code } };
  }
  return { data: body, error: null };
}

// 管理用（秘密キー）の接続：データベースの関数・Storage の削除・会員の削除
export function adminClient({ url, secret, publishable, fetchImpl = fetch }) {
  const json = { "Content-Type": "application/json" };
  return {
    rpc(name, args = {}) {
      return call(fetchImpl, `${url}/rest/v1/rpc/${encodeURIComponent(name)}`, {
        method: "POST", headers: { ...keyHeaders(secret), ...json, Accept: "application/json" }, body: JSON.stringify(args),
      });
    },
    storage: {
      from(bucket) {
        return {
          remove(names) {
            return call(fetchImpl, `${url}/storage/v1/object/${encodeURIComponent(bucket)}`, {
              method: "DELETE", headers: { ...keyHeaders(secret), ...json }, body: JSON.stringify({ prefixes: names }),
            });
          },
        };
      },
    },
    auth: {
      // 利用者のログイン情報（JWT）が本物か、Supabase の認証サーバーに確認する
      async getUser(userJwt) {
        const r = await call(fetchImpl, `${url}/auth/v1/user`, {
          method: "GET", headers: { apikey: publishable, Authorization: `Bearer ${userJwt}` },
        });
        return r.error ? { data: { user: null }, error: r.error } : { data: { user: r.data }, error: null };
      },
      admin: {
        deleteUser(id) {
          return call(fetchImpl, `${url}/auth/v1/admin/users/${encodeURIComponent(id)}`, { method: "DELETE", headers: keyHeaders(secret) });
        },
        // 利用者のログインを終了（scope: local＝このログインだけ / others＝ほかの端末 / global＝すべて）
        async signOut(userJwt, scope = "global") {
          const r = await call(fetchImpl, `${url}/auth/v1/logout?scope=${encodeURIComponent(scope)}`, {
            method: "POST", headers: { apikey: publishable, Authorization: `Bearer ${userJwt}` },
          });
          return { error: r.error };
        },
      },
    },
  };
}

// パスワードの照合（公開用キーで、正式なログイン機能を使う）
export function passwordVerifier({ url, publishable, fetchImpl = fetch }) {
  return async (email, password) => {
    const r = await call(fetchImpl, `${url}/auth/v1/token?grant_type=password`, {
      method: "POST", headers: { apikey: publishable, "Content-Type": "application/json" }, body: JSON.stringify({ email, password }),
    });
    if (r.error) {
      const s = r.error.status;
      return { ok: false, rejected: typeof s === "number" && s >= 400 && s < 500 && s !== 429 };
    }
    return { ok: true, userId: r.data && r.data.user && r.data.user.id, temporaryJwt: r.data && r.data.access_token };
  };
}
