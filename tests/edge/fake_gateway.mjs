// Supabase の API 入口（ゲートウェイ）の偽物：新しい形式のキーの規則を再現し、データベースは手元の PostgreSQL を使う
//  ・新しい形式のキー（sb_…）は apikey ヘッダーでだけ受け付ける。Authorization に JWT 以外が入っていたら 401 "Invalid JWT"
//  ・sb_secret_… → service_role、sb_publishable_… → anon（ログイン情報があれば authenticated）
//  ・Auth：/token（パスワード）・/user（ログイン情報の確認）・/logout・/admin/users/:id（秘密キーのみ）
//  ・Storage：DELETE /object/:bucket（秘密キーのみ。storage.objects から削除）
import http from "node:http";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";

export const KEYS = { secret: "sb_secret_TESTONLY_xxxxxxxxxxxxxxxxxxxxxxxx", publishable: "sb_publishable_TESTONLY_yyyyyyyyyyyyyyyy" };
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const SIGN = "test-signing-key";
export function makeJwt(claims) {
  const h = b64({ alg: "HS256", typ: "JWT" }), p = b64(claims);
  return `${h}.${p}.${crypto.createHmac("sha256", SIGN).update(`${h}.${p}`).digest("base64url")}`;
}
function verifyJwt(t) {
  const [h, p, s] = String(t).split(".");
  if (!s || crypto.createHmac("sha256", SIGN).update(`${h}.${p}`).digest("base64url") !== s) return null;
  const c = JSON.parse(Buffer.from(p, "base64url").toString()); if (c.exp && c.exp < Date.now() / 1000) return null; return c;
}

export function startGateway({ db, users }) {
  const log = [];
  const revoked = new Set();
  const psql = (sql) => {
    try { return { out: execFileSync("psql", ["-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-X", "-At", "-q", "-d", db, "-v", "ON_ERROR_STOP=1"], { input: sql, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim(), err: null }; }
    catch (e) { return { out: "", err: (String(e.stderr || "").split("\n").find((l) => l.includes("ERROR")) || "error").replace(/^.*ERROR:\s*/, "") }; }
  };
  const lit = (v) => (v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`);
  const server = http.createServer(async (req, res) => {
    const u = new URL(req.url, "http://x");
    let raw = ""; for await (const c of req) raw += c;
    const body = raw ? JSON.parse(raw) : {};
    const apikey = req.headers["apikey"] || "";
    const auth = (req.headers["authorization"] || "").replace(/^Bearer\s+/i, "");
    const send = (s, o) => { res.writeHead(s, { "Content-Type": "application/json" }); res.end(o === undefined ? "" : JSON.stringify(o)); };
    log.push({ path: u.pathname, method: req.method, apikey: apikey.slice(0, 14), auth: auth ? (auth.split(".").length === 3 ? "jwt" : auth.slice(0, 14)) : "" });
    // ゲートウェイの規則
    if (apikey !== KEYS.secret && apikey !== KEYS.publishable) return send(401, { message: "Invalid API key" });
    if (auth && auth.split(".").length !== 3) return send(401, { message: "Invalid JWT" });
    const claims = auth ? verifyJwt(auth) : null;
    if (auth && (!claims || revoked.has(claims.session_id))) return send(401, { message: "Invalid JWT" });
    const isSecret = apikey === KEYS.secret;

    if (u.pathname.startsWith("/rest/v1/rpc/")) {
      const name = u.pathname.split("/").pop();
      const role = isSecret ? "service_role" : claims ? "authenticated" : "anon";
      const jwt = isSecret ? { role: "service_role" } : claims ? { sub: claims.sub, role: "authenticated" } : { role: "anon" };
      const params = Object.entries(body).map(([k, v]) => `${k} => ${lit(v)}`).join(", ");
      const r = psql(`begin; set local role ${role}; set local request.jwt.claims='${JSON.stringify(jwt)}';
        select coalesce(json_agg(t), '[]') from (select * from public.${name}(${params})) t; commit;`);
      if (r.err) return send(/permission denied/.test(r.err) ? 403 : 400, { message: r.err });
      const rows = JSON.parse(r.out || "[]");
      if (rows.length === 1 && Object.keys(rows[0]).length === 1 && Object.keys(rows[0])[0] === name) return send(200, rows[0][name]);
      return send(200, rows);
    }
    if (u.pathname === "/auth/v1/token") {
      const usr = Object.values(users).find((x) => x.email === body.email);
      if (!usr || usr.password !== body.password) return send(400, { error: "invalid_grant", error_description: "Invalid login credentials" });
      const sid = crypto.randomUUID();
      return send(200, { access_token: makeJwt({ sub: usr.id, email: usr.email, role: "authenticated", session_id: sid }), user: { id: usr.id, email: usr.email } });
    }
    if (u.pathname === "/auth/v1/user") {
      if (!claims || !claims.sub) return send(401, { message: "invalid claim: missing sub claim" });
      const exists = psql(`select count(*) from auth.users where id=${lit(claims.sub)}`).out === "1";
      return exists ? send(200, { id: claims.sub, email: claims.email }) : send(404, { message: "User not found" });
    }
    if (u.pathname === "/auth/v1/logout") {
      if (!claims) return send(401, { message: "no session" });
      log.push({ logout: u.searchParams.get("scope"), sid: claims.session_id === "user-session" ? "user" : "temporary" });
      if (u.searchParams.get("scope") !== "others") revoked.add(claims.session_id);
      return send(204);
    }
    if (u.pathname.startsWith("/auth/v1/admin/users/")) {
      if (!isSecret) return send(403, { message: "User not allowed" });
      const id = u.pathname.split("/").pop();
      const r = psql(`delete from auth.users where id=${lit(id)} returning id`);
      return r.out ? send(200, {}) : send(404, { message: "User not found" });
    }
    if (u.pathname.startsWith("/storage/v1/object/") && req.method === "DELETE") {
      if (!isSecret) return send(400, { message: "Unauthorized" });
      const bucket = decodeURIComponent(u.pathname.split("/").pop());
      const names = body.prefixes || [];
      if (names.length) psql(`delete from storage.objects where bucket_id=${lit(bucket)} and name in (${names.map(lit).join(",")})`);
      return send(200, names.map((n) => ({ name: n })));
    }
    send(404, { message: "not found" });
  });
  return new Promise((resolve) => server.listen(0, () => resolve({ url: `http://localhost:${server.address().port}`, log, close: () => server.close(), psql })));
}
