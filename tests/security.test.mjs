// AIMUSE BOOST 自動テスト（本番のデータには一切アクセスしません）
// 実行：node --test tests/
// Supabase・AI への通信はすべて偽物（モック）に置き換えて、サーバー処理の安全性を確認します。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const root = new URL("../", import.meta.url).pathname;
const shared = await import(new URL("../lib/shared.js", import.meta.url));
const gen = await import(new URL("../functions/api/generate.js", import.meta.url));
const go = await import(new URL("../functions/go/[code].js", import.meta.url));
const out = await import(new URL("../functions/out/[id].js", import.meta.url));
const promo = await import(new URL("../functions/s/[id].js", import.meta.url));
const cover = await import(new URL("../functions/cover/[id].js", import.meta.url));

const TRACK = "11111111-2222-3333-4444-555555555555";
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1";

// fetch の偽物：呼ばれたURLと本文を記録し、handler の返り値を返す
function mockFetch(handler) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const body = init.body ? JSON.parse(init.body) : null;
    calls.push({ url: String(url), body, headers: init.headers || {} });
    const r = await handler(String(url), body, init);
    if (r instanceof Response) return r;
    return new Response(JSON.stringify(r.json), { status: r.status || 200, headers: { "content-type": "application/json" } });
  };
  return calls;
}
const req = (url, headers = {}, init = {}) => new Request(url, { headers: { "user-agent": UA, ...headers }, ...init });

/* ---------------- AI宣伝文の生成 ---------------- */
const aiOk = { run: async () => ({ response: JSON.stringify({
  x: { body: "夜に聴きたい🌙", hashtags: ["AIMUSE", "#AI音楽", "<script>"] },
  instagram: { body: "1行目\n2行目", hashtags: ["AIMUSE"] },
  tiktok: { body: "a", hashtags: [] },
  youtube: { title: "t", body: "b", hashtags: [] },
  emojis: ["🌙", "abc", "<img src=x>", "✨"],
}) }) };
const genReq = (body, jwt = "user.jwt.token") => new Request("https://b.test/api/generate", {
  method: "POST", headers: { "content-type": "application/json", ...(jwt ? { authorization: "Bearer " + jwt } : {}) }, body: JSON.stringify(body),
});

test("AI生成：AI未接続なら503（APIキー不要の設計）", async () => {
  const r = await gen.onRequestPost({ request: genReq({ title: "a", artist: "b" }), env: {} });
  assert.equal(r.status, 503);
});
test("AI生成：ログインなしは401", async () => {
  const r = await gen.onRequestPost({ request: genReq({ title: "a", artist: "b" }, null), env: { AI: aiOk } });
  assert.equal(r.status, 401);
});
test("AI生成：管理者でなければ403（AIは呼ばれない）", async () => {
  let called = false;
  mockFetch(() => ({ status: 400, json: { message: "管理者のみ" } }));
  const r = await gen.onRequestPost({ request: genReq({ title: "a", artist: "b" }), env: { AI: { run: async () => { called = true; } } } });
  assert.equal(r.status, 403); assert.equal(called, false);
});
test("AI生成：1日の上限を超えたら429（AIは呼ばれない）", async () => {
  let called = false;
  mockFetch(() => ({ json: { allowed: false, used: 30, limit: 30 } }));
  const r = await gen.onRequestPost({ request: genReq({ title: "a", artist: "b" }), env: { AI: { run: async () => { called = true; } } } });
  assert.equal(r.status, 429); assert.equal(called, false);
});
test("AI生成：利用回数の確認はログイン本人の権限で行う", async () => {
  const calls = mockFetch(() => ({ json: { allowed: true, used: 1, limit: 30 } }));
  await gen.onRequestPost({ request: genReq({ title: "a", artist: "b" }, "my.jwt"), env: { AI: aiOk } });
  assert.match(calls[0].url, /\/rest\/v1\/rpc\/boost_ai_take_quota$/);
  assert.equal(calls[0].headers.authorization, "Bearer my.jwt");
});
test("AI生成：曲名なしは400", async () => {
  mockFetch(() => ({ json: { allowed: true } }));
  const r = await gen.onRequestPost({ request: genReq({ title: "", artist: "b" }), env: { AI: aiOk } });
  assert.equal(r.status, 400);
});
test("AI生成：結果の整形（ハッシュタグ・絵文字の除外・改行の保持）", async () => {
  mockFetch(() => ({ json: { allowed: true, used: 1, limit: 30 } }));
  const r = await gen.onRequestPost({ request: genReq({ title: "曲", artist: "人", tone: "cool" }), env: { AI: aiOk } });
  const j = await r.json();
  assert.equal(r.status, 200);
  assert.equal(j.result.x.hashtags.split(" ")[0], "#AIMUSE");
  assert.deepEqual(j.emojis, ["🌙", "✨"]);
  assert.equal(j.result.instagram.body, "1行目\n2行目");
  assert.ok(!JSON.stringify(j).includes("<img"));
});
test("AI生成：AIの無料枠切れは分かりやすいエラーに", async () => {
  mockFetch(() => ({ json: { allowed: true, used: 1, limit: 30 } }));
  const r = await gen.onRequestPost({ request: genReq({ title: "a", artist: "b" }), env: { AI: { run: async () => { throw new Error("4006: daily free allocation of 10,000 neurons exceeded"); } } } });
  assert.equal(r.status, 502); assert.equal((await r.json()).error, "ai_free_limit");
});

