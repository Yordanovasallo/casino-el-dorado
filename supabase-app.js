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
let pendingReveal = null;
let userTimer = null;
let adminTimer = null;
let usersCache = [], ledgerCache = [], statsCache = null;

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
  const b=document.getElementById("balance"), t=document.getElementById("topBalance");
  if(b) b.textContent = shown;
  if(t) t.textContent = shown;
}

/* Actualiza el usuario actual cada 2 s (equivalente al tiempo real de antes) */
function startUserPoll(){
  stopUserPoll();
  userTimer = setInterval(async ()=>{
    if(!current) return;
    try{
      const u = await sbRpc("get_user", { p_id: current.id });
      if(u && u.id){ current = u; updateBalanceUI(); }
    }catch(e){}
  }, 2000);
}
function stopUserPoll(){ if(userTimer){ clearInterval(userTimer); userTimer = null; } }

/* ---------------- sesión ---------------- */
async function register(){
  const raw = document.getElementById("rName").value.trim();
  const p = document.getElementById("rPass").value;
  if(!raw || !p) return showMsg("Completa usuario y contraseña.");
  const docId = normName(raw);
  if(!docId || docId==="." || docId==="..") return showMsg("Nombre de usuario no válido.");
  if(docId.length>24) return showMsg("El usuario debe tener máximo 24 caracteres.");
  const isAdmin = docId==="admin";
  try{
    await sbRpc("register_user", {
      p_id: docId,
      p_name: isAdmin ? "admin" : raw,
      p_pass: await hashPass(p),
      p_balance: isAdmin ? 0 : SALDO_INICIAL,
      p_admin: isAdmin,
      p_created: Date.now()
    });
  }catch(e){ return showMsg(msgDeError(e)); }
  localStorage.setItem("casino_uid", docId);
  current = { id:docId, name:isAdmin?"admin":raw, balance:isAdmin?0:SALDO_INICIAL, avatar:"", admin:isAdmin };
  await enter();
  showMsg("Cuenta creada correctamente.");
}

