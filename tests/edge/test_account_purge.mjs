// Edge Function「account-purge」の処理本体（purge.js）のテスト
// データベースは手元の PostgreSQL（Supabase と同じ権限）を service_role で実際に呼び出し、
// Storage と auth.admin は同じデータベースの storage.objects / auth.users を操作する偽物で再現（失敗も注入できる）。
// 使い方: node tests/edge/test_account_purge.mjs <db名>（v1.9＋seed_v19 を入れたDB）
import { execFileSync } from "node:child_process";
import { runPurge, sameSecret } from "../../supabase/functions/account-purge/purge.js";

const DB = process.argv[2] || "v19e";
const psql = (sql) => {
  try {
    return { out: execFileSync("psql", ["-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-X", "-At", "-q", "-d", DB, "-v", "ON_ERROR_STOP=1"], { input: sql, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim(), err: null };
  } catch (e) { return { out: "", err: String(e.stderr || e.message).split("\n").find(l => l.includes("ERROR")) || String(e.message) }; }
};
const lit = (v) => v === null || v === undefined ? "null" : `'${String(v).replace(/'/g, "''")}'`;
const R = []; const ok = (n, c, i) => { R.push([n, !!c]); console.log(`[${c ? "PASS" : "FAIL"}] ${n}${i !== undefined ? "  → " + JSON.stringify(i) : ""}`); };

function fakeClient(fail = {}) {
  const calls = [];
  return {
    calls, fail,
    async rpc(name, args = {}) {
      calls.push(name);
      if (fail.rpc && fail.rpc[name] && fail.rpc[name]-- > 0) return { data: null, error: { message: "network error (injected)" } };
      const params = Object.entries(args).map(([k, v]) => `${k} => ${lit(v)}`).join(", ");
      const sql = `begin; set local role service_role; set local request.jwt.claims='{"role":"service_role"}';
        select coalesce(json_agg(t), '[]') from (select * from public.${name}(${params})) t; commit;`;
      const { out, err } = psql(sql);
      if (err) return { data: null, error: { message: err.replace(/^.*ERROR:\s*/, "") } };
      const rows = JSON.parse(out || "[]");
      // 戻り値が1つの値（void・integer）の関数は、その値だけを返す（supabase-js と同じ）
      if (rows.length === 1 && Object.keys(rows[0]).length === 1 && Object.keys(rows[0])[0] === name) return { data: rows[0][name], error: null };
      return { data: rows, error: null };
    },
    storage: { from: (bucket) => ({ async remove(names) {
      calls.push("storage.remove");
      if (fail.storage && fail.storage-- > 0) return { data: null, error: { message: "storage 503 (injected)" } };
      if (fail.storageSilently) return { data: [], error: null };   // 成功と返すが実際には消えない
      psql(`delete from storage.objects where bucket_id=${lit(bucket)} and name in (${names.map(lit).join(",")});`);
      return { data: names.map(n => ({ name: n })), error: null };
    } }) },
    auth: { admin: { async deleteUser(id) {
      calls.push("auth.deleteUser");
      if (fail.auth && fail.auth-- > 0) return { data: null, error: { status: 500, message: "auth 500 (injected)" } };
      const { out } = psql(`delete from auth.users where id=${lit(id)} returning id;`);
      return out ? { data: {}, error: null } : { data: null, error: { status: 404, message: "User not found" } };
    } } }
  };
}
const HAMU = "22222222-2222-4222-8222-222222222222", MIKE = "33333333-3333-4333-8333-333333333333";
const q = (sql) => psql(sql).out;
// 1時間たったことにする（失敗後の待ち時間を終わらせる）
const later = () => psql(`update aimuse_private.account_deletions set locked_until=now()-interval '1 second' where status='processing'`);
const st = (u) => q(`select status||'|'||attempts from aimuse_private.account_deletions where user_id='${u}' order by requested_at desc limit 1`);

// ---- 準備：ハムとミケが退会を申請済みで、30日が過ぎた状態
psql(`insert into aimuse_private.account_deletions (user_id,purge_after,hidden_tracks) values ('${HAMU}', now()-interval '1 day', '[]'), ('${MIKE}', now()+interval '10 days', '[]');
      update public.tracks set status='hidden' where user_id in ('${HAMU}','${MIKE}');`);
psql(`select aimuse_private.collect_account_files(id, user_id) from aimuse_private.account_deletions;`);
const hamuFiles = +q(`select count(*) from storage.objects where name like '${HAMU}%' or owner_id='${HAMU}'`);

ok("0 合言葉の比較：一致・不一致・空", sameSecret("a".repeat(40), "a".repeat(40)) && !sameSecret("a".repeat(40), "a".repeat(39) + "b") && !sameSecret("", "") && !sameSecret("x".repeat(40), ""));

// ---- 1. Storage が途中で失敗 → 失敗を記録、会員は残る
let c = fakeClient({ storage: 1 });
let r = await runPurge(c);
ok("1 Storage の失敗：完了にせず失敗として記録", r.done === 0 && r.failed === 1 && st(HAMU) === "processing|1", { r, st: st(HAMU) });
ok("1 その時点では会員・曲は残っている（データだけ先に消えない）", q(`select count(*) from auth.users where id='${HAMU}'`) === "1" && +q(`select count(*) from public.tracks where user_id='${HAMU}'`) > 0);
ok("1 返す結果に会員IDは含まない", !JSON.stringify(r).includes(HAMU), r);

ok("1 失敗直後の同じ実行・次の実行ではすぐに再試行しない（1時間おく）", r.processed === 1 && (await runPurge(fakeClient())).processed === 0);

// ---- 2. 削除したと返すのに実際は消えていない Storage → 先へ進まない
later(); c = fakeClient({ storageSilently: true });
r = await runPurge(c);
ok("2 消えていないファイルを「削除済み」にしない", r.failed === 1 && q(`select count(*) from auth.users where id='${HAMU}'`) === "1", r);

// ---- 3. 会員の削除（auth）で失敗 → ファイル・データは消えたが「完了」にはしない
later(); c = fakeClient({ auth: 1 });
r = await runPurge(c);
ok("3 会員の削除に失敗したら完了にしない", r.failed === 1 && st(HAMU).startsWith("processing") && q(`select count(*) from auth.users where id='${HAMU}'`) === "1", { r, st: st(HAMU) });
ok("3 ファイルとデータは削除済み", q(`select count(*) from storage.objects where name like '${HAMU}%' or owner_id='${HAMU}'`) === "0" && q(`select count(*) from public.tracks where user_id='${HAMU}'`) === "0", hamuFiles);

// ---- 4. 次回の実行で続きから（ファイル・データは済んでいるので会員削除と完了だけ）
later(); c = fakeClient();
r = await runPurge(c);
ok("4 次回の実行で完了まで進む", r.done === 1 && st(HAMU).startsWith("done"), { r, st: st(HAMU) });
ok("4 会員と関連データが消えた", q(`select (select count(*) from auth.users where id='${HAMU}')+(select count(*) from public.profiles where id='${HAMU}')+(select count(*) from public.follows where user_id='${HAMU}')`) === "0");
ok("4 済んだ手順（ファイル削除）は繰り返さない", c.calls.filter(x => x === "storage.remove").length === 0, c.calls);

// ---- 5. 30日前のミケは対象外。もう一度動かしても何もしない
r = await runPurge(fakeClient());
ok("5 対象がなければ何もしない（ミケは期限前なので残る）", r.processed === 0 && st(MIKE) === "pending|0" && q(`select count(*) from auth.users where id='${MIKE}'`) === "1", r);

// ---- 6. 同時に2つ動いた場合
psql(`update aimuse_private.account_deletions set purge_after=now()-interval '1 minute' where user_id='${MIKE}'`);
const [a, b] = await Promise.all([runPurge(fakeClient()), runPurge(fakeClient())]);
ok("6 同時に2つ動かしても、片方だけが処理して完了", a.done + b.done === 1 && a.failed + b.failed === 0 && st(MIKE).startsWith("done"), { a, b, st: st(MIKE) });
ok("6 Ryo（管理者）のデータとファイルは無事", q(`select count(*) from storage.objects where name like '11111111%'`) === "3" && q(`select count(*) from public.tracks where user_id='11111111-1111-4111-8111-111111111111'`) === "3");

// ---- 7. 会員が別の方法ですでに消えていた場合（404）も完了できる
psql(`insert into auth.users (id,email,email_confirmed_at) values ('44444444-4444-4444-8444-444444444444','x@example.com',now());
      insert into aimuse_private.account_deletions (user_id,purge_after) values ('44444444-4444-4444-8444-444444444444', now()-interval '1 day');`);
c = fakeClient(); const orig = c.auth.admin.deleteUser;
c.auth.admin.deleteUser = async (id) => { psql(`delete from auth.users where id='${id}'`); return { data: null, error: { status: 404, message: "User not found" } }; };
r = await runPurge(c);
ok("7 会員がすでに無い（404）場合も、無いことを確認して完了", r.done === 1 && st("44444444-4444-4444-8444-444444444444").startsWith("done"), r);

const f = R.filter(x => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
