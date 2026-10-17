import re, subprocess, sys
f = sys.argv[1]; db = sys.argv[2:]
src = open(f, encoding='utf-8').read()
# コメントと文字列を取り除いてから調べる
body = re.sub(r"--[^\n]*", " ", src)
body = re.sub(r"'(?:[^']|'')*'", "''", body)
stmts = [s for s in body.split(";") if s.strip()]
bad = re.findall(r"\b(insert|update|delete|create|alter|drop|grant|revoke|truncate|copy|call|do|set|notify|listen|vacuum|analyze|lock|comment|security|execute|perform|into|returning|nextval|setval|pg_sleep|dblink|lo_\w+|pg_read\w*|pg_write\w*|pg_terminate\w*|pg_cancel\w*)\b", body, re.I)
print("statements:", len(stmts), "| first word:", stmts[0].split()[0] if stmts else None)
print("write/side-effect keywords:", sorted(set(b.lower() for b in bad)) or "none")
names = sorted(set(n.lower() for n in re.findall(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(", body)))
kw = {"values","in","exists","case","coalesce","array","rows","exp_fn","exp_pol","exp_trg","exp_grant","act_fn","act_pol","act_trg","act_grant","as","select","and","or","not","from","join","on","when","then","else","end","where","unnest","to_regclass"}
fn = [n for n in names if n not in kw or n in ("unnest","to_regclass")]
q = "select n, (select string_agg(distinct ns.nspname, ',') from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where p.proname=n), (select bool_and(provolatile in ('s','i')) from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where p.proname=n and ns.nspname='pg_catalog') from unnest(array[%s]) n" % ",".join("'%s'" % n for n in fn)
out = subprocess.run(["psql","-h","/home/pgtest/pg","-p","55432","-U","postgres","-X","-At","-F","|","-d",db[0],"-c",q],capture_output=True,text=True).stdout
print("functions called (name | schema | all read-only kinds):"); print(out)
for d in db:
    r = subprocess.run(["psql","-h","/home/pgtest/pg","-p","55432","-U","postgres","-X","-At","-F","|","-d",d,"-v","ON_ERROR_STOP=1"], input="begin read only;\n"+src+"\nrollback;", capture_output=True, text=True)
    lines=[l for l in r.stdout.splitlines() if l not in ("BEGIN","ROLLBACK")]
    verd={}
    for l in lines:
        p=l.split("|")
        if len(p)>=3: verd[p[2]]=verd.get(p[2],0)+1
    print(f"[{d}] read-only transaction exit={r.returncode} err={r.stderr.strip()[:120]!r} rows={len(lines)} verdicts={verd}")