/* ---------------- 計測リンク /go ---------------- */
const goCtx = (code, headers, method = "GET") => ({ params: { code }, env: {}, request: req("https://b.test/go/" + code, headers, { method }) });

test("計測リンク：形式がおかしいコードはDBに問い合わせずAIMUSEへ", async () => {
  const calls = mockFetch(() => ({ json: null }));
  const r = await go.onRequestGet(goCtx("../../etc"));
  assert.equal(r.status, 302); assert.equal(r.headers.get("location"), "https://aimusemusic.com"); assert.equal(calls.length, 0);
});
test("計測リンク：人のクリックは記録し、重複防止クッキーを付ける", async () => {
  const calls = mockFetch(() => ({ json: `/s/${TRACK}?src=x` }));
  const r = await go.onRequestGet(goCtx("Abc1234"));
  assert.equal(calls[0].body.p_record, true);
  assert.equal(r.headers.get("location"), `https://b.test/s/${TRACK}?src=x`);
  const ck = r.headers.get("set-cookie");
  assert.match(ck, /^bg=1; Max-Age=1800; Path=\/go\/Abc1234; Secure; HttpOnly; SameSite=Lax$/);
});
test("計測リンク：30分以内の同じ端末からの再クリックは数えない", async () => {
  const calls = mockFetch(() => ({ json: "/s/" + TRACK }));
  const r = await go.onRequestGet(goCtx("Abc1234", { cookie: "foo=2; bg=1" }));
  assert.equal(calls[0].body.p_record, false); assert.equal(r.status, 302); assert.equal(r.headers.get("set-cookie"), null);
});
test("計測リンク：SNSのプレビュー取得・ロボットは数えない", async () => {
  for (const ua of ["Twitterbot/1.0", "facebookexternalhit/1.1", "curl/8.0", ""]) {
    const calls = mockFetch(() => ({ json: "/s/" + TRACK }));
    await go.onRequestGet(goCtx("Abc1234", { "user-agent": ua }));
    assert.equal(calls[0].body.p_record, false, ua);
  }
  const calls = mockFetch(() => ({ json: "/s/" + TRACK }));
  await go.onRequestGet(goCtx("Abc1234", { "sec-purpose": "prefetch" }));
  assert.equal(calls[0].body.p_record, false);
});
test("計測リンク：HEADリクエストは数えない", async () => {
  const calls = mockFetch(() => ({ json: "/s/" + TRACK }));
  await go.onRequestHead(goCtx("Abc1234", {}, "HEAD"));
  assert.equal(calls[0].body.p_record, false);
});
test("計測リンク：宣伝ページ（/s/<楽曲ID>）以外には絶対に移動しない", async () => {
  for (const bad of ["javascript:alert(1)", "https://evil.example/", "//evil.example/s/" + TRACK, "/s/" + TRACK + "?src=x&next=https://evil.example",
                     "/s/../go/x", "/s/" + TRACK + "/../../evil", "https://b.test/s/" + TRACK, "/S/" + TRACK, "/s/" + TRACK + "\n"]) {
    mockFetch(() => ({ json: bad }));
    const r = await go.onRequestGet(goCtx("Abc1234"));
    assert.equal(r.headers.get("location"), "https://aimusemusic.com", bad);
  }
  mockFetch(() => ({ json: "/s/" + TRACK }));
  const ok = await go.onRequestGet(goCtx("Abc1234"));
  assert.equal(ok.headers.get("location"), "https://b.test/s/" + TRACK);
});
test("計測リンク：計測サーバー障害時もAIMUSEへ移動", async () => {
  mockFetch(() => { throw new Error("down"); });
  const r = await go.onRequestGet(goCtx("Abc1234"));
  assert.equal(r.status, 302); assert.equal(r.headers.get("location"), "https://aimusemusic.com");
});

