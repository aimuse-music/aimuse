// account-purge の呼び出し元の確認（合言葉を金庫で照合する方式）のテスト
// 使い方：node tests/edge/test_purge_caller.mjs
import { checkCaller } from "../../supabase/functions/account-purge/purge.js";
const R = []; const ok = (n, c, i) => { R.push(!!c); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i) : ""}`); };
const VAULT = "v".repeat(64);
const calls = [];
const sb = (mode = "ok") => ({ rpc: async (name, args) => { calls.push({ name, len: (args.p_secret || "").length });
  if (mode === "missing") return { data: null, error: { status: 404, message: "Could not find the function public.purge_secret_matches" } };
  if (mode === "down") return { data: null, error: { status: 0, message: "network" } };
  return { data: args.p_secret === VAULT, error: null }; } });
ok("金庫の合言葉と一致 → ok", await checkCaller(sb(), VAULT, null) === "ok");
ok("違う合言葉 → forbidden", await checkCaller(sb(), "x".repeat(64), null) === "forbidden");
calls.length = 0;
ok("短い・空の合言葉は、データベースに問い合わせずに forbidden", await checkCaller(sb(), "short", null) === "forbidden" && await checkCaller(sb(), null, null) === "forbidden" && calls.length === 0);
ok("v1.12 が未適用（関数が無い）→ not_configured（何もしない）", await checkCaller(sb("missing"), VAULT, null) === "not_configured");
ok("データベースに届かない → not_configured（何もしない）", await checkCaller(sb("down"), VAULT, null) === "not_configured");
calls.length = 0;
ok("関数の設定に AIMUSE_PURGE_SECRET がある場合は、その値と比べる（金庫は使わない）", await checkCaller(sb(), "e".repeat(40), "e".repeat(40)) === "ok" && await checkCaller(sb(), VAULT, "e".repeat(40)) === "forbidden" && calls.length === 0);
ok("AIMUSE_PURGE_SECRET が短すぎる場合は使わず、金庫で照合", await checkCaller(sb(), VAULT, "short") === "ok");
const bad = R.filter(x => !x).length; console.log(`\n合計 ${R.length} 件 / 不合格 ${bad} 件`); process.exit(bad ? 1 : 0);
