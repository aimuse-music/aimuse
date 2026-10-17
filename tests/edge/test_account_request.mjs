// Edge Function「account-delete-request」の処理本体（request.js）のテスト
// データベースは手元の PostgreSQL を service_role で実際に呼び出す。Supabase の認証（getUser・パスワード照合・signOut）は偽物で再現。
// 使い方: node tests/edge/test_account_request.mjs <db名>（v1.9＋seed_v19 を入れたDB）
import { execFileSync } from "node:child_process";
import { handleDeletionRequest, corsHeaders } from "../../supabase/functions/account-delete-request/request.js";

const DB = process.argv[2] || "v19r2";
const psql = (sql) => {
  try { return { out: execFileSync("psql", ["-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-X", "-At", "-q", "-d", DB, "-v", "ON_ERROR_STOP=1"], { input: sql, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim(), err: null }; }
  catch (e) { return { out: "", err: String(e.stderr || e.message).split("\n").find(l => l.includes("ERROR")) || String(e.message) }; }
};
const lit = (v) => v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`;
const q = (sql) => psql(sql).out;
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i) : ""}`); };

const USERS = { "jwt-hamu": { id: "22222222-2222-4222-8222-222222222222", email: "hamu@example.com", pw: "hamu-pass" },
                "jwt-ryo": { id: "11111111-1111-4111-8111-111111111111", email: "ryo@example.com", pw: "ryo-pass" },
                "jwt-mike": { id: "33333333-3333-4333-8333-333333333333", email: "mike@example.com", pw: "mike-pass" } };
const byEmail = Object.fromEntries(Object.values(USERS).map(u => [u.email, u]));
function env({ verifyDown = false } = {}) {
  const log = [];
  const admin = {
    log,
    async rpc(name, args = {}) {
      log.push("rpc:" + name);
      const params = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ");
      const { out, err } = psql(`begin; set local role service_role; set local request.jwt.claims='{"role":"service_role"}';
        select coalesce(json_agg(t), '[]') from (select * from public.${name}(${params})) t; commit;`);
      if (err) return { data: null, error: { message: err.replace(/^.*ERROR:\s*/, "") } };
      const rows = JSON.parse(out || "[]");
      if (rows.length === 1 && Object.keys(rows[0]).length === 1 && Object.keys(rows[0])[0] === name) return { data: rows[0][name], error: null };
      return { data: rows, error: null };
    },
    auth: {
      async getUser(jwt) { log.push("getUser"); const u = USERS[jwt]; return u ? { data: { user: { id: u.id, email: u.email } }, error: null } : { data: { user: null }, error: { status: 401, message: "invalid JWT" } }; },
      admin: { async signOut(jwt, scope) { log.push(`signOut:${jwt.startsWith("tmp-") ? "temporary" : jwt}:${scope}`); return { error: null }; } }
    }
  };
  const verifyPassword = async (email, password) => {
    log.push("verify:" + email);
    if (verifyDown) return { ok: false, rejected: false };
    const u = byEmail[email];
    if (!u || u.pw !== password) return { ok: false, rejected: true };
    return { ok: true, userId: u.id, temporaryJwt: "tmp-" + u.id };
  };
  return { admin, verifyPassword, log };
}
// このテストは受付スイッチ「全員」の状態で行う（スイッチ自体は test_new_keys.mjs と test_v19.py で確認）
psql("update aimuse_private.settings set value='all' where key='account_deletion_mode'");
const call = async (jwt, password, o) => { const e = env(o); const r = await handleDeletionRequest({ admin: e.admin, verifyPassword: e.verifyPassword, userJwt: jwt, password, mode: "all" }); return { ...r, log: e.log }; };
const HAMU = USERS["jwt-hamu"].id, MIKE = USERS["jwt-mike"].id;
const active = (u) => q(`select count(*) from aimuse_private.account_deletions where user_id='${u}' and status in ('pending','processing','failed')`);

let r = await call("", "x");
ok("1 ログイン情報なしは 401（照合しない）", r.status === 401 && !r.log.some(x => x.startsWith("verify")), r.status);
r = await call("forged-jwt", "hamu-pass");
ok("1 偽のログイン情報は 401（照合しない）", r.status === 401 && !r.log.some(x => x.startsWith("verify")), r.status);
r = await call("jwt-hamu", "");
ok("2 パスワード未入力は 400", r.status === 400);
r = await call("jwt-hamu", "x".repeat(201));
ok("2 長すぎるパスワードは 400（照合しない）", r.status === 400 && !r.log.some(x => x.startsWith("verify")));
r = await call("jwt-hamu", "wrong");
ok("3 パスワード違いは 401・失敗を記録・申請しない", r.status === 401 && r.body.code === "WRONG_PASSWORD" && q(`select count(*) from aimuse_private.reauth_failures where user_id='${HAMU}'`) === "1" && active(HAMU) === "0", r.body);
ok("3 照合に使うメールアドレスはログイン中の本人のもの", r.log.includes("verify:hamu@example.com"), r.log);
r = await call("jwt-hamu", "hamu-pass", { verifyDown: true });
ok("4 認証サーバーの一時的な障害は 503（失敗回数に数えない・申請しない）", r.status === 503 && q(`select count(*) from aimuse_private.reauth_failures where user_id='${HAMU}'`) === "1" && active(HAMU) === "0", r.status);
r = await call("jwt-ryo", "ryo-pass");
ok("5 管理者アカウントは 403", r.status === 403 && r.body.code === "ADMIN_ACCOUNT" && active(USERS["jwt-ryo"].id) === "0", r.body);
ok("5 照合用に作られたログインはすぐ終了", r.log.some(x => x === "signOut:temporary:local"), r.log);
r = await call("jwt-hamu", "hamu-pass");
ok("6 正しいパスワードで申請できる（30日後）", r.status === 200 && r.body.status === "pending" && active(HAMU) === "1", r.body);
ok("6 照合用のログインは終了し、ほかの端末のログインも終了", r.log.includes("signOut:temporary:local") && r.log.includes("signOut:jwt-hamu:others"), r.log);
ok("6 返す内容に会員ID・メールアドレスを含めない", !JSON.stringify(r.body).includes(HAMU) && !JSON.stringify(r.body).includes("@"), r.body);
r = await call("jwt-hamu", "hamu-pass");
ok("7 もう一度押しても申請は1件のまま", r.status === 200 && active(HAMU) === "1");
for (let i = 0; i < 5; i++) await call("jwt-mike", "bad" + i);
r = await call("jwt-mike", "mike-pass");
ok("8 5回間違えると、正しいパスワードでも 429（照合もしない）", r.status === 429 && !r.log.some(x => x.startsWith("verify")) && active(MIKE) === "0", r.status);
psql(`update aimuse_private.reauth_failures set at = now() - interval '61 minutes' where user_id='${MIKE}'`);
r = await call("jwt-mike", "mike-pass");
ok("8 1時間たてば申請できる", r.status === 200 && active(MIKE) === "1", r.status);
const c1 = corsHeaders("https://aimusemusic.com", ["https://aimusemusic.com"]), c2 = corsHeaders("https://evil.example", ["https://aimusemusic.com"]);
ok("9 許可したサイトだけに呼び出しを許す（CORS）", c1["Access-Control-Allow-Origin"] === "https://aimusemusic.com" && !("Access-Control-Allow-Origin" in c2));

const f = R.filter(x => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