/* ---------------- 「AIMUSEで聴く」 /out ---------------- */
const outCtx = (id, headers, q = "?src=x", env = {}) => ({ params: { id }, env, request: req(`https://b.test/out/${id}${q}`, headers) });

test("AIMUSEで聴く：記録してUTM付きでAIMUSEへ。重複防止クッキーを付ける", async () => {
  const calls = mockFetch(() => ({ json: true }));
  const r = await out.onRequestGet(outCtx(TRACK));
  assert.equal(calls[0].body.p_track, TRACK);
  const loc = new URL(r.headers.get("location"));
  assert.equal(loc.origin, "https://aimusemusic.com");
  assert.equal(loc.searchParams.get("utm_source"), "x");
  assert.match(r.headers.get("set-cookie"), new RegExp(`^bo=1; .*Path=/out/${TRACK};`));
});
test("AIMUSEで聴く：非公開の曲（記録されなかった）はクッキーを付けない", async () => {
  mockFetch(() => ({ json: false }));
  const r = await out.onRequestGet(outCtx(TRACK));
  assert.equal(r.headers.get("set-cookie"), null);
});
test("AIMUSEで聴く：再クリック・ロボットは記録しない", async () => {
  let calls = mockFetch(() => ({ json: true }));
  await out.onRequestGet(outCtx(TRACK, { cookie: "bo=1" }));
  assert.equal(calls.length, 0);
  calls = mockFetch(() => ({ json: true }));
  await out.onRequestGet(outCtx(TRACK, { "user-agent": "Slackbot" }));
  assert.equal(calls.length, 0);
});
test("AIMUSEで聴く：不正なIDやsrcは無害化", async () => {
  const calls = mockFetch(() => ({ json: true }));
  const r = await out.onRequestGet(outCtx("not-a-uuid"));
  assert.equal(r.status, 302); assert.equal(calls.length, 0);
  mockFetch(() => ({ json: true }));
  const r2 = await out.onRequestGet(outCtx(TRACK, {}, "?src=%3Cscript%3E"));
  assert.equal(new URL(r2.headers.get("location")).searchParams.get("utm_source"), "boost");
});
test("曲ページ誘導：設定すれば曲ページへ。AIMUSE以外のサイトは無視", async () => {
  mockFetch(() => ({ json: true }));
  const r = await out.onRequestGet(outCtx(TRACK, {}, "?src=tiktok", { AIMUSE_TRACK_URL: "https://aimusemusic.com/#track={id}" }));
  const loc = r.headers.get("location");
  assert.ok(loc.startsWith("https://aimusemusic.com/?utm_source=tiktok"), loc);
  assert.ok(loc.endsWith(`#track=${TRACK}`), loc);
  mockFetch(() => ({ json: true }));
  const bad = await out.onRequestGet(outCtx(TRACK, {}, "", { AIMUSE_TRACK_URL: "https://evil.example/{id}" }));
  assert.ok(bad.headers.get("location").startsWith("https://aimusemusic.com/?"));
  assert.equal(shared.trackPageUrl({ AIMUSE_TRACK_URL: "http://aimusemusic.com/{id}" }, TRACK), null);
});

/* ---------------- 宣伝ページ /s ---------------- */
const sCtx = (id) => ({ params: { id }, env: {}, request: req(`https://b.test/s/${id}?src=x`) });

test("宣伝ページ：公開中の曲だけを取得し、曲名などは無害化して表示", async () => {
  const calls = mockFetch(() => ({ json: [{ id: TRACK, title: `<script>alert(1)</script>"'`, artist: "<b>A</b>", genre: "<i>", image_path: null }] }));
  const r = await promo.onRequestGet(sCtx(TRACK));
  const h = await r.text();
  assert.equal(r.status, 200);
  assert.match(calls[0].url, /status=eq\.public/);
  assert.ok(!h.includes("<script>alert"), "scriptが無害化されていない");
  assert.ok(!h.includes("<b>A</b>"));
  assert.ok(h.includes("&lt;script&gt;"));
  assert.match(r.headers.get("content-security-policy"), /default-src 'none'/);
});
test("宣伝ページ：非公開・存在しない曲は404", async () => {
  mockFetch(() => ({ json: [] }));
  const r = await promo.onRequestGet(sCtx(TRACK));
  assert.equal(r.status, 404);
});
test("宣伝ページ：不正なIDはDBに問い合わせない", async () => {
  const calls = mockFetch(() => ({ json: [] }));
  const r = await promo.onRequestGet(sCtx("1 or 1=1"));
  assert.equal(r.status, 404); assert.equal(calls.length, 0);
});

