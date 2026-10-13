/* ================================================================
   CAPA SUPABASE (PostgREST + RPC)
   Todas las escrituras van por funciones seguras del servidor.
   ================================================================ */
const SB_URL = "https://upvqpyxscajqoszqsowa.supabase.co/rest/v1";
const SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVwdnFweXhzY2FqcW9zenFzb3dhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEzOTM5NTEsImV4cCI6MjEwNjk2OTk1MX0.JH-kcwpAd6y7BCqzTE5vj_hbNdbxaZecnty6XjPvQwg";

/* Fichas con las que empieza cada cuenta nueva (0 si prefieres que solo el admin recargue) */
const SALDO_INICIAL = 100;
const WA = "https://wa.me/58097787";
/* Ms que deben pasar entre el fin de una ronda y la creación de la siguiente (deja que todos vean el ganador) */
const NEW_ROUND_DELAY = 12000;

async function api(path, opts){
  const ctrl = new AbortController();
  const t = setTimeout(()=>ctrl.abort(), 20000);
  try{
    const r = await fetch(SB_URL + path, {
      ...opts,
      headers: { "apikey": SB_KEY, "Authorization": "Bearer " + SB_KEY, "Content-Type": "application/json" },
      signal: ctrl.signal
    });
    clearTimeout(t);
    const txt = await r.text();
    let j = null;
    try{ j = txt ? JSON.parse(txt) : null; }catch(e){ j = null; }
    if(!r.ok){
      const msg = (j && j.message) || ("HTTP " + r.status);
      const e = new Error(msg); e.status = r.status; e.body = j; throw e;
    }
    return j;
  }catch(e){
    clearTimeout(t);
    if(e.name === "AbortError") throw new Error("El servidor no respondió a tiempo (red).");
    if(e.message === "Failed to fetch") throw new Error("No se pudo conectar con el servidor. Revisa tu internet.");
    throw e;
  }
}
const sbRpc = (fn, body) => api("/rpc/" + fn, { method: "POST", body: JSON.stringify(body || {}) });
const sbRead = path => api("/" + path, { method: "GET" });

let current = null;
let token = null;
let pendingReveal = null;
let userTimer = null;
let adminTimer = null;
let usersCache = [], ledgerCache = [], statsCache = null, agentsCache = [], dailyCache = [];

