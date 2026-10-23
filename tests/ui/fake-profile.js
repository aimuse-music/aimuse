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
  db.deletions = db.deletions || []; db.trackDeletions = db.trackDeletions || [];
  window.__db = db; window.__fail = window.__fail || {}; window.__log = [];
  const delay = () => new Promise(r=>setTimeout(r, 5 + Math.random()*40));
  let session = (()=>{ try{ return JSON.parse(localStorage.getItem("fake-session")) }catch(e){ return null } })();
  const listeners = new Set();
  const uid = () => session ? session.user.id : null;
  const isAdmin = () => !!db.profiles.find(p=>p.id===uid()&&p.is_admin);
  const withdrawing = u => db.deletions.some(d=>d.user_id===u && ["pending","processing","failed"].includes(d.status));
  const active = () => { const p=db.profiles.find(p=>p.id===uid()); return !!p && !p.is_banned && !withdrawing(uid()); };
  const fire = ev => listeners.forEach(cb=>cb(ev, session));
  const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  const key = n => (n||"").normalize("NFKC").replace(/[\s\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]+/g,"").toLowerCase();
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
        if(window.__noV18 && /theme/.test(q.cols)) return E('column profiles.theme does not exist');
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
      // 投稿（tracks の追加）：本人だけ・利用できる会員だけ。データベースの仕組みと同じく「審査待ち・再生数0」にし、アーティストを結び付ける
      if(q.op==="insert" && q.table==="tracks"){
        const row={...q.row}; if(!me||row.user_id!==me||!active()) return E("new row violates row-level security policy");
        let a=db.artists.find(x=>x.user_id===me&&x.name===row.artist);
        if(!a){ a={id:"dddddddd-dddd-4ddd-8ddd-"+String(Date.now()).slice(-12).padStart(12,"0"),user_id:me,name:row.artist}; db.artists.push(a); }
        Object.assign(row,{artist_id:a.id,status:"pending",plays:0,created_at:new Date().toISOString()});
        rows.push(row); save(); window.__log.push({op:"insert_track",id:row.id});
        return { data: q.single ? {...row} : [{...row}], error:null };
      }
      if(q.op==="update"){ const hit=rows.filter(r=>match(r)&&isAdmin()); hit.forEach(r=>Object.assign(r,q.row)); save(); return { data:q.returning?hit.map(r=>({id:r.id})):null, error:null }; }
      if(q.op==="delete"){ const hit=rows.filter(r=>match(r)&&(isAdmin()||(q.table==="tracks"&&r.user_id===me))); db[q.table]=rows.filter(r=>!hit.includes(r)); save(); return { data:q.returning?hit.map(r=>({id:r.id})):null, error:null }; }
    }
    if(q.table==="favorites"||q.table==="follows"){
      const rows=db[q.table];
      if(q.op==="select") return { data: rows.filter(r=>r.user_id===me&&match(r)).map(r=>({...r})), error:null };
      if(q.op==="insert"){ const row={user_id:me,created_at:new Date().toISOString(),...q.row}; if(row.user_id!==me||!active()) return E("new row violates row-level security policy"); rows.push(row); save(); return {data:null,error:null}; }
      if(q.op==="delete"){ db[q.table]=rows.filter(r=>!(r.user_id===me&&match(r))); save(); return {data:null,error:null}; }
    }
    return { data:[], error:null };
  }

  const visible = u => { const p=db.profiles.find(x=>x.id===u); return !!p && !p.is_banned && !withdrawing(u); };
  const isPubArtist = id => { const a=db.artists.find(x=>x.id===id); return !!a && visible(a.user_id) && db.tracks.some(t=>t.artist_id===id&&t.status==="public"); };
  const pubOf = u => db.artists.filter(a=>a.user_id===u && isPubArtist(a.id))[0]||null;
  const page = (rows,{p_before_at,p_before,p_limit},key) => rows
    .sort((x,y)=> y.created_at.localeCompare(x.created_at) || (y[key]>x[key]?1:-1))
    .filter(f=>!p_before_at||!p_before|| f.created_at<p_before_at || (f.created_at===p_before_at && f[key]<p_before))
    .slice(0, Math.min(Math.max(p_limit||30,1),100));
  const ACTIVE = ["pending","processing","failed"];
  const plName = n => { const v=String(n||"").replace(/\s+/g," ").trim(); if(v.length<1||v.length>40) return E("プレイリスト名は1〜40文字で入力してください");
    if(/[\u0000-\u001f\u007f\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/.test(v)) return E("プレイリスト名に使用できない文字が含まれています"); return v; };
  const plOwned = id => { db.playlists=db.playlists||[]; const me=uid(); if(!me||!active()) return E("プレイリストを変更できません（ログイン状態・メール確認・利用状況を確認してください）");
    const p=db.playlists.find(x=>x.id===id&&x.user_id===me); return p || E("プレイリストが見つかりません"); };
  // v1.14 歌詞の同期（migration_v1_14_lyrics_sync.sql と同じ規則。規則そのものは test_v114.py で実際の PostgreSQL に対して検証済み）
  db.lyricsSync = db.lyricsSync || {};
  const lhash = l => JSON.stringify(l||[]);
  const isHead = l => /^\s*(\[[^\]]*\]|【[^】]*】)\s*$/.test(l||"");
  const rpcsSync = {
    lyrics_sync_get({p_track}){
      if(window.__noV114) return E("Could not find the function public.lyrics_sync_get");
      const t=db.tracks.find(x=>x.id===p_track), s=db.lyricsSync[p_track];
      if(!t||!s||!(t.status==="public"||t.user_id===uid()||isAdmin())) return {data:[],error:null};
      return {data:[{lines:s.lines,source:s.source,updated_at:s.updated_at,stale:s.hash!==lhash(t.lyrics)}],error:null};
    },
    lyrics_sync_save({p_track,p_lines}){
      if(window.__noV114) return E("Could not find the function public.lyrics_sync_save");
      if(!uid()||!active()) return E("NOT_ALLOWED: 同期を保存できるのは、ログイン中の会員だけです");
      const t=db.tracks.find(x=>x.id===p_track); if(!t) return E("NOT_FOUND: 楽曲が見つかりません");
      if(t.user_id!==uid()&&!isAdmin()) return E("NOT_ALLOWED: 歌詞の同期を変更できるのは、投稿者本人と運営だけです");
      if(!Array.isArray(p_lines)) return E("BAD_DATA: 形式が正しくありません");
      let pi=-1, pt=0, pe=null; const out=[];
      for(const x of p_lines){
        if(!x||typeof x!=="object"||Object.keys(x).some(k=>!["i","t","e"].includes(k))||!Number.isInteger(x.i)||typeof x.t!=="number") return E("BAD_DATA: 形式が正しくありません");
        const l=(t.lyrics||[])[x.i]; if(l==null||!String(l).trim()||isHead(l)) return E(`BAD_DATA: 空行・見出しには時刻を付けられません（${x.i+1}行目）`);
        const tt=Math.round(x.t*100)/100; if(x.i<=pi) return E("BAD_DATA: 行の順番が正しくありません");
        if(tt<0||tt>(t.duration>0?t.duration+30:3600)) return E(`BAD_DATA: 時刻が曲の長さの範囲外です（${x.i+1}行目）`);
        if(tt<pt||(pe!=null&&tt<pe)) return E(`BAD_DATA: 時刻が前の行より前になっています（${x.i+1}行目）`);
        let ee=null; if(x.e!=null){ ee=Math.round(x.e*100)/100; if(ee<=tt) return E(`BAD_DATA: 歌い終わりの時刻が正しくありません（${x.i+1}行目）`); }
        out.push(ee==null?{i:x.i,t:tt}:{i:x.i,t:tt,e:ee}); pi=x.i; pt=tt; pe=ee;
      }
      const prev=db.lyricsSync[p_track]; const src=prev&&["auto","mixed"].includes(prev.source)&&prev.hash===lhash(t.lyrics)?"mixed":"manual";
      db.lyricsSync[p_track]={lines:out,source:src,hash:lhash(t.lyrics),updated_at:new Date().toISOString()}; save();
      window.__log.push({op:"lyrics_sync_save",track:p_track,lines:out});
      return {data:{count:out.length,source:src},error:null};
    },
    // v1.15 歌詞の自動同期（AI）（migration_v1_15_lyrics_auto_sync.sql と同じ規則。規則そのものは test_v115.py で実際の PostgreSQL に対して検証済み）
    //   db.alignJobs[track] = {state, reason, proposal, meta:{ratio, quality_ok, est, hash}, review}、db.alignSettings
    lyrics_align_status({p_track}){
      if(window.__noV115) return E("Could not find the function public.lyrics_align_status");
      const t=db.tracks.find(x=>x.id===p_track); const role=alignRole(t); if(!role) return E("NOT_ALLOWED: この曲の情報は見られません");
      const j=(db.alignJobs||{})[p_track]; const st=db.alignSettings||{paused:false}; const s=db.lyricsSync[p_track];
      const base={sync_source:s&&s.hash===lhash(t.lyrics)?s.source:null,paused:!!st.paused,role,requests_left:(db.alignReqLeft??2)};
      if(!j) return {data:{state:"none",...base},error:null};
      const cur=j.proposal&&j.meta&&j.meta.hash===lhash(t.lyrics);
      return {data:{state:j.state,reason:j.reason,attempts:0,proposal:cur?j.proposal:null,meta:cur?{ratio:j.meta.ratio,quality_ok:j.meta.quality_ok,est:j.meta.est||[]}:null,review:j.review||null,...base},error:null};
    },
    lyrics_align_my_states(){
      if(window.__noV115) return E("Could not find the function public.lyrics_align_my_states");
      const me=uid(); return {data:Object.entries(db.alignJobs||{}).filter(([id])=>{ const t=db.tracks.find(x=>x.id===id); return t&&t.user_id===me; })
        .map(([id,j])=>({track_id:id,state:j.state,has_proposal:!!(j.proposal&&j.meta&&j.meta.hash===lhash(db.tracks.find(x=>x.id===id).lyrics))})),error:null};
    },
    lyrics_align_apply({p_track,p_lines}){
      const t=db.tracks.find(x=>x.id===p_track); const role=alignRole(t); if(!role) return E("NOT_ALLOWED: 歌詞の同期を変更できるのは、投稿者本人と運営だけです");
      const j=(db.alignJobs||{})[p_track]; if(!j||!j.proposal||!j.meta||j.meta.hash!==lhash(t.lyrics)) return E("NO_PROPOSAL: 今の歌詞に対する AI の提案がありません");
      const s=db.lyricsSync[p_track];
      if(t.user_id!==uid()&&s&&["manual","mixed"].includes(s.source)&&s.hash===lhash(t.lyrics)&&s.lines.length) return E("NOT_ALLOWED: 投稿者が手動で合わせた同期は、投稿者本人の操作なしに置き換えられません");
      const lines=p_lines||j.proposal; const same=JSON.stringify(lines)===JSON.stringify(j.proposal);
      const m=new Map(j.proposal.map(x=>[x.i,x.t])); const d=lines.filter(x=>m.has(x.i)).map(x=>Math.abs(x.t-m.get(x.i))).sort((a,b)=>a-b);
      const review={compared:d.length,changed:d.filter(x=>x>=0.05).length,median_abs:d.length?Math.round(d[Math.floor((d.length-1)/2)]*100)/100:0,max_abs:d.length?Math.round(d[d.length-1]*100)/100:0};
      db.lyricsSync[p_track]={lines:lines.map(x=>({...x})),source:same?"auto":"mixed",hash:lhash(t.lyrics),updated_at:new Date().toISOString()};
      j.state="applied"; j.review=review; save(); window.__log.push({op:"lyrics_align_apply",track:p_track,lines,source:same?"auto":"mixed"});
      return {data:{count:lines.length,source:same?"auto":"mixed",review},error:null};
    },
    lyrics_align_request({p_track}){
      const t=db.tracks.find(x=>x.id===p_track); if(!alignRole(t)) return E("NOT_ALLOWED: AI の解析を頼めるのは、投稿者本人と運営だけです");
      if((db.alignReqLeft??2)<=0) return E("LIMIT: この曲の AI 解析は、1日2回までです");
      db.alignReqLeft=(db.alignReqLeft??2)-1; db.alignJobs=db.alignJobs||{}; db.alignJobs[p_track]={state:"queued",reason:"requested"}; save();
      window.__log.push({op:"lyrics_align_request",track:p_track}); return {data:{result:"queued"},error:null};
    },
    lyrics_align_dismiss({p_track}){
      const t=db.tracks.find(x=>x.id===p_track); if(!alignRole(t)) return E("NOT_ALLOWED");
      const j=(db.alignJobs||{})[p_track]; if(j&&j.state==="review") j.state="dismissed"; save(); window.__log.push({op:"lyrics_align_dismiss",track:p_track}); return {data:{ok:true},error:null};
    },
    admin_align_overview(){
      if(window.__noV115) return E("Could not find the function public.admin_align_overview");
      if(!isAdmin()) return E("NOT_ALLOWED: 運営だけが使えます");
      const st=db.alignSettings||{paused:true,pause_reason:"initial",daily_cap:6000}; const jobs=Object.entries(db.alignJobs||{}).map(([id,j])=>{ const t=db.tracks.find(x=>x.id===id)||{};
        return {track_id:id,title:t.title,artist:t.artist,state:j.state,reason:j.reason,ratio:j.meta?j.meta.ratio:null,quality_ok:j.meta?j.meta.quality_ok:null,review:j.review||null,attempts:0,last_error:null}; });
      const counts={}; jobs.forEach(j=>{ counts[j.state]=(counts[j.state]||0)+1; });
      const rv=jobs.filter(j=>j.review&&j.review.median_abs!=null);
      return {data:{settings:{paused:!!st.paused,pause_reason:st.pause_reason||"",daily_cap:st.daily_cap||6000,auto_apply:false,blocked_until:null},today:{reserved:db.alignReserved||0,runs:0,ok:0,failed:0},counts,
        accuracy:{songs:rv.length,median_abs:rv.length?rv[0].review.median_abs:0,max_abs:rv.length?Math.max(...rv.map(j=>j.review.max_abs)):0},jobs},error:null};
    },
    admin_align_set_paused({p_paused}){ if(!isAdmin()) return E("NOT_ALLOWED: 運営だけが使えます"); db.alignSettings={...(db.alignSettings||{daily_cap:6000}),paused:!!p_paused,pause_reason:p_paused?"admin":""}; save(); window.__log.push({op:"admin_align_set_paused",paused:!!p_paused}); return {data:{paused:!!p_paused},error:null}; },
    admin_align_enqueue({p_track}){ if(!isAdmin()) return E("NOT_ALLOWED: 運営だけが使えます"); db.alignJobs=db.alignJobs||{};
      const t=db.tracks.find(x=>x.id===p_track); const s=db.lyricsSync[p_track];
      if(db.alignJobs[p_track]) return {data:{result:"duplicate"},error:null};
      if(s&&t&&s.hash===lhash(t.lyrics)){ db.alignJobs[p_track]={state:"skipped",reason:"has_sync"}; save(); return {data:{result:"skipped"},error:null}; }
      db.alignJobs[p_track]={state:"queued",reason:"admin"}; save(); window.__log.push({op:"admin_align_enqueue",track:p_track}); return {data:{result:"queued"},error:null}; },
    admin_align_enqueue_existing(){ if(!isAdmin()) return E("NOT_ALLOWED: 運営だけが使えます"); db.alignJobs=db.alignJobs||{}; const out={};
      db.tracks.filter(t=>t.status==="public").forEach(t=>{ let r; if(db.alignJobs[t.id]) r="duplicate"; else if(!(t.lyrics||[]).some(l=>String(l).trim()&&!isHead(l))){ r="waiting"; db.alignJobs[t.id]={state:"waiting",reason:"no_lyrics"}; }
        else if(db.lyricsSync[t.id]&&db.lyricsSync[t.id].hash===lhash(t.lyrics)){ r="skipped"; db.alignJobs[t.id]={state:"skipped",reason:"has_sync"}; } else { r="queued"; db.alignJobs[t.id]={state:"queued",reason:"existing"}; } out[r]=(out[r]||0)+1; });
      save(); window.__log.push({op:"admin_align_enqueue_existing",out}); return {data:out,error:null}; },
    admin_align_retry({p_track}){ if(!isAdmin()) return E("NOT_ALLOWED: 運営だけが使えます"); const j=(db.alignJobs||{})[p_track]; if(!j||!["failed","skipped","dismissed"].includes(j.state)) return E("BAD_DATA: 打ち切り・対象外・不採用の曲だけ、やり直せます");
      j.state="queued"; j.reason="admin_retry"; save(); return {data:{result:"queued"},error:null}; }
  };
  const alignRole = t => !t||!uid() ? null : isAdmin() ? "admin" : (t.user_id===uid()&&active()) ? "owner" : null;
  const rpcs = {
    ...rpcsSync,
    // v1.9（migration_v1_9_delete.sql と同じ規則。規則そのものは test_v19.py で実際の PostgreSQL に対して検証済み）
    delete_my_track({p_track}){
      if(window.__noV19) return E("Could not find the function public.delete_my_track");
      if(window.__fail.deleteTrack) return E("ネットワークエラー");
      const me=uid(); if(!me) return E("ログインしてください");
      if(!active()) return E("楽曲を削除できません（ログイン状態・メール確認・利用状況を確認してください）");
      const t=db.tracks.find(x=>x.id===p_track);
      if(!t){ return db.trackDeletions.some(d=>d.track.id===p_track&&d.track.user_id===me) ? {data:"already_deleted",error:null} : E("楽曲が見つかりません"); }
      if(t.user_id!==me) return E("楽曲が見つかりません");
      db.trackDeletions.push({track:{...t},reason:"owner",at:Date.now()});
      db.tracks=db.tracks.filter(x=>x!==t); db.favorites=db.favorites.filter(f=>f.track_id!==p_track); save();
      return {data:"deleted",error:null};
    },
    my_account_deletion(){
      if(window.__noV19) return E("Could not find the function public.my_account_deletion");
      const d=db.deletions.find(x=>x.user_id===uid()&&ACTIVE.includes(x.status));
      return {data: d ? [{status:d.status,requested_at:d.requested_at,purge_after:d.purge_after,can_cancel:d.status==="pending"&&Date.parse(d.purge_after)>Date.now()}] : [], error:null};
    },
    cancel_my_account_deletion(){
      if(window.__fail.cancel) return E("ネットワークエラー");
      const me=uid(); if(!me) return E("ログインしてください");
      const d=db.deletions.find(x=>x.user_id===me&&ACTIVE.includes(x.status));
      if(!d) return E("取り消せる退会申請がありません");
      if(d.status!=="pending") return E("完全削除の処理がすでに始まっているため、取り消せません");
      if(Date.parse(d.purge_after)<=Date.now()) return E("取り消しの期限（申請から30日）を過ぎたため、取り消せません");
      d.status="canceled"; let n=0;
      d.hidden.forEach(h=>{ const t=db.tracks.find(x=>x.id===h.id&&x.status==="hidden"); if(t){ t.status=h.status; n++; } }); save();
      return {data:[{status:"canceled",restored:n,kept_hidden:0}],error:null};
    },
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
    // v1.11 プレイリスト（migration_v1_11_playlists.sql と同じ規則。規則そのものは test_v111.py で実際の PostgreSQL に対して検証済み）
    my_playlists(){ const me=uid(); if(!me) return E("permission denied for function my_playlists");
      return {data:(db.playlists||[]).filter(p=>p.user_id===me).map(p=>({id:p.id,name:p.name,is_public:p.is_public,updated_at:p.updated_at,track_ids:p.track_ids.slice()})),error:null}; },
    public_playlists(){ const pubT=new Set(db.tracks.filter(t=>t.status==="public").map(t=>t.id));
      return {data:(db.playlists||[]).filter(p=>p.is_public&&visible(p.user_id)).map(p=>({id:p.id,name:p.name,updated_at:p.updated_at,track_ids:p.track_ids.filter(t=>pubT.has(t))})).filter(p=>p.track_ids.length).sort((a,b)=>b.updated_at.localeCompare(a.updated_at)),error:null}; },
    create_playlist({p_name,p_public}){ const me=uid(); db.playlists=db.playlists||[];
      if(!me||!active()) return E("プレイリストを作成できません（ログイン状態・メール確認・利用状況を確認してください）");
      if(db.playlists.filter(p=>p.user_id===me).length>=50) return E("プレイリストは1人50個までです");
      const n=plName(p_name); if(n.error) return n;
      const id="pl000000-0000-4000-8000-"+String(Date.now()).slice(-12).padStart(12,"0"), now=new Date().toISOString(); db.playlists.push({id,user_id:me,name:n,is_public:!!p_public,updated_at:now,track_ids:[]}); save(); return {data:id,error:null}; },
    update_playlist({p_id,p_name,p_public}){ const p=plOwned(p_id); if(p.error) return p;
      if(p_name!=null){ const n=plName(p_name); if(n.error) return n; p.name=n; } if(p_public!=null) p.is_public=!!p_public; p.updated_at=new Date().toISOString(); save(); return {data:null,error:null}; },
    delete_playlist({p_id}){ const p=plOwned(p_id); if(p.error) return p; db.playlists=db.playlists.filter(x=>x.id!==p_id); save(); return {data:null,error:null}; },
    playlist_add_track({p_id,p_track}){ const p=plOwned(p_id); if(p.error) return p;
      if(!db.tracks.find(t=>t.id===p_track&&t.status==="public")) return E("公開中の曲だけ追加できます");
      if(!p.track_ids.includes(p_track)){ if(p.track_ids.length>=200) return E("1つのプレイリストに入れられる曲は200曲までです"); p.track_ids.push(p_track); }
      p.updated_at=new Date().toISOString(); save(); return {data:null,error:null}; },
    playlist_remove_track({p_id,p_track}){ const p=plOwned(p_id); if(p.error) return p; p.track_ids=p.track_ids.filter(t=>t!==p_track); p.updated_at=new Date().toISOString(); save(); return {data:null,error:null}; },
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
    set_my_theme({p_theme}){
      if(window.__fail && window.__fail.theme) return E("ネットワークエラー");
      const me=uid(); if(!me) return E("ERROR: ログインしてください");
      const t=p_theme, K=["v","preset","accent","bg","button"], H=/^#[0-9a-fA-F]{6}$/;
      const okT = t===null || (t && typeof t==="object" && !Array.isArray(t) && K.every(k=>k in t) && Object.keys(t).every(k=>K.includes(k)) && t.v===1
        && ["standard","ocean","rose","emerald","gold","mono","custom"].includes(t.preset) && ["accent","bg","button"].every(k=>typeof t[k]==="string"&&H.test(t[k])));
      if(!okT) return E("ERROR: テーマの形式が正しくありません");
      const p=db.profiles.find(x=>x.id===me); p.theme=t; save(); return {data:null,error:null};
    },
    rename_my_artist({p_artist,p_name}){
      if(window.__fail.rename) return E("ネットワークエラー");
      const me=uid(); if(!me||!active()) return E("ERROR: アーティスト名を変更できません");
      const v=(p_name||"").replace(/\s+/g," ").trim();
      if(v.length<1||[...v].length>40) return E("ERROR: アーティスト名は1〜40文字で入力してください");
      if(/[\u0000-\u001f\u007f\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/.test(v)) return E("ERROR: アーティスト名に使用できない文字が含まれています");
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

  // 本物の supabase-js と同じく、作成時にアドレスのメールリンク情報（#access_token…&type=recovery / #error_code=…）を読み取って消し、
  // 読み込みが終わった直後（setTimeout 0）に、その時点で登録済みの受け取り先へだけ PASSWORD_RECOVERY を通知する
  let initP = Promise.resolve();
  const detectUrl = () => {
    const h = new URLSearchParams((location.hash||"").replace(/^#/,""));
    if(!h.get("access_token") && !h.get("error_code") && !h.get("error")) return;
    history.replaceState(null, "", location.pathname + location.search);
    if(h.get("error_code") || h.get("error")) return;
    const u = Object.entries(USERS).find(([e,x])=>"jwt-"+x.id===h.get("access_token"));
    if(!u) return;
    session = { user:{ id:u[1].id, email:u[0] }, access_token:h.get("access_token"), reauthAt:Date.now() };
    localStorage.setItem("fake-session", JSON.stringify(session));
    window.__recoveryNotified = 0;
    initP = delay().then(()=>{ if(h.get("type")==="recovery") setTimeout(()=>{ window.__recoveryNotified = listeners.size; listeners.forEach(cb=>cb("PASSWORD_RECOVERY", session)); },0); });
  };
  window.supabase = { createClient(){ detectUrl(); return {
    auth:{
      async getSession(){ await initP; await delay(); return { data:{ session } }; },
      onAuthStateChange(cb){ listeners.add(cb); setTimeout(()=>cb("INITIAL_SESSION", session),0); return { data:{ subscription:{ unsubscribe(){ listeners.delete(cb) } } } }; },
      async signInWithPassword({email,password}){ await delay(); const u=USERS[email]; if(!u||password==="wrong") return {data:{user:null,session:null},error:{message:"Invalid login credentials"}};
        session = { user:{ id:u.id, email }, access_token:"jwt-"+u.id, reauthAt:Date.now() }; localStorage.setItem("fake-session", JSON.stringify(session)); fire("SIGNED_IN"); return { data:{ session, user:session.user }, error:null }; },
      async signOut(o){ await delay(); window.__log.push({op:"signOut",scope:o&&o.scope}); if(o&&o.scope==="others") return { error:null }; session=null; localStorage.removeItem("fake-session"); fire("SIGNED_OUT"); return { error:null }; },
      async signUp(){ return { error:{message:"n/a"} }; }, async updateUser(a){ await delay(); window.__log.push({op:"updateUser",hasPassword:!!(a&&a.password)}); return { error:null }; }, async resetPasswordForEmail(){ return { error:null }; }
    },
    // Edge Function（account-delete-request）の代わり：パスワード照合・1時間5回まで・管理者は不可（本物の処理は tests/edge で検証）
    functions:{ async invoke(name,{body}={}){ await delay(); window.__log.push({op:"invoke",name,hasPassword:!!(body&&body.password)});
      const fail=(status,code)=>({data:null,error:{message:"Edge Function returned a non-2xx status code",context:{status,json:async()=>({code})}}});
      if(window.__noFn) return fail(404,"NOT_FOUND");
      const me=uid(); if(!me) return fail(401,"LOGIN_REQUIRED");
      db.reauthFails=db.reauthFails||{}; const n=db.reauthFails[me]||0;
      if(n>=5) return fail(429,"TOO_MANY_ATTEMPTS");
      if(!body||body.password!=="password"){ db.reauthFails[me]=n+1; save(); return fail(401,"WRONG_PASSWORD"); }
      if(isAdmin()) return fail(403,"ADMIN_ACCOUNT");
      if(window.__deleteMode==="off") return fail(403,"DELETION_DISABLED");   // サーバー側の受付スイッチ（本物は Edge Function とデータベースの両方）
      let d=db.deletions.find(x=>x.user_id===me&&ACTIVE.includes(x.status));
      if(!d){ const now=new Date();
        d={user_id:me,status:"pending",requested_at:now.toISOString(),purge_after:new Date(now.getTime()+30*86400000).toISOString(),
           hidden:db.tracks.filter(t=>t.user_id===me&&["public","pending"].includes(t.status)).map(t=>({id:t.id,status:t.status}))};
        db.deletions.push(d); db.tracks.forEach(t=>{ if(t.user_id===me&&["public","pending"].includes(t.status)) t.status="hidden"; }); save(); }
      window.__log.push({op:"signOutOthers(server)"});
      return {data:{status:d.status,purge_after:d.purge_after},error:null};
    } },
    from: query,
    async rpc(name, args){ await delay(); window.__log.push({op:"rpc",name,args});
      if(window.__noV16 && !["artist_follower_count","increment_plays","set_duration_if_missing"].includes(name)) return E(`Could not find the function public.${name}`);
      return rpcs[name] ? rpcs[name](args||{}) : {data:null,error:null}; },
    storage:{ from(bucket){
      if(bucket==="avatars") return avatarStore;
      return { async createSignedUrls(paths){ return { data: paths.map(p=>({ path:p, signedUrl:(p.endsWith(".jpg")||p.endsWith(".png")?"data:audio/mpeg;base64,":(window.__testAudio||"data:audio/mpeg;base64,")), error:null })), error:null }; },
               async remove(paths){ window.__log.push({op:"media_remove",bucket,paths}); return {error:null}; },
               // 音源・ジャケット（audio・covers）：本人の会員IDのフォルダだけ。window.__fail.media で失敗を注入
               async upload(path, blob, opts){ await delay();
                 if(window.__fail.media) return E("アップロードに失敗しました（テスト用）");
                 const me=uid(); if(!me||!active()||!path.startsWith(me+"/")) return E("new row violates row-level security policy");
                 window.__log.push({op:"upload",bucket,path,size:blob.size,type:opts&&opts.contentType}); return {data:{path},error:null}; } };
    } }
  }; } };
})();