/* ---------------- ジャケット画像 /cover ---------------- */
test("ジャケット：画像以外（SVG等）は返さない", async () => {
  mockFetch((url) => {
    if (url.includes("/rest/v1/tracks")) return { json: [{ id: TRACK, title: "a", artist: "b", image_path: "u/x.svg" }] };
    if (url.includes("/storage/v1/object/sign/")) return { json: { signedURL: "/object/sign/covers/u/x.svg?token=t" } };
    return new Response("<svg onload=alert(1)>", { headers: { "content-type": "image/svg+xml" } });
  });
  const r = await cover.onRequestGet({ params: { id: TRACK }, env: {} });
  assert.equal(r.status, 404);
});
test("ジャケット：非公開の曲は404", async () => {
  mockFetch(() => ({ json: [] }));
  const r = await cover.onRequestGet({ params: { id: TRACK }, env: {} });
  assert.equal(r.status, 404);
});

/* ---------------- 公開ファイルの点検 ---------------- */
function files(dir) {
  return readdirSync(dir).flatMap((f) => { const p = join(dir, f); return statSync(p).isDirectory() ? files(p) : [p]; });
}
test("公開ファイル・サーバー処理に秘密鍵が含まれていない", () => {
  const SECRET = /service_role|sb_secret_|sk-ant-|sk-[A-Za-z0-9]{20,}|eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\.eyJ[^"']*c2VydmljZV9yb2xl|BEGIN (RSA )?PRIVATE KEY/;
  for (const f of [...files(join(root, "public")), ...files(join(root, "functions")), ...files(join(root, "lib"))]) {
    const s = readFileSync(f, "utf8").replace(/「service_role」/g, "");
    assert.ok(!SECRET.test(s), "秘密情報の疑い: " + f);
  }
});
test("ブラウザに置くキーは公開用キーだけ", () => {
  const s = readFileSync(join(root, "public/config.js"), "utf8");
  const key = s.match(/supabaseAnonKey:\s*"([^"]+)"/)[1];
  assert.ok(key.startsWith("sb_publishable_"), "公開用キーではありません");
});
test("セキュリティヘッダー（CSP・埋め込み禁止・検索除外）", () => {
  const h = readFileSync(join(root, "public/_headers"), "utf8");
  for (const k of ["Content-Security-Policy", "X-Frame-Options: DENY", "X-Content-Type-Options: nosniff", "X-Robots-Tag: noindex", "frame-ancestors 'none'"]) assert.ok(h.includes(k), k);
});
test("アプリは計測リンクに移動先URLを保存しない", () => {
  const s = readFileSync(join(root, "public/index.html"), "utf8");
  assert.ok(!/destination/.test(s));
});
test("アプリはAIMUSEの公開曲だけを読み、AIMUSEのテーブルへ書き込まない", () => {
  const s = readFileSync(join(root, "public/index.html"), "utf8");
  assert.match(s, /from\("tracks"\)\.select\([^)]*\)\.eq\("status", "public"\)/);
  const writes = [...s.matchAll(/from\("([a-z_]+)"\)\.(insert|update|delete|upsert)\(/g)].map((m) => m[1]);
  assert.ok(writes.length > 0);
  for (const t of writes) assert.ok(t.startsWith("boost_"), "AIMUSE本体のテーブルへの書き込み: " + t);
});
test("アプリの画面プログラムに文法エラーがない", () => {
  const s = readFileSync(join(root, "public/index.html"), "utf8");
  const scripts = [...s.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
  assert.ok(scripts.length > 0);
  for (const code of scripts) new Function(code); // 文法エラーなら例外
});
test("追加SQL：既存テーブルの変更・削除をしない／全BOOSTテーブルにRLS", () => {
  const s = readFileSync(join(root, "supabase/boost_schema.sql"), "utf8").replace(/--.*$/gm, "");
  assert.ok(!/drop\s+table/i.test(s), "drop table がある");
  assert.ok(!/(alter|drop)\s+(table|policy)[^;]*\b(public\.)?(profiles|tracks|plays|favorites|follows|reviews|reports)\b/i.test(s), "既存テーブルを変更している");
  assert.ok(!/\b(update|delete\s+from|insert\s+into)\s+(public\.)?(profiles|tracks)\b/i.test(s), "既存データを変更している");
  const tables = [...s.matchAll(/create table if not exists public\.(\w+)/g)].map((m) => m[1]);
  for (const t of tables) {
    assert.ok(t.startsWith("boost_"), t);
    assert.ok(new RegExp(`alter table public\\.${t}\\s+enable row level security`).test(s), "RLSなし: " + t);
  }
});
