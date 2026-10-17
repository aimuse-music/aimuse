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
      calls.push("storage.remove"); (this.removed ||= []).push(...names.map(n => bucket + ":" + n));
      if (fail.storage && fail.storage-- > 0) return { data: null, error: { message: "storage 503 (injected)" } };
      if (fail.storageSilently) return { data: [], error: null };   // 成功と返すが実際には消えない
      if (fail.bucket && fail.bucket[bucket] && fail.bucket[bucket]-- > 0) return { data: null, error: { message: `storage 503 on ${bucket} (injected)` } };
      if (fail.partial && fail.partial-- > 0) names = names.slice(0, Math.ceil(names.length / 2));   // 半分だけ消えて「成功」と返る
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

// このテストは受付「全員」・完全削除「オン」の状態で行う（スイッチ自体は test_new_keys.mjs と test_v19.py で確認）
psql("update aimuse_private.settings set value='all' where key='account_deletion_mode'; update aimuse_private.settings set value='on' where key='account_purge_enabled';");
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

// ---- 8. ファイルの種類・保存先の違い・途中失敗・再試行（音源・ジャケット・アイコン・背景・削除済み曲・後から増えたファイル）
const U5 = "55555555-5555-4555-8555-555555555555", RYO = "11111111-1111-4111-8111-111111111111";
const tid = (i) => `aaaa5555-0000-4000-8000-${String(i).padStart(12, "0")}`;
const setup8 = psql(`insert into auth.users (id,email,email_confirmed_at) values ('${U5}','u5@example.com',now());
  insert into public.tracks (id,user_id,title,artist,genre,tool,tool_name,audio_path,image_path,status)
    select '${tid(1)}'::uuid,'${U5}'::uuid,'曲1','ゴゴ','J-POP','Suno','Suno','${U5}/${tid(1)}.mp3','${U5}/${tid(1)}.jpg','public' union all
    select '${tid(2)}'::uuid,'${U5}','曲2','ゴゴ','J-POP','Suno','Suno','${U5}/${tid(2)}.wav','${U5}/${tid(2)}.png','pending' union all
    select '${tid(3)}'::uuid,'${U5}','曲3（音源ファイルが既に無い）','ゴゴ','J-POP','Suno','Suno','${U5}/${tid(3)}.m4a',null,'hidden';
  insert into storage.objects (bucket_id,name,owner_id) values
    ('audio','${U5}/${tid(1)}.mp3','${U5}'),('covers','${U5}/${tid(1)}.jpg','${U5}'),
    ('audio','${U5}/${tid(2)}.wav','${U5}'),('covers','${U5}/${tid(2)}.png','${U5}'),
    ('audio','${U5}/${tid(9)}.mp3','${U5}'),('covers','${U5}/${tid(9)}.heic','${U5}'),
    ('avatars','avatar-5e5e5e5e-0000-4000-8000-000000000001.jpg','${U5}'),
    ('avatars','header-5e5e5e5e-0000-4000-8000-000000000002.webp','${U5}'),
    ('avatars','avatar-5e5e5e5e-0000-4000-8000-000000000003.png','${U5}');
  insert into storage.objects (bucket_id,name,owner_id)
    select 'audio', '${U5}/' || gen_random_uuid() || '.mp3', '${U5}' from generate_series(1,620);
  update public.profiles set avatar_path='avatar-5e5e5e5e-0000-4000-8000-000000000001.jpg', header_path='header-5e5e5e5e-0000-4000-8000-000000000002.webp' where id='${U5}';
  insert into aimuse_private.track_deletions (track_id, track) values ('${tid(9)}', jsonb_build_object('id','${tid(9)}','user_id','${U5}','audio_path','${U5}/${tid(9)}.mp3','image_path','${U5}/${tid(9)}.heic','status','public'));`);
if (setup8.err) console.log('setup8:', setup8.err);
const before = { ryo: q(`select count(*) from storage.objects where name like '${RYO}%'`), total: q(`select count(*) from storage.objects`) };
const u5files = +q(`select count(*) from storage.objects where name like '${U5}%' or owner_id='${U5}'`);
// 申請（申請時にファイル一覧を記録）
psql(`begin; set local role service_role; set local request.jwt.claims='{"role":"service_role"}'; select * from public.account_request_deletion('${U5}'); commit;`);
const listed = q(`select count(*) from aimuse_private.account_deletion_files f join aimuse_private.account_deletions d on d.id=f.request_id where d.user_id='${U5}'`);
ok("8 申請時に、音源・ジャケット・アイコン・背景・削除済み曲・使われていないファイル・参照先が無いファイルまで一覧に記録",
   +listed === u5files + 1, { listed, u5files });   // +1 = 参照されているが実体の無い曲3の音源
// 申請の後に、管理者の作業などで本人のフォルダにファイルが増えた
psql(`insert into storage.objects (bucket_id,name,owner_id) values ('covers','${U5}/${tid(8)}.jpg',null)`);
psql(`update aimuse_private.account_deletions set purge_after=now()-interval '1 minute' where user_id='${U5}' and status='pending'`);
// 1回目：アイコン・背景の保存場所（avatars）だけ失敗
c = fakeClient({ bucket: { avatars: 1 } }); const c8a = c;
r = await runPurge(c);
const left1 = +q(`select count(*) from storage.objects where name like '${U5}%' or owner_id='${U5}'`);
ok("8 アイコン・背景の保存場所だけ失敗：完了にせず、会員とデータは残る", r.failed === 1 && st(U5).startsWith("processing") && q(`select count(*) from auth.users where id='${U5}'`) === "1" && q(`select count(*) from public.tracks where user_id='${U5}'`) === "3", { r, left1 });
ok("8 失敗した時点までに消えたファイルは「削除済み」と記録", +q(`select count(*) from aimuse_private.account_deletion_files f join aimuse_private.account_deletions d on d.id=f.request_id where d.user_id='${U5}' and f.deleted_at is not null`) > 0);
// 2回目：半分だけ消えて「成功」と返る Storage
later(); c = fakeClient({ partial: 3 });
r = await runPurge(c);
ok("8 一部しか消えなくても、残りを次の回で削除して最後まで進む", r.done === 1 && st(U5).startsWith("done"), { r, st: st(U5) });
ok("8 本人のファイルはすべて削除（後から増えたファイル・500件を超える分も含む）", q(`select count(*) from storage.objects where name like '${U5}%' or owner_id='${U5}'`) === "0");
ok("8 100件ずつに分けて削除している（600件超で7回以上）", c8a.calls.filter(x => x === "storage.remove").length >= 7, c8a.calls.filter(x => x === "storage.remove").length);
ok("8 ほかの会員のファイルは1つも消えていない", q(`select count(*) from storage.objects where name like '${RYO}%'`) === before.ryo && +q(`select count(*) from storage.objects`) === +before.total + 1 - u5files - 1, { before, now: q(`select count(*) from storage.objects`) });
ok("8 削除済み曲の記録（30日復元用）と、他の曲の記録に含まれるレビューも残らない", q(`select count(*) from aimuse_private.track_deletions where track->>'user_id'='${U5}'`) === "0");

const f = R.filter(x => !x[1]); console.log(`\n合計 ${R.length} 件 / 不合格 ${f.length} 件`); f.forEach(x => console.log("  FAIL:", x[0]));
process.exit(f.length ? 1 : 0);