/* ---------------- utilidades ---------------- */
function normName(n){ return String(n||"").trim().toLowerCase().replace(/\//g,"_"); }
function showMsg(t){ const e=document.getElementById("msg"); e.textContent=t; e.classList.remove("hidden"); }
function escapeHtml(v){ return String(v).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#039;"); }

/* Traduce los errores de la red/servidor a mensajes entendibles */
function msgDeError(e){
  if(!e) return "Error desconocido.";
  const m = (e && e.message) || "";
  if(!m) return "Error desconocido.";
  if(/No se pudo conectar|no respondió|Failed to fetch|NetworkError|offline/i.test(m))
    return "Sin conexión con el servidor. Revisa tu internet (prueba con datos móviles en vez de WiFi) y desactiva VPN o bloqueadores de anuncios.";
  if(/no está permitido|rechazad|violates row|permission/i.test(m))
    return "El servidor rechazó la operación.";
  return m;
}

/* Banner inferior de diagnóstico */
function bannerConexion(html, esError){
  let b = document.getElementById("diagBanner");
  if(!b){
    b = document.createElement("div");
    b.id = "diagBanner";
    b.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:10000;padding:11px 14px;font:13px/1.45 system-ui,-apple-system,sans-serif;text-align:center;color:#fff;box-shadow:0 -4px 20px rgba(0,0,0,.5)";
    document.body.appendChild(b);
  }
  b.style.background = esError ? "#7a1420" : "#14532d";
  b.innerHTML = html;
  if(!esError) setTimeout(()=>{ if(b) b.remove(); }, 4000);
}

async function diagnosticoSupabase(){
  /* reintenta hasta 3 veces porque en redes lentas la 1ª petición tarda más */
  for(let i=1;i<=3;i++){
    const timeout = new Promise((_,rej)=>setTimeout(()=>rej({code:"timeout",message:"Sin respuesta tras 20 segundos"}), 20000));
    try{
      await Promise.race([ sbRead("v_users?select=id&limit=1"), timeout ]);
      bannerConexion("✅ Conectado al servidor correctamente. ¡Todo listo!", false);
      return;
    }catch(e){
      if(i<3){ await new Promise(r=>setTimeout(r,1500)); continue; }
      bannerConexion("⚠️ Sin conexión con el servidor &nbsp;<b>("+((e&&e.code)||"error")+")</b>: "+escapeHtml(msgDeError(e))+
        "<br>Prueba con <b>datos móviles</b> en vez de WiFi, o desactiva <b>VPN / adblock</b>. A veces la 1ª conexión en redes lentas tarda unos segundos: recarga la página.", true);
    }
  }
}

async function hashPass(p){
  if(window.crypto && crypto.subtle){
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("casino:"+p));
    return Array.from(new Uint8Array(buf)).map(b=>b.toString(16).padStart(2,"0")).join("");
  }
  let h=5381;
  for(let i=0;i<p.length;i++) h=((h<<5)+h+p.charCodeAt(i))>>>0;
  return "weak:"+h;
}

function defaultAvatar(){ return "data:image/svg+xml;charset=UTF-8,"+encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" rx="50" fill="#263552"/><text x="50" y="62" text-anchor="middle" font-size="45" fill="#f5c451">♛</text></svg>`); }

function shrinkImage(src,size){
  return new Promise(res=>{
    const img=new Image();
    img.onload=()=>{
      const c=document.createElement("canvas");
      const k=Math.min(size/img.width,size/img.height,1);
      c.width=Math.max(1,Math.round(img.width*k));
      c.height=Math.max(1,Math.round(img.height*k));
      c.getContext("2d").drawImage(img,0,0,c.width,c.height);
      res(c.toDataURL("image/jpeg",.85));
    };
    img.onerror=()=>res(src);
    img.src=src;
  });
}

/* ---------------- saldo visible ---------------- */
function updateBalanceUI(){
  if(!current) return;
  const shown = current.balance - (pendingReveal ? pendingReveal.prize : 0);
  const set = (id)=>{ const el=document.getElementById(id); if(el) el.textContent = shown; };
  set("balance"); set("topBalance"); set("cashierBalance");
}

/* Actualiza el usuario actual cada 2 s (equivalente al tiempo real de antes) */
function startUserPoll(){
  stopUserPoll();
  userTimer = setInterval(async ()=>{
    if(!current) return;
    try{
      const u = await sbRpc("get_user", { p_token: token });
      if(u && u.id){ current = u; updateBalanceUI(); updateAgentUI(); renderProfile(); }
    }catch(e){}
  }, 2000);
}
function stopUserPoll(){ if(userTimer){ clearInterval(userTimer); userTimer = null; } }

/* ---------------- navegación tipo app ---------------- */
const NAV_TABS = ["home","cashier","profile","admin"];
const GAME_SCREENS = ["rouletteGame","rouletteGame2","scratchGame","betGame","c3Game","agentPanel","agentStats"];

function hideGameScreens(){
  GAME_SCREENS.forEach(id=>{ const el=document.getElementById(id); if(el) el.classList.add("hidden"); });
}

function goTab(name){
  if(!current) return;
  hideGameScreens();
  NAV_TABS.forEach(t=>{
    const el = document.getElementById("tab" + t.charAt(0).toUpperCase() + t.slice(1));
    if(el) el.classList.toggle("hidden", t !== name);
  });
  const nav = document.getElementById("appNav");
  if(nav){
    nav.classList.remove("hidden");
    nav.querySelectorAll("button").forEach(b=>b.classList.toggle("on", (b.getAttribute("data-tab")||"") === name || b.id === "nav-"+name));
  }
  if(name === "home"){
    const mg = document.getElementById("mainGames"); if(mg) mg.classList.remove("hidden");
    updateAgentUI();
  }
  if(name === "cashier") loadMyMoves();
  if(name === "profile") renderProfile();
  if(name === "admin"){
    document.getElementById("admin").classList.remove("hidden");
    startAdminWatch();
    refreshAdmin();
  }
}

function renderProfile(){
  if(!current) return;
  const n=document.getElementById("profName"), i=document.getElementById("profId"),
        a=document.getElementById("profAvatar"), ag=document.getElementById("profAgent"),
        ab=document.getElementById("profAgentBtn");
  if(n) n.textContent = current.admin ? "Administrador" : current.name;
  if(i) i.textContent = (current.num != null ? ("ID " + current.num) : "ID —") + " · usuario " + current.id;
  if(a) a.src = current.avatar || defaultAvatar();
  if(ag) ag.textContent = current.agent ? ("🧑‍💼 Agente · código " + (current.agent_code||"—") + " · comisión " + (current.commission||0) + "%") : "";
  if(ab) ab.classList.toggle("hidden", !current.agent);
}

async function loadMyMoves(){
  if(!current) return;
  const tb = document.getElementById("myMoves"); if(!tb) return;
  try{
    const rows = await sbRead("ledger?select=date,type,amount,detail,ts&uname=eq." + encodeURIComponent(current.name) + "&order=ts.desc&limit=30");
    const arr = Array.isArray(rows) ? rows : [];
    tb.innerHTML = arr.map(x=>`<tr><td>${escapeHtml(x.date)}</td><td>${escapeHtml(x.type)}</td><td class="${x.amount>=0?"ok":"bad"}">${money(x.amount)}</td><td>${escapeHtml(x.detail||"")}</td></tr>`).join("")
      || '<tr><td colspan="4" class="muted">Sin movimientos todavía.</td></tr>';
  }catch(e){ tb.innerHTML = '<tr><td colspan="4" class="muted">No se pudieron cargar los movimientos.</td></tr>'; }
}

/* ---------------- sesión ---------------- */
async function register(){
  const raw = document.getElementById("rName").value.trim();
  const p = document.getElementById("rPass").value;
  if(!raw || !p) return showMsg("Completa usuario y contraseña.");
  const docId = normName(raw);
  if(!docId || docId==="." || docId==="..") return showMsg("Nombre de usuario no válido.");
  if(docId.length>24) return showMsg("El usuario debe tener máximo 24 caracteres.");
  const agEl = document.getElementById("rAgent");
  const agCode = (agEl ? agEl.value : "").trim();
  let reg;
  try{
    reg = await sbRpc("register_user", {
      p_id: docId,
      p_name: docId==="admin" ? "admin" : raw,
      p_pass: await hashPass(p),
      p_balance: 0,
      p_admin: false,
      p_created: Date.now()
    });
  }catch(e){ return showMsg(msgDeError(e)); }
  if(!reg || !reg.token) return showMsg("No se pudo crear la cuenta. Intenta de nuevo.");
  token = reg.token;
  let refErr = null;
  if(agCode){
    try{ await sbRpc("apply_referral", { p_token: token, p_code: agCode }); }
    catch(e){ refErr = e.message || "código de agente no válido"; }
  }
  const u = await sbRpc("get_user", { p_token: token });
  current = u || { id:docId, name:raw, balance:0, avatar:"", admin:!!reg.admin };
  localStorage.setItem("casino_token", token);
  await enter();
  showMsg(refErr ? ("Cuenta creada. Aviso: "+refErr) : "Cuenta creada correctamente.");
}

async function login(){
  const docId = normName(liUser.value);
  const p = liPass.value;
  if(!docId || docId==="." || docId==="..") return showMsg("Usuario o contraseña incorrectos.");
  try{
    const u = await sbRpc("login", { p_id: docId, p_pass: await hashPass(p) });
    if(!u || !u.id || !u.token) return showMsg("Usuario o contraseña incorrectos.");
    token = u.token;
    delete u.token;
    current = u;
    localStorage.setItem("casino_token", token);
    await enter();
  }catch(e){ showMsg("No se pudo conectar: "+msgDeError(e)); }
}

async function enter(){
  startPortalRain();
  document.getElementById("auth").classList.add("hidden");
  document.getElementById("app").classList.remove("hidden");
  document.getElementById("profileMenu").classList.add("hidden");
  const isAdmin = !!(current && current.admin);
  document.getElementById("welcome").textContent = isAdmin ? "Administrador" : current.name;
  document.getElementById("uid").textContent = (current.num != null ? current.num : current.id);
  document.getElementById("avatar").src = current.avatar || defaultAvatar();
  const nav = document.getElementById("appNav");
  if(nav) nav.classList.remove("hidden");
  const navAdm = document.getElementById("nav-admin");
  if(navAdm) navAdm.classList.toggle("hidden", !isAdmin);
  if(isAdmin){
    document.getElementById("admin").classList.remove("hidden");
    startAdminWatch();
  }else{
    document.getElementById("admin").classList.add("hidden");
    stopAdminWatch();
  }
  updateBalanceUI();
  renderProfile();
  goTab("home");
  startUserPoll();
  R1.refresh(); R2.refresh();
  updateAgentUI();
}

function logout(){
  stopPortalRain();
  stopUserPoll();
  stopAdminWatch();
  localStorage.removeItem("casino_token");
  current = null; token = null; pendingReveal = null;
  document.getElementById("app").classList.add("hidden");
  const nav = document.getElementById("appNav");
  if(nav) nav.classList.add("hidden");
  document.getElementById("auth").classList.remove("hidden");
  liPass.value = "";
  showMsg("Sesión cerrada.");
}

function toggleProfile(){ document.getElementById("profileMenu").classList.toggle("hidden"); }

async function changePassword(){
  const p = prompt("Nueva contraseña:");
  if(!p) return;
  try{
    await sbRpc("change_password", { p_token: token, p_pass: await hashPass(p) });
    alert("Contraseña cambiada.");
  }catch(e){ alert("Error: "+e.message); }
}

async function sendFichas(){
  const target = prompt("Número de ID del destinatario (el número de su perfil, ej: 1003):");
  if(target===null) return;
  const idNum = String(target).replace(/[^0-9]/g,"");
  if(!idNum) return alert("Escribe el número de ID del destinatario (solo números).");
  if(String(current.num)===idNum) return alert("No puedes enviarte fichas a ti mismo.");
  const amount = Number(prompt("Cantidad de fichas:"));
  if(!Number.isFinite(amount) || amount<=0) return alert("Cantidad no válida.");
  try{
    await sbRpc("send_fichas", { p_token: token, p_to: idNum, p_amount: amount, p_now: Date.now() });
    alert("Transferencia realizada.");
  }catch(e){ alert(e.message||"Error en la transferencia."); }
}

function uploadAvatar(){
  const input = document.createElement("input");
  input.type = "file"; input.accept = "image/*";
  input.onchange = async ()=>{
    const f = input.files[0]; if(!f) return;
    const r = new FileReader();
    r.onload = async ()=>{
      try{
        const dataUrl = await shrinkImage(r.result, 128);
        await sbRpc("set_avatar", { p_token: token, p_avatar: dataUrl });
        current.avatar = dataUrl;
        document.getElementById("avatar").src = dataUrl;
      }catch(e){ alert("No se pudo subir la imagen: "+e.message); }
    };
    r.readAsDataURL(f);
  };
  input.click();
}

function recharge(){ window.open(WA+"?text="+encodeURIComponent("Hola, quiero solicitar una recarga de fichas. Mi ID es "+current.id),"_blank"); }

/* ---------------- panel de administración ---------------- */
function startAdminWatch(){
  stopAdminWatch();
  refreshAdmin();
  adminTimer = setInterval(refreshAdmin, 3000);
}
function stopAdminWatch(){ if(adminTimer){ clearInterval(adminTimer); adminTimer=null; } }

let adminSelId = null, adminSelStats = null, agentsSel = null;

async function refreshAdmin(){
  if(!current || !current.admin) return;
  try{
    const [ou, ol, os, oa, od] = await Promise.all([
      sbRead("v_users?select=id,num,name,balance,admin"),
      sbRead("ledger?select=*&order=ts.desc&limit=150"),
      sbRead("scratch_stats?select=*&limit=1"),
      sbRpc("admin_agent_list", { p_token: token }),
      sbRpc("admin_daily_profit", { p_token: token })
    ]);
    usersCache = Array.isArray(ou) ? ou : [];
    ledgerCache = Array.isArray(ol) ? ol : [];
    statsCache = (Array.isArray(os) && os[0]) || null;
    agentsCache = Array.isArray(oa) ? oa : [];
    dailyCache = Array.isArray(od) ? od : [];
    renderAdmin();
    try{ C3.adminInfo(true); }catch(e){}
    try{ CF.adminInfo(true); }catch(e){}
  }catch(e){}
}

function renderAdmin(){
  if(!current || !current.admin) return;
  const pl = usersCache.filter(u=>!u.admin);
  document.getElementById("adminUsers").textContent = pl.length;
  document.getElementById("adminBalance").textContent = pl.reduce((s,u)=>s+(u.balance||0),0);
  pl.sort((a,b)=>(b.num||0)-(a.num||0));
  const sel = document.getElementById("adminTarget");
  const keep = sel && sel.value;
  if(sel) sel.innerHTML = pl.map(u=>`<option value="${escapeHtml(u.id)}">#${u.num} ${escapeHtml(u.name)} — ${u.balance} fichas</option>`).join("");
  if(keep && sel && [...sel.options].some(o=>o.value===keep)) sel.value = keep;
  const list = document.getElementById("adminUserList");
  if(list){
    list.innerHTML = pl.map(u=>`<button class="adm-urow${u.id===adminSelId?" on":""}" data-id="${escapeHtml(u.id)}" onclick="adminSelectUser('${u.id}')">
      <span class="adm-unum">#${u.num}</span>
      <span class="adm-uname">${escapeHtml(u.name)}</span>
      <span class="adm-ubal">${u.balance} 🪙</span>
    </button>`).join("") || '<div class="muted" style="padding:8px">Sin usuarios.</div>';
  }
  renderScratchStats();
  renderAgents();
  renderDaily();
  document.getElementById("ledger").innerHTML = ledgerDataHtml();
  if(adminSelId) updateSelRowHighlight();
}

function toggleLedger(){
  const w = document.getElementById("ledgerWrap"); if(!w) return;
  const c = document.getElementById("ledgerCaret");
  const open = w.classList.toggle("hidden") === false;
  if(c) c.textContent = open ? "▾" : "▸";
}

function renderDaily(){
  const box = document.getElementById("adminDaily"); if(!box) return;
  box.innerHTML = dailyCache.map(d=>`<tr><td>${escapeHtml(String(d.day))}</td><td>${d.profit} 🪙</td><td class="bad">${d.commission?-d.commission:0} 🪙</td><td class="${d.net>=0?"ok":"bad"}">${d.net} 🪙</td></tr>`).join("")
    || '<tr><td colspan="4" class="muted">Sin datos todavía.</td></tr>';
}

function renderAgents(){
  const list = document.getElementById("agentAdminList");
  if(list){
    list.innerHTML = agentsCache.map(a=>`<button class="adm-urow${a.id===agentsSel?" on":""}" onclick="adminAgentSelect('${escapeHtml(a.id)}')" data-ag="${escapeHtml(a.id)}">
      <span class="adm-unum">#${a.num}</span>
      <span class="adm-uname">${escapeHtml(a.name)}
        <span class="muted" style="font-size:12px">· ${escapeHtml(a.code)} · ${a.commission}%</span></span>
      <span class="adm-ubal">${a.players_count} jug. · ${a.players_balance} 🪙</span>
    </button>`).join("") || '<div class="muted" style="padding:8px">Sin agentes todavía. Selecciona un usuario arriba y usa "Hacer agente".</div>';
  }
  renderAgentDetail();
}

function renderAgentDetail(){
  const box = document.getElementById("agentAdminDetail"); if(!box) return;
  if(!agentsSel){ box.innerHTML = '<div class="muted" style="padding:8px">Toca un agente para ver qué usuarios tiene bajo su mando.</div>'; return; }
  const a = agentsCache.find(x=>x.id===agentsSel);
  if(!a){ box.innerHTML = '<div class="muted" style="padding:8px">Ese agente ya no existe.</div>'; return; }
  const pls = a.players || [];
  box.innerHTML = `
    <strong>${escapeHtml(a.name)}</strong> <span class="adm-unum">#${a.num}</span>
    <span class="muted" style="font-size:12px">· ${escapeHtml(a.code)} · ${a.commission}%</span>
    <div style="margin-top:8px">👥 Usuarios bajo su mando:</div>
    <div class="adm-list" style="margin-top:6px">
      ${pls.map(p=>`<div class="adm-urow" style="cursor:default">
        <span class="adm-unum">#${p.num}</span>
        <span class="adm-uname">${escapeHtml(p.name)}</span>
        <span class="adm-ubal">${p.balance} 🪙</span>
        <button class="ghost" style="width:auto;padding:4px 8px" onclick="adminAgentRemove('${escapeHtml(p.id)}')">− Quitar</button>
      </div>`).join("") || '<div class="muted" style="padding:6px">Sin usuarios todavía.</div>'}
    </div>`;
}

function updateSelRowHighlight(){
  document.querySelectorAll("#adminUserList .adm-urow").forEach(b=>{
    if(b.dataset.id === adminSelId) b.classList.add("on"); else b.classList.remove("on");
  });
}

function adminSelectUser(id){
  adminSelId = id;
  if(adminTarget) adminTarget.value = id;
  updateSelRowHighlight();
  adminLoadStats(id);
}

async function adminLoadStats(id){
  const box = document.getElementById("adminUserDetail");
  if(!box) return;
  box.innerHTML = '<div class="muted" style="padding:10px">Cargando datos…</div>';
  try{
    const s = await sbRpc("admin_user_stats", { p_token: token, p_user_id: id });
    adminSelStats = s;
    renderUserDetail(s);
  }catch(e){ box.innerHTML = '<div class="bad" style="padding:10px">'+escapeHtml(e.message||"Error al cargar.")+'</div>'; }
}

function money(v){ return (v>0?"+":"")+v; }

function renderUserDetail(s){
  const box = document.getElementById("adminUserDetail"); if(!box || !s) return;
  const byType = (s.byType||[]).map(t=>`<tr><td>${escapeHtml(t.type)}</td><td>${t.count}</td><td class="${t.sum>=0?"ok":"bad"}">${money(t.sum)}</td></tr>`).join("") || '<tr><td colspan="3" class="muted">Sin movimientos.</td></tr>';
  const last = (s.last||[]).map(x=>`<tr><td>${escapeHtml(x.date)}</td><td>${escapeHtml(x.type)}</td><td class="${x.amount>=0?"ok":"bad"}">${money(x.amount)}</td><td>${escapeHtml(x.detail||"")}</td></tr>`).join("") || '<tr><td colspan="4" class="muted">Sin movimientos.</td></tr>';
  const b = s.bets || {};
  box.innerHTML = `
    <div class="card" style="background:linear-gradient(180deg,#17152a,#0b1220);border:1px solid #6b5420">
      <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px">
        <div><strong style="font-size:18px">${escapeHtml(s.name)}</strong> <span class="adm-unum">#${s.num}</span>
          <div class="muted" style="font-size:12px">Usuario: ${escapeHtml(s.id)}</div></div>
        <div style="text-align:right"><div class="muted" style="font-size:12px">Saldo actual</div><div class="balance" style="font-size:22px">${s.balance} 🪙</div></div>
      </div>
      <div class="grid" style="margin-top:10px">
        <div><div class="muted">Ganado (juegos)</div><div class="balance ok">+${s.won}</div></div>
        <div><div class="muted">Perdido (juegos)</div><div class="balance bad">${s.lost}</div></div>
      </div>
      <div class="grid">
        <div><div class="muted">Neto en juegos</div><div class="balance ${s.gameNet>=0?"ok":"bad"}">${money(s.gameNet)}</div></div>
        <div><div class="muted">Neto total</div><div class="balance ${s.net>=0?"ok":"bad"}">${money(s.net)}</div></div>
      </div>
      <div class="muted" style="font-size:13px;margin-top:8px">Recargas: <b class="ok">+${s.recargas}</b> · Retiros: <b class="bad">${s.retiros}</b> · Transferencias: <b>${money(s.transferencias)}</b></div>
      <div class="muted" style="font-size:13px;margin-top:4px">🎯 Apuestas: ${b.count||0} · apostado ${b.staked||0} · ganado ${b.payout||0} · (${b.won||0} ganadas, ${b.lost||0} perdidas, ${b.open||0} en juego)</div>
      <div class="muted" style="font-size:13px;margin-top:4px">🏆 Rondas ganadas: ${(s.rounds&&s.rounds.games)||0} · premios ${(s.rounds&&s.rounds.prize)||0} 🪙</div>
      <div style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap">
        <button class="danger" onclick="adminDeleteUser('${s.id}')">🗑️ Eliminar usuario</button>
        <button class="ghost" onclick="adminAdjust(1)">＋ Dar fichas</button>
        <button class="ghost" onclick="adminAdjust(-1)">− Quitar fichas</button>
      </div>
    </div>
    <h3>Desglose por tipo</h3>
    <div style="overflow:auto"><table><thead><tr><th>Tipo</th><th>Veces</th><th>Total</th></tr></thead><tbody>${byType}</tbody></table></div>
    <h3>Últimos movimientos</h3>
    <div style="overflow:auto"><table><thead><tr><th>Fecha</th><th>Tipo</th><th>Fichas</th><th>Detalle</th></tr></thead><tbody>${last}</tbody></table></div>`;
}

async function adminDeleteUser(id){
  const u = usersCache.find(x=>x.id===id) || {};
  if(!confirm("¿Eliminar definitivamente a "+(u.name||id)+" (#"+(u.num||"?")+")?\nSe borrarán su cuenta, sus apuestas y sus movimientos del historial. No se puede deshacer.")) return;
  try{
    await sbRpc("admin_delete_user", { p_token: token, p_user_id: id });
    adminSelId = null; adminSelStats = null;
    const box = document.getElementById("adminUserDetail");
    if(box) box.innerHTML = '<div class="muted" style="padding:10px">Selecciona un usuario de la lista para ver sus datos.</div>';
    refreshAdmin();
    alert("Usuario eliminado.");
  }catch(e){ alert(e.message||"No se pudo eliminar."); }
}

function renderScratchStats(){
  const e = document.getElementById("scratchStats"); if(!e) return;
  const s = statsCache || {cards:0,bets:0,paid:0};
  const profit = s.bets - s.paid, pct = s.bets ? (profit/s.bets*100).toFixed(1) : "0.0";
  e.innerHTML = `🎟️ Raspa y Gana: ${s.cards} cartones · apostado ${s.bets} · pagado ${s.paid} · ganancia de la casa <b class="${profit>=0?"ok":"bad"}">${profit} (${pct}%)</b> · fondo de premios disponible: ${Math.max(0,Math.floor(s.bets*.9)-s.paid)} · mínimo garantizado 10%`;
}

async function adminAdjust(sign){
  const toId = adminSelId || (adminTarget && adminTarget.value);
  const a = Math.floor(Number(adminAmount.value));
  if(!toId) return alert("Toca primero un usuario de la lista.");
  if(!Number.isFinite(a) || a<=0) return alert("Escribe una cantidad válida en fichas (número entero mayor que 0).");
  try{
    await sbRpc("admin_adjust", { p_token: token, p_to: toId, p_amount: a, p_sign: sign, p_now: Date.now() });
    adminAmount.value = "";
    if(adminSelId === toId) adminLoadStats(toId);
    refreshAdmin();
    alert((sign>0?"Se sumaron ":"Se quitaron ")+a+" fichas.");
  }catch(e){ alert(e.message||"Error al ajustar fichas."); }
}

async function adminMakeAgent(isAgent){
  if(!adminSelId) return alert("Toca primero un usuario de la lista de arriba.");
  const codeEl = document.getElementById("agentCodeInput");
  const commEl = document.getElementById("agentCommissionInput");
  const code = (codeEl ? codeEl.value : "").trim();
  const comm = Math.floor(Number(commEl ? commEl.value : 10));
  if(!confirm((isAgent?"¿Hacer agente a":"¿Quitar el rol de agente a")+" este usuario?")) return;
  try{
    await sbRpc("admin_agent_set", {
      p_token: token, p_user_id: adminSelId, p_is_agent: isAgent,
      p_commission: Number.isFinite(comm) ? comm : 10, p_code: code
    });
    alert(isAgent ? "Usuario marcado como agente." : "Se quitó el rol de agente.");
    refreshAdmin();
  }catch(e){ alert(e.message||"Error al actualizar el agente."); }
}

function adminAgentSelect(id){
  agentsSel = (agentsSel === id) ? null : id;
  renderAgents();
}

async function adminAgentAdd(){
  if(!agentsSel) return alert("Toca primero un agente de la lista.");
  if(!adminSelId) return alert("Selecciona primero un usuario en la lista de arriba.");
  try{
    await sbRpc("admin_agent_assign", { p_token: token, p_player: adminSelId, p_agent: agentsSel });
    alert("Usuario añadido al agente.");
    refreshAdmin();
  }catch(e){ alert(e.message||"Error al añadir el usuario."); }
}

async function adminAgentRemove(playerId){
  if(!confirm("¿Quitar este usuario del agente?")) return;
  try{
    await sbRpc("admin_agent_assign", { p_token: token, p_player: playerId, p_agent: null });
    alert("Usuario quitado del agente.");
    refreshAdmin();
  }catch(e){ alert(e.message||"Error al quitar el usuario."); }
}

function ledgerDataHtml(){
  return ledgerCache.map(x=>`<tr><td>${escapeHtml(x.date)}</td><td>${escapeHtml(x.uname)}</td><td>${escapeHtml(x.type)}</td><td class="${x.amount>=0?"ok":"bad"}">${x.amount>0?"+":""}${x.amount}</td><td>${escapeHtml(x.detail)}</td></tr>`).join("")
    || `<tr><td colspan="5" class="muted">Sin movimientos.</td></tr>`;
}

/* ================================================================
   AGENTES / AFILIADOS (panel del agente + gestión del admin)
   ================================================================ */
function updateAgentUI(){
  const card = document.getElementById("agentCard");
  const btn = document.getElementById("agentStatsBtn");
  const isAg = !!(current && current.agent);
  if(card){ card.classList.toggle("hidden", !isAg); }
  if(btn){ btn.classList.toggle("hidden", !isAg); }
}

const AG = (function(){
  const $ = n => document.getElementById(n);
  let players = [], sel = null, repCache = null, selDay = null;

  function open(){
    if(!current || !current.agent) return alert("No eres agente.");
    $("agentPanel").classList.remove("hidden");
    $("mainGames").classList.add("hidden");
    sel = null;
    $("agentDetail").innerHTML = '<div class="muted" style="padding:10px">Selecciona un jugador de la lista.</div>';
    refresh();
    window.scrollTo(0,0);
  }
  function close(){
    $("agentPanel").classList.add("hidden");
    $("mainGames").classList.remove("hidden");
  }

  async function refresh(){
    if(!current || !current.agent) return;
    try{
      const [sum, pl] = await Promise.all([
        sbRpc("agent_summary", { p_token: token }),
        sbRpc("agent_players", { p_token: token })
      ]);
      players = Array.isArray(pl) ? pl : [];
      renderSummary(sum || {});
      renderPlayers();
      refreshBal();
    }catch(e){
      const b = $("agentSummary"); if(b) b.innerHTML = '<b class="bad">'+escapeHtml(e.message||"Error al cargar.")+'</b>';
    }
  }
  async function refreshBal(){
    try{ const u = await sbRpc("get_user", { p_token: token }); if(u && u.id){ current.balance = u.balance; updateBalanceUI(); } }catch(e){}
  }

  function renderSummary(s){
    const box = $("agentSummary"); if(!box) return;
    box.innerHTML = `🆔 Código de agente: <b>${escapeHtml(s.code||"—")}</b> · Comisión: <b>${s.commission||0}%</b> ·
      Jugadores: <b>${s.players||0}</b> · Saldo gestionado: <b>${s.managed_balance||0} 🪙</b><br>
      Comisión acumulada: <b>${s.earned||0}</b> ·
      Ya cobrada: <b>${s.paid||0}</b> · <span class="ok">Por cobrar: ${s.pending||0} 🪙</span>
      <div style="margin-top:10px"><button class="primary" onclick="AG.pay()">💰 Cobrar comisión</button></div>`;
  }

  function renderPlayers(){
    const box = $("agentPlayers"); if(!box) return;
    box.innerHTML = players.map(p=>`<button class="adm-urow${p.id===sel?" on":""}" onclick="AG.select('${escapeHtml(p.id)}')">
      <span class="adm-unum">#${p.num}</span>
      <span class="adm-uname">${escapeHtml(p.name)}</span>
      <span class="adm-ubal">${p.balance} 🪙</span>
      <span class="adm-ubal" style="color:#7ee2a8" title="Comisión ganada hoy">+${p.today||0} hoy</span>
    </button>`).join("") || '<div class="muted" style="padding:8px">Aún no tienes jugadores afiliados. Comparte tu código al registrarse.</div>';
  }

  async function select(id){
    sel = id; renderPlayers();
    const box = $("agentDetail"); if(!box) return;
    box.innerHTML = '<div class="muted" style="padding:10px">Cargando…</div>';
    try{
      const s = await sbRpc("agent_player_stats", { p_token: token, p_player: id });
      renderDetail(s);
    }catch(e){ box.innerHTML = '<div class="bad" style="padding:10px">'+escapeHtml(e.message||"Error al cargar.")+'</div>'; }
  }

  function renderDetail(s){
    const box = $("agentDetail"); if(!box || !s) return;
    const last = (s.last||[]).slice(0,20).map(x=>`<tr><td>${escapeHtml(x.date)}</td><td>${escapeHtml(x.type)}</td><td class="${x.amount>=0?"ok":"bad"}">${x.amount>0?"+":""}${x.amount}</td><td>${escapeHtml(x.detail||"")}</td></tr>`).join("") || '<tr><td colspan="4" class="muted">Sin movimientos.</td></tr>';
    box.innerHTML = `
      <div class="card" style="background:linear-gradient(180deg,#17152a,#0b1220);border:1px solid #6b5420">
        <div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px">
          <div><strong style="font-size:18px">${escapeHtml(s.name)}</strong> <span class="adm-unum">#${s.num}</span></div>
          <div style="text-align:right"><div class="muted" style="font-size:12px">Saldo actual</div><div class="balance" style="font-size:22px">${s.balance} 🪙</div></div>
        </div>
        <div class="grid" style="margin-top:10px">
          <div><div class="muted">Neto en juegos</div><div class="balance ${s.gameNet>=0?"ok":"bad"}">${money(s.gameNet)}</div></div>
          <div><div class="muted">Neto total</div><div class="balance ${s.net>=0?"ok":"bad"}">${money(s.net)}</div></div>
        </div>
      </div>
      <h3>Últimos movimientos</h3>
      <div style="overflow:auto"><table><thead><tr><th>Fecha</th><th>Tipo</th><th>Fichas</th><th>Detalle</th></tr></thead><tbody>${last}</tbody></table></div>`;
  }

  async function pay(){
    try{
      const r = await sbRpc("agent_pay_commission", { p_token: token, p_now: Date.now() });
      alert((r && r.paid>0) ? ("Cobraste "+r.paid+" fichas de comisión.") : "No tienes comisión pendiente.");
      await refresh();
    }catch(e){ alert(e.message||"No se pudo cobrar la comisión."); }
  }

  function stats(){
    if(!current || !current.agent) return alert("No eres agente.");
    const menu = $("profileMenu"); if(menu) menu.classList.add("hidden");
    $("agentPanel").classList.add("hidden");
    $("mainGames").classList.add("hidden");
    $("agentStats").classList.remove("hidden");
    $("agentStatsSummary").innerHTML = '<span class="muted">Cargando…</span>';
    $("agentStatsDays").innerHTML = '';
    $("agentStatsPlayers").innerHTML = '';
    window.scrollTo(0,0);
    return statsRefresh();
  }
  function closeStats(){
    $("agentStats").classList.add("hidden");
    $("mainGames").classList.remove("hidden");
  }
  async function statsRefresh(){
    if(!current || !current.agent) return;
    try{
      const r = await sbRpc("agent_commission_report", { p_token: token });
      renderStats(r || {});
    }catch(e){
      const b = $("agentStatsSummary"); if(b) b.innerHTML = '<b class="bad">'+escapeHtml(e.message||"Error al cargar.")+'</b>';
    }
  }
  function renderStats(r){
    repCache = r || {};
    selDay = null;
    const sum = $("agentStatsSummary");
    if(sum) sum.innerHTML = `Comisión: <b>${r.rate||0}%</b> · Comisión acumulada: <b class="ok">${r.total_commission||0} 🪙</b>`;
    const arr = repCache.by_day || [];
    if(arr.length) selDay = String(arr[0].day);
    renderDays();
    renderByPlayer();
  }
  function renderDays(){
    const box = $("agentStatsDays"); if(!box) return;
    const arr = (repCache && repCache.by_day) || [];
    box.innerHTML = arr.map(d=>{ const dd = String(d.day); const on = dd===selDay;
      return `<tr style="cursor:pointer${on?";background:#2a2340":""}" onclick="AG.pickDay('${dd}')"><td>${escapeHtml(dd)}</td><td>${d.players||0}</td><td class="ok">${d.commission||0} 🪙</td></tr>`;
    }).join("") || '<tr><td colspan="3" class="muted">Todavía no hay comisiones registradas.</td></tr>';
  }
  function renderByPlayer(){
    const box = $("agentStatsPlayers"); if(!box) return;
    const t = $("agentStatsPlayersTitle");
    if(t) t.textContent = selDay ? ("👥 Comisión por jugador — " + selDay) : "👥 Comisión por jugador";
    const arr = ((repCache && repCache.by_player_day) || []).filter(p=>String(p.day)===selDay);
    box.innerHTML = arr.map(p=>`<tr><td>${escapeHtml(String(p.name))} <span class="adm-unum">#${p.num}</span></td><td class="ok">${p.commission||0} 🪙</td></tr>`).join("")
      || '<tr><td colspan="2" class="muted">Sin comisiones ese día.</td></tr>';
  }
  function pickDay(d){ selDay = d; renderDays(); renderByPlayer(); }

  return {open, close, refresh, select, pay, stats, closeStats, pickDay};
})();

/* ================================================================
   RULETA COMPARTIDA (Supabase + polling)
   Cada instancia (R1/R2) tiene su propia fila en la tabla rounds.
   ================================================================ */
function makeRoulette(cfg){
  const sfx = cfg.sfx, el = n=>document.getElementById(n+sfx);
  let data=null, timerInt=null, rotation=0, busy=false, settling=false, creating=false, pollTimer=null, pollBusy=false;
  const roundPath = "rounds?select=*&id=eq." + encodeURIComponent(cfg.doc);
  const msg = (t,html)=>{ const m=el("rouletteMessage"); if(!m) return; if(html) m.innerHTML=t; else m.textContent=t; };
  const isOpen = ()=>{ const g=el("rouletteGame"); return g && !g.classList.contains("hidden"); };
  const norm = d=>({ id:d.id, start:Number(d.start)||Date.now(), end:Number(d.ends)||0, participants:d.participants||[], finished:!!d.finished, winnerId:d.winner_id||null, winnerName:d.winner_name||null, winnerIndex:Number.isFinite(d.winner_index)?d.winner_index:-1, prize:Number(d.prize)||0, finishedAt:Number(d.finished_at)||0 });

  async function ensure(){
    try{
      await sbRpc("ensure_round", { p_id: cfg.doc, p_now: Date.now(), p_end: Date.now()+cfg.duration, p_delay: NEW_ROUND_DELAY });
    }catch(e){ console.warn("ensure "+cfg.label+":", e.message); }
  }

  async function pull(){
    if(pollBusy || creating) return;
    pollBusy = true;
    try{
      let rows = await sbRead(roundPath);
      if(!rows || !rows.length){
        await ensure();
        rows = await sbRead(roundPath);
      }
      if(!rows || !rows.length) return;
      const prev = data;
      const nd = norm(rows[0]);
      const gainedFinish = !(prev && prev.finished) && nd.finished;
      data = nd;
      draw(); renderParticipants();
      if(isOpen()) updateTimer();
      if(!prev) return;
      if(gainedFinish){
        if(nd.winnerIndex>=0 && nd.participants.length && nd.winnerName){
          busy = true;
          spinTo(nd.winnerIndex, nd.participants.length, announce);
        }else{
          msg("No hubo participantes en esta ronda.");
          busy = true;
          setTimeout(()=>{ busy=false; }, 3000);
        }
        return;
      }
      if(prev.finished && !nd.finished){
        rotation = 0; resetWheel();
        if(!busy && isOpen()) msg(`🎡 Nueva ronda abierta. ¡Participa con ${cfg.cost} fichas!`);
      }
    }catch(e){ console.warn("Ronda "+cfg.label+":", e.message); }
    finally{ pollBusy = false; }
  }

  function subscribe(){
    if(pollTimer) return;
    ensure();
    pull();
    pollTimer = setInterval(pull, 1500);
  }

  /* Cierra la ronda vencida (la función del servidor es atómica) */
  async function settleRound(){
    if(settling || !data) return;
    settling = true;
    try{
      await sbRpc("settle_round", { p_round: cfg.doc, p_label: cfg.label, p_cost: cfg.cost, p_now: Date.now() });
    }catch(e){ console.warn(e); }
    finally{ settling = false; }
  }

  /* Abre una ronda nueva (solo si la anterior ya lleva NEW_ROUND_DELAY terminada) */
  async function tryNewRound(){
    if(creating) return;
    creating = true;
    try{ await ensure(); }catch(e){ console.warn(e); }
    finally{ creating = false; }
    pull();
  }

  function join(){
    if(!current) return;
    if(current.admin) return alert("La cuenta de administración no puede participar.");
    if(busy) return alert("La ronda está terminando. Espera a que abra la siguiente.");
    if(!data) return alert("La ronda se está cargando, intenta de nuevo en un momento.");
    if(data.finished || Date.now()>=data.end) return alert("La ronda está terminando. Espera la siguiente.");
    if(data.participants.some(p=>p.id===current.id)) return alert("Ya estás participando en esta ronda.");
    if(current.balance<cfg.cost) return alert(`No tienes suficientes fichas. Necesitas ${cfg.cost} fichas.`);
    return sbRpc("join_round", { p_round: cfg.doc, p_token: token, p_cost: cfg.cost, p_label: cfg.label, p_now: Date.now() })
      .then(()=>{
        msg("🎡 ¡Ya estás dentro de la ruleta!");
        if(isOpen()) updateTimer();
        pull();
      })
      .catch(e=>alert(e.message||"No se pudo participar."));
  }

  function draw(){
    const canvas = el("rouletteCanvas"); if(!canvas) return;
    const ctx = canvas.getContext("2d"), size = canvas.width, cx = size/2, cy = size/2, radius = size/2-5;
    ctx.clearRect(0,0,size,size);
    const ps = (data && data.participants) || [];
    if(!ps.length){
      ctx.beginPath(); ctx.arc(cx,cy,radius,0,Math.PI*2); ctx.fillStyle="#171f32"; ctx.fill();
      ctx.strokeStyle="#f5c451"; ctx.lineWidth=4; ctx.stroke();
      ctx.fillStyle="#f5c451"; ctx.font="bold 22px system-ui"; ctx.textAlign="center"; ctx.textBaseline="middle";
      ctx.fillText("ESPERANDO",cx,cy-15); ctx.fillText("PARTICIPANTES",cx,cy+18);
      return;
    }
    const slice = Math.PI*2/ps.length, colors = ["#c0392b","#8e44ad","#2980b9","#16a085","#d35400","#2c3e50","#7f8c8d","#27ae60","#34495e","#9b59b6"];
    ps.forEach((p,i)=>{
      const start = -Math.PI/2+i*slice, end = start+slice;
      ctx.beginPath(); ctx.moveTo(cx,cy); ctx.arc(cx,cy,radius,start,end); ctx.closePath();
      ctx.fillStyle = colors[i%colors.length]; ctx.fill();
      ctx.strokeStyle="#f5c451"; ctx.lineWidth=2; ctx.stroke();
      ctx.save(); ctx.translate(cx,cy); ctx.rotate(start+slice/2);
      ctx.textAlign="right"; ctx.textBaseline="middle"; ctx.fillStyle="#fff";
      let fs=17; if(p.name.length>12) fs=13; if(p.name.length>18) fs=10;
      ctx.font=`bold ${fs}px system-ui`;
      const name = p.name.length>22 ? p.name.slice(0,21)+"…" : p.name;
      ctx.shadowColor="#000"; ctx.shadowBlur=4; ctx.fillText(name,radius-14,0);
      ctx.restore();
    });
    ctx.beginPath(); ctx.arc(cx,cy,radius,0,Math.PI*2); ctx.strokeStyle="#f5c451"; ctx.lineWidth=5; ctx.stroke();
  }

  function renderParticipants(){
    const box = el("rouletteParticipants"); if(!box) return;
    const ps = (data && data.participants) || [];
    if(!ps.length){ box.innerHTML = '<div class="muted">No hay participantes todavía.</div>'; return; }
    box.innerHTML = ps.map((p,i)=>`<div class="participant"><div class="num">${i+1}</div><div><strong>${escapeHtml(p.name)}</strong><div class="muted" style="font-size:12px">🪙 ${cfg.cost} fichas</div></div></div>`).join("");
  }

  function updateTimer(){
    if(timerInt){ clearInterval(timerInt); timerInt=null; }
    const t = el("rouletteTimer"); if(!t || !data) return;
    const tick = ()=>{
      if(!data) return;
      const rem = data.end - Date.now();
      if(rem<=0){
        t.textContent = "00:00:00";
        if(!data.finished && !busy && !settling) settleRound();
        if(timerInt){ clearInterval(timerInt); timerInt=null; }
        return;
      }
      const s = Math.floor(rem/1000), h = Math.floor(s/3600), m = Math.floor((s%3600)/60), sec = s%60;
      t.textContent = `${String(h).padStart(2,"0")}:${String(m).padStart(2,"0")}:${String(sec).padStart(2,"0")}`;
    };
    tick();
    if(!timerInt && data && data.end-Date.now()>0) timerInt = setInterval(tick,1000);
  }

  function spinTo(wi,count,callback){
    const canvas = el("rouletteCanvas"); if(!canvas) return callback();
    const slice = 360/count, target = -(wi*slice+slice/2), extra = 360*6;
    const finalRotation = rotation+extra+target, startRotation = rotation, duration = 5000, startTime = performance.now();
    function animate(now){
      const progress = Math.min(1,(now-startTime)/duration), eased = 1-Math.pow(1-progress,3);
      rotation = startRotation+(finalRotation-startRotation)*eased;
      canvas.style.transform = `rotate(${rotation}deg)`;
      if(progress<1) requestAnimationFrame(animate);
      else { rotation = finalRotation; callback(); }
    }
    requestAnimationFrame(animate);
  }

  function resetWheel(){ rotation=0; const c=el("rouletteCanvas"); if(c) c.style.transform="rotate(0deg)"; }

  function announce(){
    triggerWinRain();
    if(data && data.winnerName){
      msg(`🏆 <strong>¡GANADOR!</strong><br>🎉 ${escapeHtml(data.winnerName)}<br>🪙 Premio: ${data.prize} fichas`, true);
    }
    setTimeout(()=>{
      busy = false;
      if(data && !data.finished){ resetWheel(); if(isOpen()) msg(`🎡 Nueva ronda abierta. ¡Participa con ${cfg.cost} fichas!`); }
      tryNewRound();
    }, 7000);
  }

  function open(){
    subscribe();
    el("rouletteGame").classList.remove("hidden");
    document.getElementById("mainGames").classList.add("hidden");
    draw(); renderParticipants();
    if(!data) msg("⏳ Cargando la ronda…");
    else if(data.finished) msg("La ronda anterior terminó. Preparando la siguiente…");
    updateTimer();
    window.scrollTo(0,0);
  }
  function close(){
    el("rouletteGame").classList.add("hidden");
    document.getElementById("mainGames").classList.remove("hidden");
    if(timerInt){ clearInterval(timerInt); timerInt=null; }
  }
  function refresh(){ if(isOpen()){ draw(); renderParticipants(); updateTimer(); } }

  function watch(){
    if(!data) return;
    if(!data.finished && Date.now()>=data.end && !busy && !settling) settleRound();
    else if(data.finished && !busy && !creating && Date.now()-(data.finishedAt||0)>=NEW_ROUND_DELAY) tryNewRound();
  }

  return {open,close,join,refresh,watch,subscribe};
}

const R1 = makeRoulette({sfx:"", doc:"r1", cost:50, duration:60*60*1000, label:"Ruleta"});
const R2 = makeRoulette({sfx:"2", doc:"r2", cost:5, duration:60*1000, label:"Ruleta Rápida"});
setInterval(()=>{ R1.watch(); R2.watch(); }, 1000);

/* ================================================================
   RASPA Y GANA
   Tabla de premios [fichas, peso sobre 1000]. Retorno esperado:
   (10·190+20·80+50·30+100·10+200·5+1000·2)/1000 = 9 fichas por cartón de 10
   ================================================================ */
const SCRATCH_COST = 10;
const SCRATCH_TABLE = [[0,683],[10,190],[20,80],[50,30],[100,10],[200,5],[1000,2]];
const SCRATCH_SYMS = [10,20,50,100,200,1000];
const SCRATCH_ICON = {10:"🍒",20:"🍋",50:"🔔",100:"💎",200:"⭐",1000:"👑"};

const SC = (function(){
  const $ = n=>document.getElementById(n);
  let state=null, drawing=false, last=null;
  const msg = t=>{ $("scratchMsg").innerHTML = t; };
  function rInt(n){ const a=new Uint32Array(1), lim=Math.floor(4294967296/n)*n; do{crypto.getRandomValues(a)}while(a[0]>=lim); return a[0]%n; }
  function board(prize){
    const cells=[], cnt={}, add=x=>{ cells.push(x); cnt[x]=(cnt[x]||0)+1; };
    if(prize>0) for(let i=0;i<3;i++) add(prize);
    while(cells.length<9){ const x=SCRATCH_SYMS[rInt(SCRATCH_SYMS.length)]; if(x!==prize && (cnt[x]||0)<2) add(x); }
    for(let i=8;i>0;i--){ const j=rInt(i+1); [cells[i],cells[j]]=[cells[j],cells[i]]; }
    return cells;
  }
  function cover(){
    const c=$("scratchCanvas"), x=c.getContext("2d");
    x.globalCompositeOperation="source-over"; x.clearRect(0,0,c.width,c.height);
    const g=x.createLinearGradient(0,0,c.width,c.height);
    g.addColorStop(0,"#dfe3ec"); g.addColorStop(.5,"#9aa3b5"); g.addColorStop(1,"#d3d8e2");
    x.fillStyle=g; x.fillRect(0,0,c.width,c.height);
    x.fillStyle="rgba(60,50,20,.35)"; x.font="bold 26px system-ui"; x.textAlign="center"; x.textBaseline="middle";
    x.fillText("♛ RASCA AQUÍ ♛",c.width/2,c.height/2);
    c.style.opacity=1; c.style.pointerEvents="none";
  }
  function placeholder(){ $("scratchBoard").innerHTML = Array(9).fill("<div>❓</div>").join(""); }
  function open(){
    $("scratchGame").classList.remove("hidden");
    document.getElementById("mainGames").classList.add("hidden");
    if(!state){ placeholder(); cover(); }
    window.scrollTo(0,0);
  }
  function close(){
    if(state && !state.revealed) reveal();
    $("scratchGame").classList.add("hidden");
    document.getElementById("mainGames").classList.remove("hidden");
  }

  async function buy(){
    if(!current || current.admin) return alert("La cuenta de administración no puede jugar.");
    if(state && !state.revealed) reveal();
    if(current.balance < SCRATCH_COST) return alert(`No tienes suficientes fichas. Necesitas ${SCRATCH_COST} fichas.`);
    let res;
    try{
      res = await sbRpc("scratch_buy", { p_token: token, p_price: SCRATCH_COST, p_now: Date.now() });
    }catch(e){ return alert(e.message||"No se pudo comprar el cartón."); }

    const prize = Number(res && res.prize) || 0;
    state = { prize, cells: board(prize), revealed:false };
    pendingReveal = { prize };
    current.balance = Number(res.new_bal);
    $("scratchBoard").innerHTML = state.cells.map(x=>`<div data-v="${x}">${SCRATCH_ICON[x]}<small>${x}</small></div>`).join("");
    cover();
    $("scratchCanvas").style.pointerEvents = "auto";
    $("scratchAllBtn").classList.remove("hidden");
    updateBalanceUI();
    msg("🎟️ ¡Rasca el cartón!");
  }

  function scratchAt(e){
    const c=$("scratchCanvas"), r=c.getBoundingClientRect(), k=c.width/r.width;
    const x=(e.clientX-r.left)*k, y=(e.clientY-r.top)*k, ctx=c.getContext("2d");
    ctx.globalCompositeOperation="destination-out"; ctx.lineWidth=50; ctx.lineCap="round"; ctx.lineJoin="round";
    ctx.beginPath(); ctx.moveTo(last?last.x:x, last?last.y:y); ctx.lineTo(x,y+.01); ctx.stroke(); last={x,y};
  }
  function cleared(){
    const c=$("scratchCanvas"), d=c.getContext("2d").getImageData(0,0,c.width,c.height).data;
    let t=0, n=0;
    for(let i=3;i<d.length;i+=64){ n++; if(d[i]<128) t++; }
    return t/n;
  }
  function reveal(){
    if(!state || state.revealed) return;
    state.revealed = true;
    const c=$("scratchCanvas");
    c.style.opacity=0; c.style.pointerEvents="none";
    $("scratchAllBtn").classList.add("hidden");
    pendingReveal = null;
    if(state.prize>0){
      document.querySelectorAll("#scratchBoard div").forEach(d=>{ if(Number(d.dataset.v)===state.prize) d.classList.add("win"); });
      msg(`🏆 <strong>¡GANASTE!</strong><br>🪙 Premio: ${state.prize} fichas`);
      triggerWinRain();
    }else{
      msg("😕 Sin premio esta vez. ¡Prueba con otro cartón!");
    }
    updateBalanceUI();
  }
  const cv=$("scratchCanvas");
  cv.addEventListener("pointerdown",e=>{ if(!state||state.revealed) return; drawing=true; last=null; cv.setPointerCapture(e.pointerId); scratchAt(e); });
  cv.addEventListener("pointermove",e=>{ if(drawing) scratchAt(e); });
  const end=()=>{ if(!drawing) return; drawing=false; last=null; if(cleared()>.55) reveal(); };
  cv.addEventListener("pointerup",end);
  cv.addEventListener("pointercancel",end);
  return {open,close,buy,reveal};
})();


/* ================================================================
   APUESTAS DEPORTIVAS (The Odds API + Supabase)
   Las cuotas y resultados los trae el servidor; aquí solo se apuesta
   sobre el saldo de fichas del casino.
   ================================================================ */
const BETS = (function(){
  const $ = n => document.getElementById(n);
  let data = null, timer = null, busy = false, sel = null, adminInfoDone = false;

  function fmtWhen(ms){
    if(!ms) return "";
    const d = new Date(ms);
    return d.toLocaleDateString("es", {weekday:"short", day:"2-digit", month:"short"}) + " " +
           d.toLocaleTimeString("es", {hour:"2-digit", minute:"2-digit"});
  }
  function fmtUpd(ms){
    if(!ms) return "—";
    const s = Math.floor((Date.now() - ms)/1000);
    if(s < 60) return "hace un momento";
    if(s < 3600) return "hace " + Math.floor(s/60) + " min";
    if(s < 86400) return "hace " + Math.floor(s/3600) + " h";
    return "hace " + Math.floor(s/86400) + " días";
  }
  const msg = (t, html)=>{ const m=$("betMsg"); if(!m) return; if(html) m.innerHTML=t; else m.textContent=t; m.classList.remove("hidden"); };
  const hideBar = ()=>{ sel=null; const b=$("betBar"); if(b) b.classList.add("hidden"); };

  function open(){
    $("betGame").classList.remove("hidden");
    $("mainGames").classList.add("hidden");
    hideBar();
    msg("⏳ Cargando partidos…");
    load();
    if(timer) clearInterval(timer);
    timer = setInterval(()=>{ if($("betGame") && !$("betGame").classList.contains("hidden")) load(true); }, 20000);
    window.scrollTo(0,0);
  }
  function close(){
    $("betGame").classList.add("hidden");
    $("mainGames").classList.remove("hidden");
    if(timer){ clearInterval(timer); timer = null; }
    hideBar();
  }

  async function load(silent){
    if(busy || !current) return;
    busy = true;
    try{
      const r = await sbRpc("bets_list", { p_token: token });
      data = r || {};
      if(typeof data.balance === "number"){ current.balance = data.balance; updateBalanceUI(); }
      render();
      if(!silent) msg(data.events && data.events.length ? "Elige un partido y toca una cuota (1 · X · 2) para apostar." : "No hay partidos disponibles ahora mismo. Vuelve más tarde.");
    }catch(e){ if(!silent) msg("No se pudo cargar: " + msgDeError(e)); }
    finally{ busy = false; }
  }

  function render(){
    const bal = $("betBalance"), upd = $("betUpdated");
    if(bal) bal.textContent = (data && typeof data.balance==="number") ? data.balance : (current ? current.balance : 0);
    if(upd) upd.textContent = fmtUpd(data && data.updated);
    renderEvents();
    renderMine();
  }

  function renderEvents(){
    const box = $("betList"); if(!box) return;
    const evs = (data && data.events) || [];
    if(!evs.length){ box.innerHTML = '<div class="muted" style="padding:14px">No hay partidos disponibles ahora mismo.</div>'; return; }
    const has = sel ? sel.id : null;
    box.innerHTML = evs.map(e=>{
      const settled = e.status !== "open";
      const started = e.commence <= Date.now();
      const canBet = !settled && !started;
      const mine = e.mine;
      const resName = e.result === "home" ? e.home : e.result === "away" ? e.away : e.result === "draw" ? "Empate" : null;
      const opt = (pick, name, odds, cls)=>{
        if(odds==null) return "";
        const chosen = sel && sel.id===e.id && sel.pick===pick ? " on" : "";
        const win = settled && e.result===pick ? " win" : "";
        const mineOn = mine && mine.pick===pick ? " mine" : "";
        const dis = canBet ? "" : " disabled";
        return `<button class="bet-opt${chosen}${win}${mineOn}"${dis} onclick="BETS.choose('${e.id}','${pick}')">
          <span class="lbl">${pick==="home"?"1":pick==="draw"?"X":"2"}</span><span class="nm">${escapeHtml(name)}</span><span class="od">${odds}</span></button>`;
      };
      return `<div class="bet-ev">
        <div class="bet-ev-top"><span class="bet-sport">${escapeHtml(e.sport||"")}</span><span class="bet-when">${settled ? "Finalizado" : escapeHtml(fmtWhen(e.commence))}</span></div>
        <div class="bet-teams">${escapeHtml(e.home)} <span class="muted">vs</span> ${escapeHtml(e.away)}</div>
        ${settled ? `<div class="bet-res ${resName?"ok":"bad"}">Resultado: ${resName?escapeHtml(resName):"—"}</div>` : ""}
        <div class="bet-opts">
          ${opt("home", e.home, e.oh)}
          ${opt("draw", "Empate", e.od)}
          ${opt("away", e.away, e.oa)}
        </div>
        ${mine ? `<div class="bet-mineline">Tu apuesta: ${escapeHtml(mine.pick_name)} · ${mine.stake} fichas x${mine.odds} · ${betStatusTxt(mine)}</div>` : ""}
      </div>`;
    }).join("");
  }

  function betStatusTxt(b){
    if(b.status==="won") return `<b class="ok">GANADA +${b.payout}</b>`;
    if(b.status==="lost") return `<b class="bad">perdida</b>`;
    if(b.status==="void") return `<b class="muted">anulada (devuelta)</b>`;
    return `<b class="muted">en juego</b>`;
  }

  function renderMine(){
    const box = $("betMine"); if(!box) return;
    const mine = (data && data.mine) || [];
    if(!mine.length){ box.innerHTML = '<div class="muted" style="padding:10px">Todavía no has hecho ninguna apuesta.</div>'; return; }
    box.innerHTML = mine.slice(0, 25).map(b=>`<div class="bet-mrow">
      <div class="bet-mmain"><strong>${escapeHtml(b.home)}</strong> <span class="muted">vs</span> <strong>${escapeHtml(b.away)}</strong>
        <div class="muted" style="font-size:12px">${escapeHtml(b.pick_name)} · apuesta ${b.stake} · cuota x${b.odds}</div></div>
      <div class="bet-mstat">${betStatusTxt(b)}</div>
    </div>`).join("");
  }

  function choose(id, pick){
    if(!current) return;
    if(current.admin) return alert("La cuenta de administración no puede apostar.");
    const e = (data && data.events || []).find(x=>x.id===id);
    if(!e) return;
    const name = pick==="home" ? e.home : pick==="away" ? e.away : "Empate";
    const odds = pick==="home" ? e.oh : pick==="away" ? e.oa : e.od;
    if(odds == null) return alert("Ese pronóstico no está disponible.");
    sel = { id, pick, odds, name };
    const bar = $("betBar"); if(!bar) return;
    $("betBarText").innerHTML = `Apostar a <b>${escapeHtml(name)}</b> · cuota <b>x${odds}</b>`;
    $("betStake").value = "";
    bar.classList.remove("hidden");
    renderEvents();
    setTimeout(()=>{ const i=$("betStake"); if(i) i.focus(); }, 50);
  }

  async function place(){
    if(!sel || !current) return;
    const stake = Math.floor(Number($("betStake").value));
    if(!Number.isFinite(stake) || stake <= 0) return alert("Escribe cuántas fichas quieres apostar.");
    if(stake > current.balance) return alert("No tienes suficientes fichas (tienes " + current.balance + ").");
    const btn = $("betPlaceBtn"); if(btn){ btn.disabled = true; btn.textContent = "Apostando…"; }
    const name = sel.name;
    try{
      const r = await sbRpc("bets_place", { p_token: token, p_event: sel.id, p_pick: sel.pick, p_stake: stake, p_now: Date.now() });
      data = r || data;
      if(typeof data.balance === "number"){ current.balance = data.balance; updateBalanceUI(); }
      hideBar();
      render();
      msg(`✅ Apuesta registrada: ${stake} fichas a <b>${escapeHtml(name)}</b>. ¡Suerte!`, true);
    }catch(e){ alert(e.message || "No se pudo apostar."); }
    finally{ if(btn){ btn.disabled = false; btn.textContent = "Apostar"; } }
  }

  /* ---- admin ---- */
  async function adminSave(){
    if(!current || !current.admin) return;
    const raw = ($("betAdminSports") && $("betAdminSports").value || "").trim();
    const arr = raw ? raw.split(",").map(s=>s.trim()).filter(Boolean) : null;
    try{
      const r = await sbRpc("bets_admin_setup", { p_token: token, p_key: null, p_sports: arr });
      adminShow(r);
      alert("Deportes guardados. Ahora pulsa «Actualizar cuotas».");
    }catch(e){ alert(e.message || "Error al guardar."); }
  }
  function adminShow(r){
    const box = $("betAdminInfo"); if(!box || !r) return;
    const sp = (r.sports || []).join(", ");
    box.innerHTML = `Deportes activos: <b>${escapeHtml(sp || "—")}</b> · Actualizado ${fmtUpd(r.updated)}`;
  }
  async function adminRefresh(){
    if(!current || !current.admin) return;
    const box = $("betAdminInfo"); if(box) box.innerHTML = "Actualizando cuotas… (puede tardar unos segundos)";
    try{
      const r = await sbRpc("bets_admin_refresh", { p_token: token });
      const d = (r && r.detail) || {};
      const txt = Object.keys(d).map(k=>`${k}: ${d[k]}`).join(" · ");
      const cfg = await sbRpc("bets_admin_setup", { p_token: token, p_key: null, p_sports: null });
      if(box) box.innerHTML = `Cuotas actualizadas (${(r&&r.total)||0} partidos).<br>${escapeHtml(txt)}<br>Deportes activos: <b>${escapeHtml((cfg.sports||[]).join(", "))}</b>`;
      load(true);
    }catch(e){ alert(e.message || "Error al actualizar cuotas."); }
  }
  async function adminSettle(){
    if(!current || !current.admin) return;
    const box = $("betAdminInfo"); if(box) box.innerHTML = "Revisando resultados…";
    try{
      const r = await sbRpc("bets_admin_settle", { p_token: token });
      const d = (r && r.detail) || {};
      const txt = Object.keys(d).map(k=>`${k}: ${d[k]}`).join(" · ");
      if(box) box.innerHTML = `Resultados revisados. Apuestas pagadas: <b>${(r&&r.total)||0}</b><br>${escapeHtml(txt)}`;
      load(true);
    }catch(e){ alert(e.message || "Error al revisar resultados."); }
  }
  function adminPanelShown(){
    if(!adminInfoDone){ adminInfoDone = true; }
  }

  function cancel(){ hideBar(); renderEvents(); }

  return {open, close, load, choose, place, cancel, adminSave, adminRefresh, adminSettle, adminPanelShown};
})();


/* ---------------- Cash 3 ---------------- */
const C3 = (function(){
  const $ = n => document.getElementById(n);
  let data = null, timer = null, busy = false, adminData = null;

  const msg = (t, cls)=>{ const m=$("c3Msg"); if(!m) return; m.textContent=t; if(cls) m.className="notice "+cls; else m.className="notice"; };
  const int = (el, def)=>{ const v = parseInt(el && el.value, 10); return isNaN(v) ? (def||0) : v; };

  function listText(){
    const bets = (adminData && adminData.bets) || [];
    const sorted = [...bets].sort((a,b)=>(a.created||0)-(b.created||0));
    const groups = new Map();
    for(const b of sorted){
      const k = b.user_id || b.name || "?";
      if(!groups.has(k)) groups.set(k, []);
      groups.get(k).push(`${b.name}-${b.num}-${b.stake_three}-${b.stake_two}`);
    }
    return [...groups.values()].map(arr=>arr.join("\n")).join("\n");
  }
  async function copyList(){
    const t = listText();
    if(!t) return alert("No hay jugadas abiertas todavía.");
    try{ await navigator.clipboard.writeText(t); msg("Lista copiada ✅"); alert("Lista copiada ✅"); }
    catch(e){
      const ta = $("c3List");
      if(ta){ ta.removeAttribute("readonly"); ta.select(); try{ document.execCommand("copy"); }catch(_){} ta.setAttribute("readonly","readonly"); alert("Lista copiada ✅"); }
    }
  }
  function shareList(){
    const t = listText();
    if(!t) return alert("No hay jugadas abiertas todavía.");
    window.open("https://wa.me/?text=" + encodeURIComponent(t), "_blank");
  }

  function open(){
    $("c3Game").classList.remove("hidden");
    $("mainGames").classList.add("hidden");
    msg("⏳ Cargando…");
    load();
    if(timer) clearInterval(timer);
    timer = setInterval(()=>{ if($("c3Game") && !$("c3Game").classList.contains("hidden")) load(true); }, 5000);
    window.scrollTo(0,0);
  }
  function close(){
    $("c3Game").classList.add("hidden");
    $("mainGames").classList.remove("hidden");
    if(timer){ clearInterval(timer); timer = null; }
  }

  function clean(){
    const num = $("c3Num"); if(!num) return;
    num.value = num.value.replace(/[^0-9]/g, "").slice(0, 3);
    preview();
  }
  function preview(){
    const box = $("c3Preview"); if(!box) return;
    const m3 = (data && data.mult_three) || 400, m2 = (data && data.mult_two) || 70;
    const s3 = Math.max(int($("c3StakeThree"),0),0), s2 = Math.max(int($("c3StakeTwo"),0),0);
    const has = s3 > 0 || s2 > 0;
    if(!has){ box.textContent = ""; return; }
    box.innerHTML = `Si aciertas: ${s3>0?`a las 3 <b>${s3*m3}</b> 🪙`:""}${s3>0&&s2>0?" · ":""}${s2>0?`últimos 2 <b>${s2*m2}</b> 🪙`:""}`;
  }

  async function load(silent){
    if(busy || !current) return;
    busy = true;
    try{
      const r = await sbRpc("cash3_state", { p_token: token });
      data = r || {};
      if(typeof data.balance === "number"){ current.balance = data.balance; updateBalanceUI(); }
      render();
      if(!silent) msg("Escribe tu número, cuánto juegas a las 3 y/o a los últimos 2.");
    }catch(e){ if(!silent) msg("No se pudo cargar: " + msgDeError(e)); }
    finally{ busy = false; }
  }

  function render(){
    const bal = $("c3Balance");
    if(bal) bal.textContent = (data && typeof data.balance==="number") ? data.balance : (current ? current.balance : 0);
    const p3 = $("c3PayThree"), p2 = $("c3PayTwo");
    if(p3 && data && data.mult_three) p3.textContent = "paga " + data.mult_three + " por ficha" + ((data.max_three>0) ? " · tope " + data.max_three : " · sin tope");
    if(p2 && data && data.mult_two) p2.textContent = "paga " + data.mult_two + " por ficha" + ((data.max_two>0) ? " · tope " + data.max_two : " · sin tope");
    renderMine();
    renderHist();
    renderRecent();
    preview();
  }

  function betRow(b, withWinner){
    const st = b.status === "won" ? "won" : b.status === "lost" ? "lost" : "open";
    const label = st === "won" ? "GANÓ" : st === "lost" ? "PERDIÓ" : "EN JUEGO";
    const num = (b.num||"").padStart(3, "0");
    const st3 = b.stake_three||0, st2 = b.stake_two||0, total = st3 + st2;
    const code = `${num}-${st3}-${st2}`;
    const right = st === "won" ? `+${b.payout} 🪙` : st === "lost" ? `−${total} 🪙` : `${total} 🪙 apostados`;
    const win = withWinner && b.winner ? `<span class="muted"> · salió ${escapeHtml(b.winner)}</span>` : "";
    return `<div class="c3-mrow"><div><b>${escapeHtml(code)}</b><span class="c3-badge ${st}">${label}</span>${win}</div><div style="white-space:nowrap;color:${st==='won'?'#7dffb0':st==='lost'?'#ff9aa8':'#cdd6ea'}">${right}</div></div>`;
  }

  function renderMine(){
    const box = $("c3Mine"); if(!box) return;
    const mine = (data && data.mine) || [];
    box.innerHTML = mine.length ? mine.map(b=>betRow(b,false)).join("")
      : '<div class="muted" style="padding:8px">Aún no has apostado en esta ronda. El administrador está por publicar el resultado.</div>';
  }
  function renderRecent(){
    const box = $("c3Recent"); if(!box) return;
    const rec = (data && data.recent) || [];
    box.innerHTML = rec.length ? rec.map(b=>betRow(b,true)).join("")
      : '<div class="muted" style="padding:8px">Sin jugadas todavía.</div>';
  }
  function renderHist(){
    const box = $("c3Hist"); if(!box) return;
    const hist = (data && data.history) || [];
    box.innerHTML = hist.length ? hist.map(h=>`<div class="c3-ball">${escapeHtml(h.winner)}</div>`).join("")
      : '<div class="muted" style="padding:8px">Todavía no hay resultados. El primero lo publica el administrador.</div>';
  }

  async function place(){
    if(!current) return;
    const num = ($("c3Num") && $("c3Num").value || "").trim();
    const s3 = Math.max(int($("c3StakeThree"),0),0), s2 = Math.max(int($("c3StakeTwo"),0),0);
    if(!num) return msg("Escribe tu número.");
    if(s3 <= 0 && s2 <= 0) return msg("Escribe cuántas fichas a las 3 y/o a los últimos 2.");
    msg("⏳ Enviando jugada…");
    try{
      const r = await sbRpc("cash3_place", { p_token: token, p_num: num, p_stake_three: s3, p_stake_two: s2, p_now: Date.now() });
      if(r && typeof r.balance === "number"){ current.balance = r.balance; updateBalanceUI(); }
      const num2 = $("c3Num"); if(num2) num2.value = "";
      const s3i = $("c3StakeThree"), s2i = $("c3StakeTwo");
      if(s3i) s3i.value = ""; if(s2i) s2i.value = "";
      msg(`✅ Jugada al ${escapeHtml((r&&r.num)||num)} enviada (${(r&&r.stake_three)||0} a las 3, ${(r&&r.stake_two)||0} a los últimos 2).`, "win");
      load(true);
    }catch(e){ msg("No se pudo apostar: " + msgDeError(e), "danger"); }
  }

  async function adminInfo(silent){
    if(!current || !current.admin) return;
    const info = $("c3AdminInfo"), list = $("c3AdminBets");
    if(!silent && info) info.textContent = "Cargando…";
    try{
      const r = await sbRpc("cash3_admin_info", { p_token: token }) || {};
      adminData = r;
      const by = r.by_num || [];
      const m3 = $("c3MaxThree"), m2 = $("c3MaxTwo");
      if(m3 && r.max_three != null && m3.value === "") m3.value = r.max_three;
      if(m2 && r.max_two != null && m2.value === "") m2.value = r.max_two;
      if(info) info.innerHTML = `Ronda abierta · <b>${r.open_stake||0}</b> fichas apostadas · <b>${(r.bets||[]).length}</b> jugadas · Topes: a las 3 <b>${r.max_three||0}</b> · últ. 2 <b>${r.max_two||0}</b>`;
      const ta = $("c3List");
      if(ta) ta.value = listText();
      if(list){
        list.innerHTML = by.length ? by.map(b=>{
          const rem = [];
          if(b.rem_three != null) rem.push(`<span style="color:${b.rem_three>0?'#7dffb0':'#ff9aa8'}">3: ${b.rem_three} disp.</span>`);
          if(b.rem_two != null) rem.push(`<span style="color:${b.rem_two>0?'#7dffb0':'#ff9aa8'}">2: ${b.rem_two} disp.</span>`);
          return `<div class="adm-urow" style="cursor:default"><span class="adm-unum">${escapeHtml(b.num)}</span><span class="adm-uname">${b.count} jug. · a las 3: ${b.stake_three} · últ. 2: ${b.stake_two}${rem.length?' · '+rem.join(' · '):''}</span><span class="adm-ubal">${b.stake} 🪙</span></div>`;
        }).join("")
          : '<div class="muted" style="padding:8px">Sin apuestas abiertas todavía.</div>';
      }
    }catch(e){ if(info) info.textContent = "Error: " + msgDeError(e); }
  }

  async function adminSettle(){
    if(!current || !current.admin) return;
    const w = ($("c3Winner") && $("c3Winner").value || "").replace(/[^0-9]/g,"");
    if(!w) return alert("Escribe el número ganador (3 dígitos).");
    if(!confirm("¿Publicar el número ganador " + w.padStart(3,"0") + " y pagar las apuestas abiertas?")) return;
    const info = $("c3AdminInfo"); if(info) info.textContent = "Publicando resultado…";
    try{
      const r = await sbRpc("cash3_admin_settle", { p_token: token, p_winner: w, p_now: Date.now() });
      if($("c3Winner")) $("c3Winner").value = "";
      if(info) info.innerHTML = `✅ Resultado <b>${escapeHtml(r.winner)}</b> · ${r.won} ganadoras / ${r.lost} perdidas · pagado <b>${r.total_paid}</b> 🪙 (casa ${r.net})`;
      load(true);
      adminInfo();
    }catch(e){ if(info) info.textContent = "Error: " + msgDeError(e); }
  }

  async function adminSaveMax(){
    if(!current || !current.admin) return;
    const v3 = Math.max(int($("c3MaxThree"),0), 0), v2 = Math.max(int($("c3MaxTwo"),0), 0);
    const info = $("c3AdminInfo");
    try{
      const r = await sbRpc("cash3_admin_config", { p_token: token, p_max_three: v3, p_max_two: v2 });
      const got = r || {};
      if(info) info.innerHTML = `Topes guardados: a las 3 = <b>${got.max_three != null ? got.max_three : v3}</b> · últimos 2 = <b>${got.max_two != null ? got.max_two : v2}</b>`;
      load(true);
      adminInfo(true);
    }catch(e){ if(info) info.textContent = "Error: " + msgDeError(e); }
  }

  return {open, close, load, clean, preview, place, adminInfo, adminSettle, adminSaveMax, copyList, shareList};
})();


/* ---------------- pestañas de acceso ---------------- */
loginTab.onclick = ()=>{ loginBox.classList.remove("hidden"); regBox.classList.add("hidden"); loginTab.className="primary"; regTab.className="ghost"; };
regTab.onclick = ()=>{ regBox.classList.remove("hidden"); loginBox.classList.add("hidden"); regTab.className="primary"; loginTab.className="ghost"; };

/* ---------------- cara o cruz ---------------- */
const CF = (()=>{
  const $ = (id)=>document.getElementById(id);
  let selected = "cara", timer = null, data = null;

  function msg(html){ const m = $("cfResult"); if(m) m.innerHTML = html; }

  function spin(cb, onDone){
    let n = 0;
    const faces = ["🪙","🌙"];
    const flip = ()=>{ const e = $("cfResult"); if(!e) return; e.innerHTML = '<b style="font-size:26px">'+faces[n%2]+'</b>' + (n<2 ? " · lanzando…" : ""); if(n++ >= 8){ if(onDone) onDone(); } else setTimeout(flip, 90); };
    flip();
  }

  function rowHtml(b, withName){
    const badge = b.won ? `<span class="cf-badge won">GANASTE +${b.payout}</span>` : `<span class="cf-badge lost">PERDISTE</span>`;
    const who = withName ? " · " + escapeHtml(b.uname||"") : "";
    return `<div class="cf-mrow"><div class="cf-mmain">${b.choice==="cara"?"🪙 Cara":"🌙 Cruz"} → cayó <b>${b.result==="cara"?"🪙 Cara":"🌙 Cruz"}</b><span class="muted" style="font-size:12px">${who} · apostó ${b.stake} 🪙</span></div><div style="text-align:right;white-space:nowrap">${badge}</div></div>`;
  }

  function render(){
    if(data && data.mult != null){
      const pt = $("cfPayTxt");
      if(pt) pt.textContent = "paga " + (data.mult) + "x si aciertas · máximo " + data.max_bet + " fichas por apuesta";
    }
    const cb = $("cfBalance");
    if(cb && current) cb.textContent = current.balance;
    const c1 = $("cfCara"), c2 = $("cfCruz");
    if(c1) c1.classList.toggle("on", selected === "cara");
    if(c2) c2.classList.toggle("on", selected === "cruz");
    const mine = $("cfMine"), rec = $("cfRecent");
    if(mine) mine.innerHTML = (data && data.mine || []).map(b=>rowHtml(b,false)).join("") || '<div class="muted">Aún no has lanzado.</div>';
    if(rec) rec.innerHTML = (data && data.recent || []).map(b=>rowHtml(b,true)).join("") || '<div class="muted">Sin lanzamientos todavía.</div>';
  }

  function pick(c){ selected = c; render(); }

  async function load(silent){
    if(!current || !token) return;
    try{
      data = await sbRpc("coinflip_state", { p_token: token });
      render();
    }catch(e){ if(!silent) msg("Error: " + msgDeError(e)); }
  }

  async function flip(){
    if(!current || !token) return;
    const stake = Math.floor(Number($("cfStake") && $("cfStake").value));
    if(!Number.isFinite(stake) || stake <= 0) return msg("Escribe cuántas fichas quieres apostar.");
    if(stake > current.balance) return msg("No tienes suficientes fichas (tienes " + current.balance + ").");
    const btn = $("cfBetBtn");
    if(btn){ btn.disabled = true; }
    try{
      const r = await sbRpc("coinflip_flip", { p_token: token, p_choice: selected, p_stake: stake, p_now: Date.now() });
      if(r && r.balance != null){
        current.balance = r.balance;
        updateBalanceUI();
        data = await sbRpc("coinflip_state", { p_token: token });
        render();
      }
      spin(null, ()=>{
        const e = $("cfResult"); if(!e) return;
        e.innerHTML = (r.won ? '<b class="ok">🎉 ¡GANASTE!</b>' : '<b class="bad">Perdiste…</b>')
          + ' · Cayó <b>' + (r.result==="cara"?"🪙 Cara":"🌙 Cruz") + '</b>'
          + ' · apostaste ' + r.stake + ' 🪙'
          + (r.won ? ' · <b class="ok">+'+r.payout+' 🪙</b>' : ' · esta vez no hubo suerte');
        if(r.won){ try{ triggerWinRain(); }catch(err){} }
      });
      if($("cfStake")) $("cfStake").value = "";
    }catch(err){ msg("Error: " + msgDeError(err)); }
    finally{
      if(btn){ btn.disabled = false; }
    }
  }

  function open(){
    $("cfGame").classList.remove("hidden");
    document.getElementById("mainGames").classList.add("hidden");
    selected = "cara";
    load();
    if(timer) clearInterval(timer);
    timer = setInterval(()=>{ if($("cfGame") && !$("cfGame").classList.contains("hidden")) load(true); }, 5000);
  }

  function close(){
    $("cfGame").classList.add("hidden");
    document.getElementById("mainGames").classList.remove("hidden");
    if(timer){ clearInterval(timer); timer = null; }
  }

  async function adminInfo(silent){
    if(!current || !current.admin) return;
    try{
      const r = await sbRpc("coinflip_admin_info", { p_token: token });
      const m3 = $("cfMult"), m2 = $("cfMaxBet");
      if(m3 && r.mult != null && m3.value === "") m3.value = r.mult;
      if(m2 && r.max_bet != null && m2.value === "") m2.value = r.max_bet;
      const box = $("cfAdminInfo");
      if(box){
        const profit = (r.bets||0) - (r.paid||0);
        const pct = (r.bets ? (profit/r.bets*100).toFixed(1) : "0.0");
        box.innerHTML = `Paga <b>${r.mult}x</b> · máximo <b>${r.max_bet}</b> fichas por apuesta · ${r.flips||0} lanzamientos · apostado ${r.bets||0} 🪙 · pagado ${r.paid||0} 🪙 · <b class="${profit>=0?"ok":"bad"}">ganancia de la casa ${profit} (${pct}%)</b>`;
      }
    }catch(e){ if(!silent){ const box = $("cfAdminInfo"); if(box) box.textContent = "Error: " + msgDeError(e); } }
  }

  async function adminSave(){
    if(!current || !current.admin) return;
    const mult = Number($("cfMult") && $("cfMult").value);
    const maxBet = Math.floor(Number($("cfMaxBet") && $("cfMaxBet").value));
    if(!Number.isFinite(mult) || mult <= 1) return alert("El múltiplo debe ser mayor que 1 (ej. 1.9).");
    if(!Number.isFinite(maxBet) || maxBet < 1) return alert("Escribe el máximo por apuesta (mayor que 0).");
    try{
      await sbRpc("coinflip_admin_config", { p_token: token, p_mult: mult, p_max_bet: maxBet });
      alert("Configuración de Cara o Cruz guardada.");
      adminInfo();
    }catch(e){ alert("Error: " + msgDeError(e)); }
  }

  return { open, close, load, pick, flip, adminInfo, adminSave };
})();

/* ---------------- lluvia de fichas ---------------- */
function startPortalRain(){
  const box = document.getElementById("chipRain");
  if(!box) return;
  box.style.display = "block";
  box.innerHTML = "";
  for(let i=0;i<20;i++){
    const c = document.createElement("div");
    c.className = "chip"; c.textContent = "🪙";
    c.style.left = Math.random()*100+"vw";
    c.style.animationDuration = (4+Math.random()*4)+"s";
    box.appendChild(c);
  }
}
function stopPortalRain(){
  const box = document.getElementById("chipRain");
  if(box){ box.style.display="none"; box.innerHTML=""; }
}
function triggerWinRain(){
  const box = document.getElementById("chipRain");
  if(!box) return;
  box.style.display = "block";
  box.innerHTML = "";
  for(let i=0;i<80;i++){
    const c = document.createElement("div");
    c.className = "chip"; c.textContent = "🪙";
    c.style.left = Math.random()*100+"vw";
    c.style.animationDuration = (2+Math.random()*2)+"s";
    box.appendChild(c);
  }
  setTimeout(()=>{ if(current) startPortalRain(); else stopPortalRain(); }, 5000);
}

/* ---------------- reloj: hora de Cuba ---------------- */
function startCubaClock(){
  const box = document.getElementById("cubaClock");
  if(!box) return;
  const timeEl = box.querySelector(".clockTime");
  const dateEl = box.querySelector(".clockDate");
  const timeFmt = new Intl.DateTimeFormat("en-US", { timeZone:"America/Havana", hour:"numeric", minute:"2-digit", second:"2-digit", hour12:true });
  let dateFmt;
  try{ dateFmt = new Intl.DateTimeFormat("es-CU", { timeZone:"America/Havana", weekday:"short", day:"2-digit", month:"short" }); }
  catch(e){ dateFmt = new Intl.DateTimeFormat("es", { timeZone:"America/Havana", weekday:"short", day:"2-digit", month:"short" }); }
  const tick = ()=>{
    const now = new Date();
    if(timeEl) timeEl.textContent = timeFmt.format(now).toLowerCase().replace(/\s?(am|pm)/, " $1");
    if(dateEl) dateEl.textContent = dateFmt.format(now).replace(/\./g, "");
  };
  tick();
  setInterval(tick, 1000);
}

/* ---------------- arranque ---------------- */
startCubaClock();
R1.subscribe();
R2.subscribe();

(async function restoreSession(){
  const st = localStorage.getItem("casino_token");
  if(st){
    try{
      const u = await sbRpc("get_user", { p_token: st });
      if(u && u.id){ token = st; current = u; await enter(); }
      else localStorage.removeItem("casino_token");
    }catch(e){ console.warn("Sesión:", e.message); }
  }
  setTimeout(diagnosticoSupabase, 600);
})();