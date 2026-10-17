#!/usr/bin/env python3
"""AIMUSE v1.8 theme tests (local Postgres, Supabase-equivalent roles)."""
import subprocess, json, sys
DB = ["psql","-h","/home/pgtest/pg","-p","55432","-U","postgres","-d","v18","-X","-At","-v","ON_ERROR_ROLLBACK=on"]
RYO, HAMU = "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
def q(who, sql, pre=""):
    role, c = ("anon", {"role":"anon"}) if who=="anon" else ("authenticated", {"sub":{"ryo":RYO,"hamu":HAMU}[who],"role":"authenticated"})
    s = f"begin; {pre};\nset local role {role}; set local request.jwt.claims='{json.dumps(c)}';\n\\echo ===A\n{sql};\n\\echo ===V\nreset role;\nselect coalesce((select theme::text from public.profiles where id='{HAMU}'),'null')||' / '||coalesce((select theme::text from public.profiles where id='{RYO}'),'null');\nrollback;"
    out = subprocess.run(DB, input=s, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    a = out.split("===A")[1].split("===V")[0]; v = out.split("===V")[1]
    clean = lambda t: " ".join(l for l in t.strip().splitlines() if l and l not in ("RESET","ROLLBACK","SET") and not l.startswith(("UPDATE","CONTEXT","LINE"," ")))
    return clean(a), clean(v)
R=[]
def ok(n, c, i=None): R.append((n,bool(c))); print(f"[{'PASS' if c else 'FAIL'}] {n}" + (f"  → {i}" if i is not None else ""))
GOOD = '{"v":1,"preset":"ocean","accent":"#5ab8ff","bg":"#06101e","button":"#2f74ff"}'
a,v = q("hamu", f"select public.set_my_theme('{GOOD}'::jsonb)")
ok("本人がテーマを保存できる", "ocean" in v.split(" / ")[0] and "ERROR" not in a, v)
a,v = q("hamu", "select public.set_my_theme(null)", pre=f"update public.profiles set theme='{GOOD}' where id='{HAMU}'")
ok("null で未設定に戻せる", v.startswith("null"), v)
BAD = {
 "色の名前":'{"v":1,"preset":"custom","accent":"red","bg":"#000000","button":"#ffffff"}',
 "CSSの注入":'{"v":1,"preset":"custom","accent":"#000000;}body{display:none","bg":"#000000","button":"#ffffff"}',
 "余分な項目":'{"v":1,"preset":"custom","accent":"#000000","bg":"#000000","button":"#ffffff","x":"<script>"}',
 "項目の不足":'{"v":1,"preset":"custom","accent":"#000000","bg":"#000000"}',
 "不明なプリセット":'{"v":1,"preset":"hack","accent":"#000000","bg":"#000000","button":"#ffffff"}',
 "版が違う":'{"v":2,"preset":"custom","accent":"#000000","bg":"#000000","button":"#ffffff"}',
 "色が数値":'{"v":1,"preset":"custom","accent":123456,"bg":"#000000","button":"#ffffff"}',
 "配列":'["#000000"]',
 "巨大な値":'{"v":1,"preset":"custom","accent":"#' + "0"*100000 + '","bg":"#000000","button":"#ffffff"}'}
for name, js in BAD.items():
    a,v = q("hamu", f"select public.set_my_theme('{js}'::jsonb)")
    ok(f"不正な値は保存されない：{name}", "ERROR" in a and v.startswith("null"), a[:60])
a,v = q("hamu", f"update public.profiles set theme='{GOOD}' where id='{HAMU}'")
ok("theme 列を直接書き換えられない（関数経由のみ）", "permission denied" in a and v.startswith("null"), a[:60])
a,v = q("hamu", f"update public.profiles set theme='{GOOD}' where id='{RYO}'")
ok("他人（Ryo）のテーマを書き換えられない", "ERROR" in a and v.endswith("null"), a[:60])
a,v = q("anon", f"select public.set_my_theme('{GOOD}'::jsonb)")
ok("未ログインでは保存できない", "permission denied" in a, a[:60])
a,v = q("hamu", f"select count(*) from public.profiles where id='{RYO}' and theme is not null", pre=f"update public.profiles set theme='{GOOD}' where id='{RYO}'")
ok("他人のテーマは読めない", a == "0", a)
a,v = q("anon", "select pg_get_function_result('public.public_artist_profiles(uuid[])'::regprocedure)||' | '||pg_get_function_result('public.public_artist_followers(uuid,timestamptz,uuid,integer)'::regprocedure)")
ok("公開用の関数はテーマを返さない", "theme" not in a, a[:80])
a,v = q("hamu", "update public.profiles set display_name='ハム' where id='"+HAMU+"' returning display_name", pre=f"update public.profiles set theme='{GOOD}' where id='{HAMU}'")
ok("テーマ設定済みでも表示名の変更は従来どおりできる", "ハム" in a, a)
f=[r for r in R if not r[1]]; print(f"\n合計 {len(R)} 件 / 不合格 {len(f)} 件"); [print("  FAIL:",x[0]) for x in f]