async function login(){
  const docId = normName(liUser.value);
  const p = liPass.value;
  if(!docId || docId==="." || docId==="..") return showMsg("Usuario o contraseña incorrectos.");
  try{
    const u = await sbRpc("login", { p_id: docId, p_pass: await hashPass(p) });
    if(!u || !u.id) return showMsg("Usuario o contraseña incorrectos.");
    current = u;
    localStorage.setItem("casino_uid", docId);
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
  document.getElementById("uid").textContent = current.id;
  document.getElementById("avatar").src = current.avatar || defaultAvatar();
  if(isAdmin){
    document.getElementById("admin").classList.remove("hidden");
    startAdminWatch();
  }else{
    document.getElementById("admin").classList.add("hidden");
    stopAdminWatch();
  }
  updateBalanceUI();
  startUserPoll();
  R1.refresh(); R2.refresh();
}

function logout(){
  stopPortalRain();
  stopUserPoll();
  stopAdminWatch();
  localStorage.removeItem("casino_uid");
  current = null; pendingReveal = null;
  document.getElementById("app").classList.add("hidden");
  document.getElementById("auth").classList.remove("hidden");
  liPass.value = "";
  showMsg("Sesión cerrada.");
}

function toggleProfile(){ document.getElementById("profileMenu").classList.toggle("hidden"); }

async function changePassword(){
  const p = prompt("Nueva contraseña:");
  if(!p) return;
  try{
    await sbRpc("change_password", { p_id: current.id, p_pass: await hashPass(p) });
    alert("Contraseña cambiada.");
  }catch(e){ alert("Error: "+e.message); }
}

async function sendFichas(){
  const target = prompt("ID del usuario destinatario (ej: carlos):");
  if(target===null) return;
  const amount = Number(prompt("Cantidad de fichas:"));
  const toId = normName(target);
  if(!toId || !Number.isFinite(amount) || amount<=0) return alert("Datos no válidos.");
  if(toId===current.id) return alert("No puedes enviarte fichas a ti mismo.");
  try{
    await sbRpc("send_fichas", { p_from: current.id, p_to: toId, p_amount: amount, p_now: Date.now() });
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
        await sbRpc("set_avatar", { p_id: current.id, p_avatar: dataUrl });
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

async function refreshAdmin(){
  if(!current || !current.admin) return;
  try{
    const [ou, ol, os] = await Promise.all([
      sbRead("v_users?select=id,name,balance,admin"),
      sbRead("ledger?select=*&order=ts.desc&limit=150"),
      sbRead("scratch_stats?select=*&limit=1")
    ]);
    usersCache = Array.isArray(ou) ? ou : [];
    ledgerCache = Array.isArray(ol) ? ol : [];
    statsCache = (Array.isArray(os) && os[0]) || null;
    renderAdmin();
  }catch(e){}
}

function renderAdmin(){
  if(!current || !current.admin) return;
  const pl = usersCache.filter(u=>!u.admin);
  document.getElementById("adminUsers").textContent = pl.length;
  document.getElementById("adminBalance").textContent = pl.reduce((s,u)=>s+(u.balance||0),0);
  const sel = document.getElementById("adminTarget");
  const keep = sel && sel.value;
  sel.innerHTML = pl.map(u=>`<option value="${escapeHtml(u.id)}">${escapeHtml(u.name)} — ${escapeHtml(u.id)} — ${u.balance} fichas</option>`).join("");
  if(keep && [...sel.options].some(o=>o.value===keep)) sel.value = keep;
  renderScratchStats();
  document.getElementById("ledger").innerHTML = ledgerDataHtml();
}

function renderScratchStats(){
  const e = document.getElementById("scratchStats"); if(!e) return;
  const s = statsCache || {cards:0,bets:0,paid:0};
  const profit = s.bets - s.paid, pct = s.bets ? (profit/s.bets*100).toFixed(1) : "0.0";
  e.innerHTML = `🎟️ Raspa y Gana: ${s.cards} cartones · apostado ${s.bets} · pagado ${s.paid} · ganancia de la casa <b class="${profit>=0?"ok":"bad"}">${profit} (${pct}%)</b> · fondo de premios disponible: ${Math.max(0,Math.floor(s.bets*.9)-s.paid)} · mínimo garantizado 10%`;
}

async function adminAdjust(sign){
  const toId = adminTarget.value;
  const a = Math.floor(Number(adminAmount.value));
  if(!toId) return alert("No hay usuarios para ajustar. Crea una cuenta primero.");
  if(!Number.isFinite(a) || a<=0) return alert("Escribe una cantidad válida en fichas (número entero mayor que 0).");
  try{
    await sbRpc("admin_adjust", { p_to: toId, p_amount: a, p_sign: sign, p_now: Date.now() });
    adminAmount.value = "";
    refreshAdmin();
    alert((sign>0?"Se sumaron ":"Se quitaron ")+a+" fichas.");
  }catch(e){ alert(e.message||"Error al ajustar fichas."); }
}

function ledgerDataHtml(){
  return ledgerCache.map(x=>`<tr><td>${escapeHtml(x.date)}</td><td>${escapeHtml(x.uname)}</td><td>${escapeHtml(x.type)}</td><td class="${x.amount>=0?"ok":"bad"}">${x.amount>0?"+":""}${x.amount}</td><td>${escapeHtml(x.detail)}</td></tr>`).join("")
    || `<tr><td colspan="5" class="muted">Sin movimientos.</td></tr>`;
}

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
    return sbRpc("join_round", { p_round: cfg.doc, p_user_id: current.id, p_cost: cfg.cost, p_label: cfg.label, p_now: Date.now() })
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
      res = await sbRpc("scratch_buy", { p_user_id: current.id, p_price: SCRATCH_COST, p_now: Date.now() });
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

/* ---------------- pestañas de acceso ---------------- */
loginTab.onclick = ()=>{ loginBox.classList.remove("hidden"); regBox.classList.add("hidden"); loginTab.className="primary"; regTab.className="ghost"; };
regTab.onclick = ()=>{ regBox.classList.remove("hidden"); loginBox.classList.add("hidden"); regTab.className="primary"; loginTab.className="ghost"; };

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

/* ---------------- arranque ---------------- */
R1.subscribe();
R2.subscribe();

(async function restoreSession(){
  const sid = localStorage.getItem("casino_uid");
  if(sid){
    try{
      const u = await sbRpc("get_user", { p_id: sid });
      if(u && u.id){ current = u; await enter(); }
    }catch(e){ console.warn("Sesión:", e.message); }
  }
  setTimeout(diagnosticoSupabase, 600);
})();