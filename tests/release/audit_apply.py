#!/usr/bin/env python3
"""本番に近いデータ（v1.5）に v1.6〜v1.10 を SQL Editor と同じ「1回の実行＝1つのまとまり」で適用し、
・既存データが1件も変わらないこと（既存の列のみで比較）
・各段階の元に戻す用SQL（rollback）で、関数・トリガー・アクセスルール・権限が適用前と完全に同じに戻ること
・戻したあと、もう一度適用できること
を確認する。使い方: python3 audit_apply.py <DB名>"""
import subprocess, sys, json, hashlib
DB = sys.argv[1] if len(sys.argv) > 1 else "prodlike"
S = "/home/claude/aimuse/supabase/"
BASE = ["psql", "-h", "/home/pgtest/pg", "-p", "55432", "-U", "postgres", "-X", "-At", "-q", "-d", DB]
def run(sql=None, f=None, single=False):
    cmd = BASE + ["-v", "ON_ERROR_STOP=1"] + (["-1"] if single else []) + (["-f", f] if f else [])
    p = subprocess.run(cmd, input=sql, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return p.returncode, p.stdout.strip(), "\n".join(l for l in p.stderr.splitlines() if "ERROR" in l)
R = []
def ok(n, c, i=None): R.append((n, bool(c))); print(f"[{'PASS' if c else 'FAIL'}] {n}" + (f"  → {i}" if i is not None else ""))

TABLES = ["auth.users", "public.profiles", "public.artists", "public.tracks", "public.favorites", "public.follows", "public.reviews",
          "public.reports", "public.play_events", "storage.objects", "storage.buckets", "aimuse_private.settings", "aimuse_private.track_deletions"]
def cols(t):
    s, n = t.split(".")
    return run(f"select string_agg(quote_ident(column_name), ',' order by ordinal_position) from information_schema.columns where table_schema='{s}' and table_name='{n}'")[1]
COLS = {t: cols(t) for t in TABLES}
def data_snapshot():
    out = {}
    for t, c in COLS.items():
        out[t] = run(f"select count(*)||':'||coalesce(md5(string_agg(r, '|' order by r)),'') from (select row({c})::text r from {t}) x")[1]
    return out

CATALOG = """
select 'fn '||n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||') '||md5(pg_get_functiondef(p.oid))||' '||coalesce(p.proacl::text,'')
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','aimuse_private') and p.prokind='f'
union all select 'policy '||schemaname||'.'||tablename||' '||policyname||' '||cmd||' '||array_to_string(roles,',')||' '||coalesce(qual,'')||' '||coalesce(with_check,'')
  from pg_policies where schemaname in ('public','storage','aimuse_private')
union all select 'trigger '||c.relname||' '||t.tgname||' '||pg_get_triggerdef(t.oid) from pg_trigger t join pg_class c on c.oid=t.tgrelid where not t.tgisinternal
union all select 'tablepriv '||table_schema||'.'||table_name||' '||grantee||' '||privilege_type from information_schema.role_table_grants
  where table_schema in ('public','storage','aimuse_private') and grantee in ('anon','authenticated','service_role','PUBLIC')
union all select 'colpriv '||table_schema||'.'||table_name||'.'||column_name||' '||grantee||' '||privilege_type from information_schema.column_privileges
  where table_schema in ('public') and grantee in ('anon','authenticated')
union all select 'rls '||relname||' '||relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','aimuse_private') and c.relkind='r'
order by 1"""
def catalog(): return set(run(CATALOG)[1].splitlines())
# 元に戻しても残す（データを守るため）と決めているもの：追加した表・列に付く権限・RLS
KEEP = ("aimuse_private.account_deletions", "aimuse_private.account_deletion_files", "aimuse_private.reauth_failures", "aimuse_private.artist_name_history",
        "account_deletions ", "account_deletion_files ", "reauth_failures ", "artist_name_history ", "public.profiles.avatar_path", "public.profiles.header_path",
        "public.profiles.media_updated_at", "public.profiles.theme")
def diff(a, b): return sorted(x for x in (a ^ b) if not any(k in x for k in KEEP))

STEPS = [("v1.6", "migration_v1_6_profile.sql", "rollback_v1_6.sql"), ("v1.7", "migration_v1_7_follow_lists.sql", "rollback_v1_7.sql"),
         ("v1.8", "migration_v1_8_theme.sql", "rollback_v1_8.sql"), ("v1.9", "migration_v1_9_delete.sql", "rollback_v1_9.sql"),
         ("v1.10", "migration_v1_10_review_names.sql", "rollback_v1_10.sql")]
d0 = data_snapshot(); cats = [catalog()]
# ---- 適用（順番どおり・SQL Editor と同じく1ファイル＝1まとまり）
for name, mig, _ in STEPS:
    rc, o, e = run(f=S + mig, single=True)
    ok(f"{name} を本番に近いデータへ適用できる", rc == 0, e[:120] or None)
    cats.append(catalog())
d1 = data_snapshot()
changed = [t for t in TABLES if d0[t] != d1[t] and t != "storage.buckets"]
ok("既存のデータ（会員・曲・お気に入り・フォロー・レビュー・通報・再生記録・ファイル・削除記録）は1件も変わらない", not changed, changed or {k: d0[k].split(':')[0] for k in TABLES})
bk = run("select string_agg(id||'='||public::text, ',' order by id) from storage.buckets")[1]
ok("保存場所は avatars（公開）が増えるだけ。audio・covers（非公開）の設定は変わらない", bk == "audio=false,avatars=true,covers=false", bk)
pc = run(f=S + "production_checks.sql")[1].splitlines()
ok("本番確認SQL（r8）がすべて OK", len(pc) == 28 and all(l.split("|")[2] == "OK" for l in pc), [l.split("|")[0] for l in pc if l.split("|")[2] != "OK"])
# ---- 2回目の適用（やり直しても壊れない）
for name, mig, _ in STEPS:
    rc, o, e = run(f=S + mig, single=True)
    ok(f"{name} をもう一度実行しても壊れない", rc == 0 and catalog() == cats[-1] if name == "v1.10" else rc == 0, e[:100] or None)
ok("2回目の実行後もデータは変わらない", data_snapshot() == d1)
# ---- 順番を間違えた場合（元に戻す順番の保護）
rc, o, e = run(f=S + "rollback/rollback_v1_8.sql", single=True)
ok("元に戻す順番を間違えると、何も変更せずに中止（v1.9 が有効なのに v1.8 を戻そうとした）", rc != 0 and catalog() == cats[-1], e[:80])
# ---- 元に戻す（新しい順に）
for i in range(len(STEPS) - 1, -1, -1):
    name, _, rb = STEPS[i]
    rc, o, e = run(f=S + "rollback/" + rb, single=True)
    dd = diff(catalog(), cats[i])
    ok(f"{name} を元に戻すと、関数・トリガー・アクセスルール・権限が適用前と同じ", rc == 0 and not dd, (e[:100] or None, dd[:4]))
ok("元に戻しても、既存データは変わらない（追加した列は残る）", data_snapshot() == d1)
# ---- 戻したあと、もう一度適用できる
for name, mig, _ in STEPS:
    rc, o, e = run(f=S + mig, single=True)
    if rc: ok(f"戻したあと {name} を再適用", False, e[:100])
ok("戻したあと、もう一度 v1.6〜v1.10 を適用でき、元の適用後と同じ状態", diff(catalog(), cats[-1]) == [] and data_snapshot() == d1)
f = [r for r in R if not r[1]]; print(f"\n合計 {len(R)} 件 / 不合格 {len(f)} 件"); [print("  FAIL:", x[0]) for x in f]
