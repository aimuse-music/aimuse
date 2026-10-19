# 退会テスト用SQL（supabase/deletion_test/01〜04）のテスト：専用テストアカウントだけが対象になり、本番の会員を守ること（PostgreSQL 17・15）
import subprocess, json
import os; D=os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),'supabase')+'/'
rd=lambda f: open(D+f,encoding='utf-8').read()
MIG=rd('migration_v1_12_purge_play_events.sql'); F=[rd('deletion_test/0%d'%i+n) for i,n in [(1,'_register_tester.sql'),(2,'_fast_forward_and_purge.sql'),(3,'_check.sql'),(4,'_finish_test.sql')]]
F1B=rd('deletion_test/01b_start_testers.sql')
T='72000000-0000-4000-8000-000000000001'; M='72000000-0000-4000-8000-000000000002'; ADM='10000000-0000-4000-8000-000000000003'
R=[]
def ok(n,c,i=''): R.append(c); print(f"  [{'PASS' if c else 'FAIL'}] {n}  {str(i)[:150]}")
for port in [55417,55415]:
    def q(sql,role=None):
        if role: sql=f"begin; set local role {role}; set local request.jwt.claims='{json.dumps({'role':role})}';\n{sql};\ncommit;"
        r=subprocess.run(['psql','-h','/opt/pgx','-p',str(port),'-U','postgres','-X','-At','-q','-d','dt','-c',sql],capture_output=True,text=True)
        return r.stdout.strip(), next((l for l in r.stderr.splitlines() if 'ERROR' in l),'')
    subprocess.run(['psql','-h','/opt/pgx','-p',str(port),'-U','postgres','-X','-q','-d','postgres','-c','drop database if exists dt','-c','create database dt template prod111'],capture_output=True)
    print('== port',port)
    q(MIG)
    q(f"""create schema if not exists vault; create table vault.decrypted_secrets (name text, decrypted_secret text, created_at timestamptz default now());
insert into vault.decrypted_secrets(name,decrypted_secret) values ('aimuse_purge_secret', repeat('z',64));
create schema if not exists net; create table net.calls (url text, headers jsonb); create table net._http_response (status_code int, created timestamptz default now());
create function net.http_post(url text, headers jsonb, body jsonb, timeout_milliseconds int) returns bigint language sql as $$ insert into net.calls values (url, headers) returning 1::bigint $$;
update public.profiles set is_admin = true where id = '{ADM}';
insert into auth.users (id,email,email_confirmed_at) values ('{M}','member@example.com',now());""")
    mode=lambda: q("select value from aimuse_private.settings where key='account_deletion_mode'")[0]
    o,e=q(F[0]); ok('テスト用アカウントが無ければ中止・変化なし', '1人ではありません' in e and mode()=='off' and q("select count(*) from aimuse_private.deletion_testers")[0]=='0', e)
    o,e=q(F1B); ok('許可リストが空なら 01b は中止（受付 off のまま）', '許可リストが空' in e and mode()=='off', e)
    q(f"update public.profiles set display_name='退会テスト用' where id='{ADM}'"); o,e=q(F[0]); ok('管理者は登録できない', '管理者' in e, e)
    q(f"update public.profiles set display_name='管理' where id='{ADM}'")
    q(f"""insert into auth.users (id,email,email_confirmed_at,raw_user_meta_data) values ('{T}','tester@example.com',null,'{{"display_name":" 退会テスト用 "}}')""")
    o,e=q(F[0]); ok('メール未確認は登録できない', '確認' in e, e)
    q(f"update auth.users set email_confirmed_at=now(), created_at=now()-interval '8 days' where id='{T}'"); o,e=q(F[0]); ok('登録から7日を過ぎたアカウントは使えない', '7日' in e, e)
    q(f"update auth.users set created_at=now() where id='{T}'")
    q(f"insert into public.artists (user_id,name) values ('{T}','テスト')"); o,e=q(F[0]); ok('アーティストを持つアカウントは使えない', 'アーティスト' in e, e); q(f"delete from public.artists where user_id='{T}'")
    q(f"update public.profiles set display_name='退会テスト用' where id='{M}'"); o,e=q(F[0]); ok('同じ表示名が2人いれば中止', '2 人' in e, e); q(f"update public.profiles set display_name='会員' where id='{M}'")
    o,e=q(F[0]); ok('テスト用アカウントを登録（表示名の前後の空白も一致）・会員IDだけ表示・受付は off のまま', not e and o.split('|')[0]==T and o.split('|')[1]=='off', o or e)
    o,e=q(f"select status from public.account_request_deletion('{T}')",role='service_role'); ok('受付 off の間はテスト用アカウントも申請できない', 'pending' not in o and e, e)
    o,e=q(F1B); ok('01b：受付を testers にする（完全削除は off のまま）', not e and o.split('|')[:2]==['testers','off'], o or e)
    # 申請（Edge Function の代わりに service_role で）
    o,e=q(f"select status from public.account_request_deletion('{T}')",role='service_role'); ok('テスト用アカウントは申請できる', o=='pending', o or e)
    o,e=q(f"select status from public.account_request_deletion('{M}')",role='service_role'); ok('許可リスト以外の会員は申請できない（受付 testers）', 'pending' not in o and e, e)
    # 他の会員の申請が紛れている場合（受付を一時的に all にして作る）→ 02 は中止
    q("update aimuse_private.settings set value='all' where key='account_deletion_mode'"); q(f"select public.account_request_deletion('{M}')",role='service_role'); q("update aimuse_private.settings set value='testers' where key='account_deletion_mode'")
    b=q("select string_agg(user_id||':'||purge_after::text, ',' order by user_id) from aimuse_private.account_deletions")[0]
    o,e=q(F[1]); ok('許可リスト以外の会員の申請があれば中止・期限も完全削除のスイッチも変わらない', '許可リスト以外' in e and q("select string_agg(user_id||':'||purge_after::text, ',' order by user_id) from aimuse_private.account_deletions")[0]==b and q("select value from aimuse_private.settings where key='account_purge_enabled'")[0]=='off' and q("select count(*) from net.calls")[0]=='0', e)
    q(f"select public.cancel_my_account_deletion()") ; q(f"update aimuse_private.account_deletions set status='canceled', canceled_at=now() where user_id='{M}'")
    o,e=q(F[1]); ok('テスト用アカウントだけ期限を過ぎた状態にし、完全削除を on・1回呼び出す', not e and o=='t' and q("select value from aimuse_private.settings where key='account_purge_enabled'")[0]=='on' and q("select count(*) from net.calls")[0]=='1', o or e)
    due=q("select string_agg(user_id::text, ',') from aimuse_private.account_deletions where purge_after < now() and status='pending'")[0]
    ok('期限を短くしたのはテスト用アカウントの申請だけ', due==T, due)
    hdr=q("select headers->>'x-aimuse-purge-secret' = repeat('z',64) from net.calls")[0]; ok('呼び出しには金庫の合言葉を使い、結果には表示しない', hdr=='t' and 'zzzz' not in o, o)
    o,e=q(F[1]); ok('もう一度実行しても、対象はテスト用アカウントの申請だけ', not e and q("select string_agg(user_id::text, ',') from aimuse_private.account_deletions where purge_after < now() and status='pending'")[0]==T, e)
    o,e=q(F[2]); ok('確認SQL（読み取り）が動く', not e and o.count('|')>=7, (o or e)[:120])
    o,e=q(F[3]); ok('後片付け：受付・完全削除 off、許可リスト0人', o=='off|off|0', o or e)
    subprocess.run(['psql','-h','/opt/pgx','-p',str(port),'-U','postgres','-X','-q','-d','postgres','-c','drop database if exists dt'],capture_output=True)
print(f"合計 {len(R)} 件 / 不合格 {R.count(False)} 件")
