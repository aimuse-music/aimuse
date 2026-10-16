// Fake Supabase for AIMUSE v1.6 profile tests. Mirrors the rules in supabase/migration_v1_6_profile.sql
// (those rules themselves were verified against real PostgreSQL in attack_v16.py).
// Failure injection: window.__fail = {upload, setImage, remove, rename}; window.__noV16 = true simulates "SQL not applied".
(function(){
  const USERS = {
    "ryo@test.jp":  { id:"11111111-1111-4111-8111-111111111111", name:"NOCTERA Ryo", admin:true },
    "hamu@test.jp": { id:"22222222-2222-4222-8222-222222222222", name:"ハムハム", admin:false },
    "mike@test.jp": { id:"33333333-3333-4333-8333-333333333333", name:"ミケ", admin:false }
  };
  const RYO=USERS["ryo@test.jp"].id, HAMU=USERS["hamu@test.jp"].id;
  const A_RYO="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", A_HAMU="cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const T = (id,uid,aid,title,artist,status,genre) => ({id,user_id:uid,artist_id:aid,title,artist,genre:genre||"J-POP",tool:"Suno",tool_name:"Suno",
    audio_path:uid+"/"+id+".mp3",status,plays:0,lyrics:[],checks:[true,true,true,true],hues:[270,230],pattern:0,submitted_at:"2026/10/14",approved_at:"2026/10/14",created_at:"2026-10-14T00:00:00Z"});
  const fresh = () => ({
    profiles: Object.values(USERS).map(u=>({id:u.id,display_name:u.name,is_admin:u.admin,is_banned:false,avatar_path:null,header_path:null})),
    artists: [{id:A_RYO,user_id:RYO,name:"NOCTERA",bio:""},{id:A_HAMU,user_id:HAMU,name:"ハムハム",bio:""}],
    tracks: [T("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1",RYO,A_RYO,"おぼろ月","NOCTERA","public"),
             T("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2",RYO,A_RYO,"ああ","NOCTERA","public","バラード"),
             T("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3",HAMU,A_HAMU,"ひまわり","ハムハム","public")],
    reports:[], favorites:[], follows:[], avatars:[], history:[]
  });
  let db; try{ db = JSON.parse(sessionStorage.getItem("fakedb2")); }catch(e){}
  if(!db){ db = fresh();
    if(window.__bigFollow){
      const t0 = Date.parse("2026-10-16T00:00:00Z");
      for(let i=1;i<=75;i++){
        const uid = "00000000-0000-4000-8000-"+String(i).padStart(12,"0");
        db.profiles.push({id:uid,display_name:"個人名"+i,is_admin:false,is_banned:i===75,avatar_path:null,header_path:null});
        if(i<=35 || i===75){
          const aid = "a0000000-0000-4000-8000-"+String(i).padStart(12,"0");
          db.artists.push({id:aid,user_id:uid,name:"公開アーティスト"+i,bio:""});
          db.tracks.push(T("b0000000-0000-4000-8000-"+String(i).padStart(12,"0"),uid,aid,"曲"+i,"公開アーティスト"+i,"public"));
          if(i<=32) db.follows.push({user_id:RYO,artist_id:aid,created_at:new Date(t0-i*1000).toISOString()});
        }
        db.follows.push({user_id:uid,artist_id:A_RYO,created_at:new Date(t0-i*60000).toISOString()});
      }
    }
  }
  const blobs = window.__blobs = window.__blobs || {};
  const save = () => sessionStorage.setItem("fakedb2", JSON.stringify(db));
  window.__db = db; window.__fail = window.__fail || {}; window.__log = [];
  const delay = () => new Promise(r=>setTimeout(r, 5 + Math.random()*40));
  let session = (()=>{ try{ return JSON.parse(localStorage.getItem("fake-session")) }catch(e){ return null } })();
  const listeners = new Set();
  const uid = () => session ? session.user.id : null;
  const isAdmin = () => !!db.profiles.find(p=>p.id===uid()&&p.is_admin);
  const active = () => { const p=db.profiles.find(p=>p.id===uid()); return !!p && !p.is_banned; };
  const fire = ev => listeners.forEach(cb=>cb(ev, session));
  const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  const key = n => (n||"").normalize("NFKC").replace(/[\s​-‏‪-‮⁠-⁤﻿]+/g,"").toLowerCase();
  const reserved = n => /(aimuse|運営|管理者|公式|admin|staff|スタッフ)/.test((n||"").normalize("NFKC").toLowerCase());
  const E = m => ({ data:null, error:{ message:m } });
  const pick = (r,cols) => { if(!cols||cols==="*") return {...r}; const o={}; cols.split(",").forEach(c=>{ c=c.trim(); if(!(c in r) && window.__noV16 && /avatar_path|header_path/.test(c)) o.__missing=c; o[c]=r[c]; }); return o; };

  function query(table){
    const q = { table, op:"select", filters:[], ins:[], row:null, returning:false, cols:"*" };
    const api = {
      select(c){ if(q.op!=="select") q.returning=true; else q.cols=c||"*"; return api; },
      order(){ return api; }, limit(){ return api; }, gte(){ return api; },
      eq(c,v){ q.filters.push([c,v]); return api; },
      in(c,v){ q.ins.push([c,v]); return api; },
      insert(row){ q.op="insert"; q.row=row; return api; },
      delete(){ q.op="delete"; return api; },
      update(p){ q.op="update"; q.row=p; return api; },
      single(){ q.single=true; return api; }, maybeSingle(){ q.maybe=true; return api; },
      then(res, rej){ return run(q).then(res, rej); }
    };
    return api;
  }
  async function run(q){
    const me = uid(); await delay();
    const match = r => q.filters.every(([c,v])=>r[c]===v) && q.ins.every(([c,v])=>v.includes(r[c]));
    const one = rows => q.maybe||q.single ? (rows[0]||null) : rows;
    if(q.table==="profiles"){
      if(q.op==="select"){
        if(window.__noV16 && /avatar_path/.test(q.cols)) return E('column profiles.avatar_path does not exist');
        return { data: one(db.profiles.filter(p=>(p.id===me||isAdmin()) && match(p)).map(p=>pick(p,q.cols))), error:null };
      }
      if(q.op==="update"){
        const keys = Object.keys(q.row);
        if(keys.some(k=>k!=="display_name")) return E("permission denied for table profiles");
        if(q.row.display_name && reserved(q.row.display_name)) return E("表示名に使用できない言葉が含まれています");
        const hit = db.profiles.filter(p=>p.id===me && match(p)); hit.forEach(p=>Object.assign(p,q.row)); save();
        return { data: q.returning ? hit.map(p=>({id:p.id})) : null, error:null };
      }
    }
    if(q.table==="artists"){
      const vis = a => a.user_id===me || isAdmin() || db.tracks.some(t=>t.artist_id===a.id&&t.status==="public");
      if(q.op==="select") return { data: db.artists.filter(a=>vis(a)&&match(a)).map(a=>pick(a,q.cols)), error:null };
      if(q.op==="update"){
        if(Object.keys(q.row).some(k=>k!=="bio")) return E("permission denied for table artists");
        if((q.row.bio||"").length>500) return E('new row violates check constraint "artists_bio_check"');
        const hit = db.artists.filter(a=>match(a) && ((a.user_id===me&&active())||isAdmin())); hit.forEach(a=>Object.assign(a,q.row)); save();
        return { data: q.returning ? hit.map(a=>({id:a.id})) : null, error:null };
      }
    }
    if(q.table==="tracks"||q.table==="reports"){
      const rows = db[q.table];
      const visible = r => q.table==="tracks" ? (r.status==="public"||r.user_id===me||isAdmin()) : isAdmin();
      if(q.op==="select") return { data: rows.filter(r=>visible(r)&&match(r)).map(r=>({...r})), error:null };
      if(q.op==="update"){ const hit=rows.filter(r=>match(r)&&isAdmin()); hit.forEach(r=>Object.assign(r,q.row)); save(); return { data:q.returning?hit.map(r=>({id:r.id})):null, error:null }; }
      if(q.op==="delete"){ const hit=rows.filter(r=>match(r)&&(isAdmin()||(q.table==="tracks"&&r.user_id===me))); db[q.table]=rows.filter(r=>!hit.includes(r)); save(); return { data:q.returning?hit.map(r=>({id:r.id})):null, error:null }; }
    }
    if(q.table==="favorites"||q.table==="follows"){
      const rows=db[q.table];
      if(q.op==="select") return { data: rows.filter(r=>r.user_id===me&&match(r)).map(r=>({...r})), error:null };
      if(q.op==="insert"){ const row={user_id:me,created_at:new Date().toISOString(),...q.row}; if(row.user_id!==me) return E("rls"); rows.push(row); save(); return {data:null,error:null}; }
      if(q.op==="delete"){ db[q.table]=rows.filter(r=>!(r.user_id===me&&match(r))); save(); return {data:null,error:null}; }
    }
    return { data:[], error:null };
  }

  const visible = u => { const p=db.profiles.find(x=>x.id===u); return !!p && !p.is_banned; };
  const isPubArtist = id => { const a=db.artists.find(x=>x.id===id); return !!a && visible(a.user_id) && db.tracks.some(t=>t.artist_id===id&&t.status==="public"); };
  const pubOf = u => db.artists.filter(a=>a.user_id===u && isPubArtist(a.id))[0]||null;
  const page = (rows,{p_before_at,p_before,p_limit},key) => rows
    .sort((x,y)=> y.created_at.localeCompare(x.created_at) || (y[key]>x[key]?1:-1))
    .filter(f=>!p_before_at||!p_before|| f.created_at<p_before_at || (f.created_at===p_before_at && f[key]<p_before))
    .slice(0, Math.min(Math.max(p_limit||30,1),100));
  const rpcs = {
    artist_follower_count: ({aid}) => ({data: db.follows.filter(f=>f.artist_id===aid&&visible(f.user_id)).length, error:null}),
    public_artist_follow_summary({p_artist}){
      if(!isPubArtist(p_artist)) return {data:[],error:null};
      const fs=db.follows.filter(f=>f.artist_id===p_artist&&visible(f.user_id)); const pub=fs.filter(f=>pubOf(f.user_id)).length;
      const owner=db.artists.find(a=>a.id===p_artist).user_id;
      return {error:null,data:[{followers:fs.length,public_followers:pub,listeners:fs.length-pub,following:db.follows.filter(g=>g.user_id===owner&&isPubArtist(g.artist_id)).length}]};
    },
    public_artist_followers(a){
      if(!isPubArtist(a.p_artist)) return {data:[],error:null};
      const rows=page(db.follows.filter(f=>f.artist_id===a.p_artist&&pubOf(f.user_id)).map(f=>({...f})),a,"user_id");
      return {error:null,data:rows.map(f=>{const pa=pubOf(f.user_id), p=db.profiles.find(x=>x.id===f.user_id); return {artist_id:pa.id,name:pa.name,avatar_path:p.avatar_path,followed_at:f.created_at,cursor:f.user_id};})};
    },
    public_artist_following(a){
      if(!isPubArtist(a.p_artist)) return {data:[],error:null};
      const owner=db.artists.find(x=>x.id===a.p_artist).user_id;
      const rows=page(db.follows.filter(g=>g.user_id===owner&&isPubArtist(g.artist_id)).map(g=>({...g})),a,"artist_id");
      return {error:null,data:rows.map(g=>{const x=db.artists.find(y=>y.id===g.artist_id), p=db.profiles.find(y=>y.id===x.user_id); return {artist_id:x.id,name:x.name,avatar_path:p.avatar_path,followed_at:g.created_at,cursor:g.artist_id};})};
    },
    my_following(a){
      const me=uid(); if(!me) return E("permission denied for function my_following");
      const rows=page(db.follows.filter(g=>g.user_id===me).map(g=>({...g})),a,"artist_id");
      return {error:null,data:rows.map(g=>{const x=db.artists.find(y=>y.id===g.artist_id), p=db.profiles.find(y=>y.id===x.user_id), v=isPubArtist(x.id);
        return {artist_id:x.id,name:v?x.name:null,avatar_path:v?p.avatar_path:null,followed_at:g.created_at,cursor:g.artist_id,is_public:v};})};
    },
    increment_plays: () => ({data:null,error:null}),
    set_duration_if_missing: () => ({data:null,error:null}),
    public_artist_profiles({p_artist_ids}){
      return {error:null, data: db.artists.filter(a=>(p_artist_ids||[]).slice(0,200).includes(a.id)).map(a=>{
        const p=db.profiles.find(x=>x.id===a.user_id);
        if(!p||p.is_banned||!(p.avatar_path||p.header_path)||!db.tracks.some(t=>t.artist_id===a.id&&t.status==="public")) return null;
        return {artist_id:a.id, avatar_path:p.avatar_path, header_path:p.header_path}; }).filter(Boolean)};
    },
    set_my_profile_image({p_kind,p_path}){
      if(window.__fail.setImage) return E("ネットワークエラー（テスト用に失敗させています）");
      const me=uid(); if(!me||!active()) return E("ERROR: プロフィールを変更できません（ログイン状態・メール確認・利用状況を確認してください）");
      if(!["avatar","header"].includes(p_kind)) return E("ERROR: 画像の種類が正しくありません");
      if(p_path!==null){
        if(!new RegExp(`^${p_kind}-${UUID}\\.(jpg|png|webp)$`).test(p_path)) return E("ERROR: 画像の保存場所が正しくありません");
        if(!db.avatars.some(o=>o.name===p_path&&o.owner===me)) return E("ERROR: 画像が保存されていないか、あなたの画像ではありません");
      }
      const p=db.profiles.find(x=>x.id===me); const col=p_kind+"_path"; const old=p[col]; p[col]=p_path; save();
      return {data:old,error:null};
    },
    rename_my_artist({p_artist,p_name}){
      if(window.__fail.rename) return E("ネットワークエラー");
      const me=uid(); if(!me||!active()) return E("ERROR: アーティスト名を変更できません");
      const v=(p_name||"").replace(/\s+/g," ").trim();
      if(v.length<1||[...v].length>40) return E("ERROR: アーティスト名は1〜40文字で入力してください");
      if(/[\u0000-\u001f\u007f​-‏‪-‮⁠-⁤﻿]/.test(v)) return E("ERROR: アーティスト名に使用できない文字が含まれています");
      const a=db.artists.find(x=>x.id===p_artist); if(!a||a.user_id!==me) return E("ERROR: アーティストが見つかりません");
      if(a.name===v) return {data:v,error:null};
      if(reserved(v)||db.artists.some(x=>x.user_id!==me&&key(x.name)===key(v))) return E("ERROR: このアーティスト名は使用できません（運営と誤解される言葉を含む、または他の会員が使用しています）");
      if(db.history.filter(h=>h.user_id===me&&!h.by_admin&&Date.now()-h.at<864e5).length>=3) return E("ERROR: アーティスト名の変更は24時間に3回までです。時間をおいてから変更してください");
      db.history.unshift({artist_id:a.id,user_id:me,by_admin:false,old_name:a.name,new_name:v,at:Date.now()});
      a.name=v; db.tracks.filter(t=>t.artist_id===a.id).forEach(t=>t.artist=v); save();
      return {data:v,error:null};
    },
    admin_reset_profile_image({p_artist,p_kind}){
      if(!isAdmin()) return E("ERROR: 管理者のみ利用できます");
      const a=db.artists.find(x=>x.id===p_artist); const p=db.profiles.find(x=>x.id===a.user_id); const col=p_kind+"_path"; const old=p[col]; p[col]=null; save();
      return {data:old,error:null};
    },
    admin_set_artist_name({p_artist,p_name}){
      if(!isAdmin()) return E("ERROR: 管理者のみ利用できます");
      const a=db.artists.find(x=>x.id===p_artist); db.history.unshift({artist_id:a.id,user_id:a.user_id,by_admin:true,old_name:a.name,new_name:p_name,at:Date.now()});
      a.name=p_name; db.tracks.filter(t=>t.artist_id===a.id).forEach(t=>t.artist=p_name); save(); return {data:p_name,error:null};
    },
    admin_artist_name_history(){
      if(!isAdmin()) return E("ERROR: 管理者のみ利用できます");
      return {error:null, data: db.history.map(h=>({changed_at:new Date(h.at).toISOString(),artist_id:h.artist_id,current_name:db.artists.find(a=>a.id===h.artist_id).name,old_name:h.old_name,new_name:h.new_name,by_admin:h.by_admin}))};
    }
  };

  const avatarStore = {
    async upload(path, blob, opts){
      await delay();
      if(window.__fail.upload) return E("アップロードに失敗しました（テスト用）");
      const me=uid();
      if(!me||!active()||!new RegExp(`^(avatar|header)-${UUID}\\.(jpg|png|webp)$`).test(path)) return E("new row violates row-level security policy");
      if(db.avatars.filter(o=>o.owner===me).length>=4) return E("new row violates row-level security policy");
      if(!["image/jpeg","image/png","image/webp"].includes(opts&&opts.contentType)) return E("mime type not supported");
      if(blob.size>2097152) return E("The object exceeded the maximum allowed size");
      if(db.avatars.some(o=>o.name===path)) return E("The resource already exists");
      db.avatars.push({name:path,owner:me,size:blob.size,type:opts.contentType}); blobs[path]=URL.createObjectURL(blob); save();
      window.__log.push({op:"upload",path,size:blob.size,type:opts.contentType});
      return {data:{path},error:null};
    },
    async remove(paths){
      await delay();
      if(window.__fail.remove) return E("削除に失敗しました（テスト用）");
      const me=uid(); const inUse=n=>db.profiles.some(p=>p.avatar_path===n||p.header_path===n);
      const ok=paths.filter(n=>db.avatars.some(o=>o.name===n && (isAdmin() || (o.owner===me && !inUse(n)))));
      db.avatars=db.avatars.filter(o=>!ok.includes(o.name)); save(); window.__log.push({op:"remove",paths,removed:ok});
      return {data:ok.map(n=>({name:n})),error:null};
    },
    async list(prefix){ await delay(); const me=uid();   // 保存場所のルールにより、見えるのは本人の画像（管理者は全部）
      return {data: db.avatars.filter(o=>o.owner===me||isAdmin()).map(o=>({name:o.name})), error:null}; },
    getPublicUrl(path){ return {data:{publicUrl: blobs[path] || ("https://x.supabase.co/storage/v1/object/public/avatars/"+path)}}; }
  };

  window.supabase = { createClient(){ return {
    auth:{
      async getSession(){ await delay(); return { data:{ session } }; },
      onAuthStateChange(cb){ listeners.add(cb); setTimeout(()=>cb("INITIAL_SESSION", session),0); return { data:{ subscription:{ unsubscribe(){ listeners.delete(cb) } } } }; },
      async signInWithPassword({email}){ await delay(); const u=USERS[email]; if(!u) return {error:{message:"Invalid login credentials"}};
        session = { user:{ id:u.id, email }, access_token:"jwt-"+u.id }; localStorage.setItem("fake-session", JSON.stringify(session)); fire("SIGNED_IN"); return { data:{ session, user:session.user }, error:null }; },
      async signOut(){ await delay(); session=null; localStorage.removeItem("fake-session"); fire("SIGNED_OUT"); return { error:null }; },
      async signUp(){ return { error:{message:"n/a"} }; }, async updateUser(){ return { error:null }; }, async resetPasswordForEmail(){ return { error:null }; }
    },
    from: query,
    async rpc(name, args){ await delay(); window.__log.push({op:"rpc",name,args});
      if(window.__noV16 && !["artist_follower_count","increment_plays","set_duration_if_missing"].includes(name)) return E(`Could not find the function public.${name}`);
      return rpcs[name] ? rpcs[name](args||{}) : {data:null,error:null}; },
    storage:{ from(bucket){
      if(bucket==="avatars") return avatarStore;
      return { async createSignedUrls(paths){ return { data: paths.map(p=>({ path:p, signedUrl:"data:audio/mpeg;base64,", error:null })), error:null }; },
               async remove(){ return {error:null}; }, async upload(){ return {error:null}; } };
    } }
  }; } };
})();
