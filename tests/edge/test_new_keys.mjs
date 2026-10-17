// C2（新しい形式のキー）と C3（受付スイッチ・許可リスト）の確認
// Supabase の API 入口の規則を再現した偽ゲートウェイ（fake_gateway.mjs）越しに、実際の HTTP で2つの Edge Function の処理を動かす
// 使い方: node tests/edge/test_new_keys.mjs <db名>（v1.9＋seed_v19 を入れたDB）
import { resolveKeys, keyHeaders, adminClient, passwordVerifier } from "../../supabase/functions/account-delete-request/supa.js";
import { handleDeletionRequest, deletionGate } from "../../supabase/functions/account-delete-request/request.js";
import { runPurge } from "../../supabase/functions/account-purge/purge.js";
import { startGateway, KEYS, makeJwt } from "./fake_gateway.mjs";
import fs from "node:fs";

const DB = process.argv[2] || "v19k";
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i) : ""}`); };
const HAMU = "22222222-2222-4222-8222-222222222222", MIKE = "33333333-3333-4333-8333-333333333333", RYO = "11111111-1111-4111-8111-111111111111";
const USERS = { hamu: { id: HAMU, email: "hamu@example.com", password: "hamu-pass" }, mike: { id: MIKE, email: "mike@example.com", password: "mike-pass" }, ryo: { id: RYO, email: "ryo@example.com", password: "ryo-pass" } };
const userJwt = (u) => makeJwt({ sub: USERS[u].id, email: USERS[u].email, role: "authenticated", session_id: "user-session" });

// ---- 1. キーの読み込み
const envOf = (o) => (k) => o[k] ?? null;
let k = resolveKeys(envOf({ SUPABASE_URL: "https://p.supabase.co/", SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_A", billing: "sb_secret_B" }), SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_P" }), SUPABASE_SERVICE_ROLE_KEY: "eyJ.legacy.x" }));
ok("1 新しい形式（JSON の辞書）を優先し、default のキーを使う", k.secret === "sb_secret_A" && k.publishable === "sb_publishable_P" && k.url === "https://p.supabase.co", k);
k = resolveKeys(envOf({ SUPABASE_URL: "u", SUPABASE_SERVICE_ROLE_KEY: "eyJa.b.c", SUPABASE_ANON_KEY: "eyJd.e.f" }));
ok("1 新しい形式が無ければ旧形式を使う", k.secret === "eyJa.b.c" && k.publishable === "eyJd.e.f");
k = resolveKeys(envOf({ SUPABASE_URL: "u", SUPABASE_SECRET_KEY: "sb_publishable_WRONG", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_P" }));
ok("1 公開用キーを管理用として使わない（設定の取り違えを防ぐ）", k.secret === null);
k = resolveKeys(envOf({ SUPABASE_URL: "u", SUPABASE_SECRET_KEYS: "{broken" }));
ok("1 形式が壊れた設定は使わない", k.secret === null);
ok("1 新しい形式のキーは apikey だけに載せる（Authorization に入れない）", JSON.stringify(keyHeaders("sb_secret_A")) === JSON.stringify({ apikey: "sb_secret_A" }));
ok("1 旧形式（JWT）のキーは従来どおり両方に載せる", keyHeaders("eyJa.b.c").Authorization === "Bearer eyJa.b.c");

// ---- 2. 受付スイッチ（この関数の設定）
ok("2 初期値（未設定）は誰も申請できない", deletionGate(undefined, "", HAMU)?.body.code === "DELETION_DISABLED");
ok("2 書き間違えた値も申請できない", deletionGate("ALL ", "", HAMU)?.body.code === "DELETION_DISABLED" || deletionGate("yes", "", HAMU)?.body.code === "DELETION_DISABLED");
ok("2 testers：許可リストの会員だけ", deletionGate("testers", `${MIKE}, ${HAMU}`, HAMU) === null && deletionGate("testers", MIKE, HAMU)?.body.code === "NOT_ALLOWED" && deletionGate("testers", "", HAMU)?.body.code === "NOT_ALLOWED");
ok("2 all：全員", deletionGate("all", "", HAMU) === null);

// ---- 3. 偽ゲートウェイ越しに、実際の HTTP で動かす
const gw = await startGateway({ db: DB, users: USERS });
const keys = { url: gw.url, secret: KEYS.secret, publishable: KEYS.publishable };
const admin = adminClient(keys), verify = passwordVerifier(keys);
const req = (u, pw, mode = "all", testers = "") => handleDeletionRequest({ admin, verifyPassword: verify, userJwt: u ? userJwt(u) : "", password: pw, mode, testers });
const q = (sql) => gw.psql(sql).out;
const active = (id) => q(`select count(*) from aimuse_private.account_deletions where user_id='${id}' and status in ('pending','processing','failed')`);
q("update aimuse_private.settings set value='off' where key='account_deletion_mode'; update aimuse_private.settings set value='off' where key='account_purge_enabled';");

let r = await req("hamu", "hamu-pass", "all");
ok("3 関数の設定が all でも、データベースのスイッチがオフなら申請できない（二重の確認）", r.status === 403 && r.body.code === "DELETION_DISABLED" && active(HAMU) === "0", r.body);
q("update aimuse_private.settings set value='testers' where key='account_deletion_mode'");
r = await req("hamu", "hamu-pass", "testers", HAMU);
ok("3 関数の許可リストにあっても、データベースの許可リストに無ければ申請できない", r.status === 403 && r.body.code === "NOT_ALLOWED" && active(HAMU) === "0", r.body);
q(`insert into aimuse_private.deletion_testers (user_id) values ('${HAMU}') on conflict do nothing`);
let mark = gw.log.length;
r = await req("hamu", "hamu-pass", "testers", "");
ok("3 データベースの許可リストにあっても、関数の許可リストに無ければ申請できない（パスワード照合もしない）", r.status === 403 && r.body.code === "NOT_ALLOWED" && !gw.log.slice(mark).some((l) => l.path === "/auth/v1/token"), r.body);
const before = gw.log.length;
r = await req("hamu", "wrong", "testers", HAMU);
ok("3 両方の許可リストにある会員：パスワード違いは 401", r.status === 401 && r.body.code === "WRONG_PASSWORD" && active(HAMU) === "0", r.body);
r = await req("hamu", "hamu-pass", "testers", HAMU);
ok("3 両方の許可リストにある会員：正しいパスワードで申請できる", r.status === 200 && r.body.status === "pending" && active(HAMU) === "1", r.body);
const calls = gw.log.slice(before).filter((l) => l.path);
ok("3 秘密キーは apikey だけで送り、Authorization に入れていない（新しい形式の規則）", calls.filter((l) => l.apikey.startsWith("sb_secret")).every((l) => l.auth === ""), calls.filter((l) => l.apikey.startsWith("sb_secret")));
ok("3 ログイン情報の確認・ログイン終了は、公開用キー＋利用者のログイン情報で行う", calls.filter((l) => /\/auth\/v1\/(user|logout)/.test(l.path)).every((l) => l.apikey.startsWith("sb_publishable") && l.auth === "jwt"));
ok("3 照合用のログインはすぐ終了し、ほかの端末のログインも終了", gw.log.some((l) => l.logout === "local" && l.sid === "temporary") && gw.log.some((l) => l.logout === "others" && l.sid === "user"));
r = await handleDeletionRequest({ admin, verifyPassword: verify, userJwt: KEYS.publishable, password: "hamu-pass", mode: "all" });
ok("3 公開用キーだけの呼び出し（ログイン情報なし）は何も実行しない", r.status === 401, r.status);
r = await handleDeletionRequest({ admin, verifyPassword: verify, userJwt: makeJwt({ sub: MIKE, role: "authenticated" }).slice(0, -3) + "AAA", password: "mike-pass", mode: "all" });
ok("3 偽造したログイン情報は 401（認証サーバーが拒否）", r.status === 401 && active(MIKE) === "0", r.status);
// 管理用の操作を公開用キーで行おうとしても通らない（ゲートウェイの確認）
const bad = adminClient({ url: gw.url, secret: KEYS.publishable, publishable: KEYS.publishable });
const d = await bad.auth.admin.deleteUser(MIKE); const rp = await bad.rpc("account_purge_claim");
ok("3 公開用キーでは、会員の削除も完全削除の関数も実行できない", d.error && d.error.status === 403 && rp.error && rp.error.status === 403 && q(`select count(*) from auth.users where id='${MIKE}'`) === "1", { d: d.error, rp: rp.error });
// 旧来のやり方（秘密キーを Authorization に入れる）だと、新しい形式では拒否されることも確認（今回の修正が必要だった理由）
const old = await fetch(`${gw.url}/rest/v1/rpc/account_purge_claim`, { method: "POST", headers: { apikey: KEYS.secret, Authorization: `Bearer ${KEYS.secret}`, "Content-Type": "application/json" }, body: "{}" });
ok("3 （参考）秘密キーを Authorization に入れる従来の送り方は、新しい形式では拒否される", old.status === 401);

// ---- 4. 完全削除（新しい形式のキー・HTTP）
q(`update aimuse_private.account_deletions set purge_after=now()-interval '1 minute' where user_id='${HAMU}' and status='pending'`);
let p = await runPurge(admin);
ok("4 データベースの完全削除スイッチがオフの間は、何もしない", p.processed === 0 && active(HAMU) === "1", p);
q("update aimuse_private.settings set value='on' where key='account_purge_enabled'");
p = await runPurge(admin);
const left = q(`select (select count(*) from auth.users where id='${HAMU}')+(select count(*) from storage.objects where name like '${HAMU}%' or owner_id='${HAMU}')+(select count(*) from public.tracks where user_id='${HAMU}')`);
ok("4 オンにすると、新しい形式のキーで Storage・データ・会員の削除まで完了", p.done === 1 && left === "0" && q(`select status from aimuse_private.account_deletions where user_id='${HAMU}' order by requested_at desc limit 1`) === "done", { p, left });
ok("4 ほかの会員のファイル・データは無事", q(`select count(*) from storage.objects where name like '${RYO}%' or name like '${MIKE}%'`) === "4" && q(`select count(*) from auth.users where id in ('${RYO}','${MIKE}')`) === "2");

// ---- 5. 公開されるファイルに秘密キーが入っていない
const pub = ["public/index.html", "public/config.js", "public/sw.js", "public/offline.html", "public/manifest.webmanifest"].map((f) => fs.readFileSync(new URL("../../" + f, import.meta.url), "utf8")).join("\n");
ok("5 公開されるファイルに秘密キー（sb_secret_ / service_role の JWT）が無い", !/sb_secret_[A-Za-z0-9]/.test(pub) && !/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/.test(pub));
const fnA = fs.readFileSync(new URL("../../supabase/functions/account-delete-request/supa.js", import.meta.url), "utf8"), fnB = fs.readFileSync(new URL("../../supabase/functions/account-purge/supa.js", import.meta.url), "utf8");
ok("5 2つの関数の接続部品（supa.js）は同じ内容", fnA === fnB);

gw.close();
const f = R.filter((x) => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach((x) => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
