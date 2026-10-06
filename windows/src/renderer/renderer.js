"use strict";

const paneWebviews = document.getElementById("pane-webviews");
const railProviders = document.getElementById("rail-providers");

let providers = [];        // ordered list of provider objects
let current = "__universal__";
const webviews = {};       // id -> <webview>
const unread = {};         // id -> count
let recents = [];
let notifications = [];
let allKnown = [];         // every provider (built-in + custom), unfiltered
let hidden = new Set();    // provider ids hidden from the rail
let memory = [];           // user's reusable notes

// -------------------------------------------------------------- auth + sync
// Google sign-in gates the app; synced UAI data lives in one JSON blob in
// Firestore (users/{uid}.data), the same shape the Mac and web apps use.
let currentUser = null;
let applyingRemote = false;
let pushTimer = null;
// blob key -> local state key
const SYNC_MAP = {
  custom: "customProviders",
  memory: "memory",
  recents: "universalRecents",
  profile: "profile",
  railOrder: "railOrder",
  hidden: "hiddenProviders",
};
const SYNC_STATE_KEYS = Object.values(SYNC_MAP);

// Push synced state up whenever setState or a custom-AI change touches it.
if (window.api) {
  const _setState = window.api.setState;
  window.api.setState = async (patch) => {
    const r = await _setState(patch);
    if (patch && Object.keys(patch).some((k) => SYNC_STATE_KEYS.includes(k))) scheduleSyncPush();
    return r;
  };
  const _add = window.api.addCustomAI;
  window.api.addCustomAI = async (c) => { const r = await _add(c); scheduleSyncPush(); return r; };
  const _remove = window.api.removeCustomAI;
  window.api.removeCustomAI = async (id) => { const r = await _remove(id); scheduleSyncPush(); return r; };
}

function showGate(show) { document.getElementById("auth-gate").classList.toggle("hidden", !show); }

function ensureSignedIn() {
  return new Promise(async (resolve) => {
    showGate(false);
    let user = null;
    try { user = await window.api.authRestore(); } catch (e) {}
    if (user) { currentUser = user; resolve(user); return; }
    showGate(true);
    const btn = document.getElementById("google-signin");
    const err = document.getElementById("auth-err");
    btn.onclick = async () => {
      btn.disabled = true; err.textContent = ""; btn.textContent = "Opening browser…";
      let r = null;
      try { r = await window.api.authSignIn(); } catch (e) { r = { ok: false, error: String(e && e.message || e) }; }
      btn.disabled = false; btn.textContent = "Sign in with Google";
      if (r && r.ok && r.user) { currentUser = r.user; showGate(false); resolve(r.user); }
      else { err.textContent = (r && r.error) || "Sign-in failed. Please try again."; }
    };
  });
}

// Merge recent entries from multiple devices: dedupe, newest-first, bounded.
function mergeRecents(list) {
  const seen = new Set(); const out = [];
  for (const r of list) {
    if (!r || typeof r !== "object") continue;
    const key = (r.providerId || "") + "|" + (r.at || 0) + "|" + String(r.text || "").slice(0, 60);
    if (seen.has(key)) continue;
    seen.add(key); out.push(r);
  }
  out.sort((a, b) => (b.at || 0) - (a.at || 0));
  return out.slice(0, 80);
}

async function syncPullIntoState() {
  let blob = {};
  try { blob = (await window.api.syncPull()) || {}; } catch (e) {}
  const patch = {};
  let localRecents = [];
  try { localRecents = (await window.api.getState()).universalRecents || []; } catch (e) {}
  for (const bk in SYNC_MAP) {
    const v = blob[bk];
    if (bk === "profile") { if (v && typeof v === "object") patch.profile = v; }
    else if (bk === "recents") { if (Array.isArray(v)) patch.universalRecents = mergeRecents(v.concat(localRecents)); }
    else if (Array.isArray(v)) patch[SYNC_MAP[bk]] = v;
  }
  // First sign-in with nothing stored yet: seed the profile from the Google account.
  if (!patch.profile) {
    try {
      const cur = (await window.api.getState()).profile || {};
      if (!cur.name && currentUser && currentUser.name) patch.profile = { name: currentUser.name, avatar: currentUser.photo || cur.avatar || "" };
    } catch (e) {}
  }
  if (Object.keys(patch).length) {
    applyingRemote = true;
    try { await window.api.setState(patch); } finally { applyingRemote = false; }
  }
}

function scheduleSyncPush() {
  if (applyingRemote || !currentUser) return;
  clearTimeout(pushTimer);
  pushTimer = setTimeout(doSyncPush, 800);
}
async function doSyncPush() {
  if (!currentUser) return;
  let state = {};
  try { state = await window.api.getState(); } catch (e) { return; }
  const blob = {};
  for (const bk in SYNC_MAP) {
    const v = state[SYNC_MAP[bk]];
    if (bk === "profile") { if (v && typeof v === "object") blob.profile = v; }
    else if (Array.isArray(v)) blob[bk] = v;
  }
  // Merge recents with the current remote so we never drop entries another
  // device added (e.g. "Send to UAI" from the web) while this app was open.
  try {
    const remote = await window.api.syncPull();
    if (remote && Array.isArray(remote.recents)) {
      blob.recents = mergeRecents((blob.recents || []).concat(remote.recents));
    }
  } catch (e) {}
  try { await window.api.syncPush(blob); } catch (e) {}
}

function renderAccount() {
  const chip = document.getElementById("acct-chip");
  if (!chip) return;
  if (!currentUser) { chip.style.display = "none"; return; }
  chip.style.display = "";
  const img = document.getElementById("acct-photo");
  if (currentUser.photo) { img.src = currentUser.photo; img.style.display = ""; } else { img.style.display = "none"; }
  document.getElementById("acct-name").textContent = currentUser.name || currentUser.email || "Account";
}
const _acctBtn = document.getElementById("acct-signout");
if (_acctBtn) _acctBtn.onclick = async () => { try { await window.api.authSignOut(); } catch (e) {} location.reload(); };

// -------------------------------------------------------------- startup
drawGalaxies();   // render the spiral galaxy SVG into the rail icon + hero
async function boot() {
  await ensureSignedIn();      // blocks on the sign-in gate until Google sign-in succeeds
  renderAccount();
  await syncPullIntoState();   // bring this account's cloud data down before first render
  const state = await window.api.getState();
  recents = state.universalRecents || [];
  notifications = state.notifications || [];
  allRecents = state.allRecents || [];
  memory = state.memory || [];
  profile = state.profile || {};
  if (state.rbHidden) document.getElementById("app").classList.add("rb-hidden");
  await loadProviders(state);
  buildRail();
  renderRecents();
  renderProfile();
  renderRightBar();
  select("__universal__");
  refreshApiKeyStatus();
  buildSettingsProviders();
  renderMediaTabs();

  window.api.onMediaChanged(() => { if (current === "__media__") loadMedia(); });
  window.api.onOpenProvider((id) => { if (id) select(id); });

  // Poll the cloud so Recent (and other synced data) from other devices shows
  // up without a restart.
  setInterval(async () => {
    if (!currentUser) return;
    try {
      await syncPullIntoState();
      const st = await window.api.getState();
      recents = st.universalRecents || [];
      renderRecents();
    } catch (e) {}
  }, 20000);
}

async function loadProviders(state) {
  const all = await window.api.providers();
  allKnown = all;                                   // full list incl. hidden
  hidden = new Set(state.hiddenProviders || []);
  const order = state.railOrder || [];
  const byId = Object.fromEntries(all.map((p) => [p.id, p]));
  const ordered = [];
  for (const id of order) if (byId[id]) { ordered.push(byId[id]); delete byId[id]; }
  for (const p of all) if (byId[p.id]) ordered.push(byId[p.id]);
  providers = ordered.filter((p) => !hidden.has(p.id));   // rail shows non-hidden
}

function faviconFor(p) {
  try { return `https://www.google.com/s2/favicons?sz=128&domain=${new URL(p.home).host}`; }
  catch (e) { return ""; }
}

// -------------------------------------------------------------- rail
function buildRail() {
  railProviders.innerHTML = "";
  for (const p of providers) railProviders.appendChild(railItem(p));
  updateBadges();
}

function railItem(p) {
  const el = document.createElement("button");
  el.className = "rail-item";
  el.dataset.id = p.id;
  el.title = p.name;
  el.draggable = true;
  el.innerHTML = `
    <span class="icon" style="--ring:${p.tint}"><img src="${faviconFor(p)}" alt="" onerror="this.style.display='none'"/></span>
    <span class="label">${escapeHtml(p.name)}</span>
    <span class="badge" style="display:none"></span>`;
  el.addEventListener("click", () => select(p.id));
  wireDrag(el);
  return el;
}

function wireDrag(el) {
  el.addEventListener("dragstart", (e) => { el.classList.add("dragging"); e.dataTransfer.setData("text/plain", el.dataset.id); });
  el.addEventListener("dragend", () => el.classList.remove("dragging"));
  el.addEventListener("dragover", (e) => {
    e.preventDefault();
    const dragging = railProviders.querySelector(".dragging");
    if (!dragging || dragging === el) return;
    const rect = el.getBoundingClientRect();
    const after = e.clientY > rect.top + rect.height / 2;
    railProviders.insertBefore(dragging, after ? el.nextSibling : el);
  });
  el.addEventListener("drop", (e) => { e.preventDefault(); persistOrder(); });
}

function persistOrder() {
  const order = [...railProviders.children].map((c) => c.dataset.id);
  window.api.setState({ railOrder: order });
}

// -------------------------------------------------------------- selection
function select(id) {
  current = id;
  // rail active state
  document.querySelectorAll(".rail-item").forEach((el) => el.classList.toggle("active", el.dataset.id === id));
  document.getElementById("rail-universal").classList.toggle("active", id === "__universal__");

  // panes
  showPane(id);
  document.getElementById("btn-media").classList.toggle("active", id === "__media__");
  document.getElementById("btn-memory").classList.toggle("active", id === "__memory__");
  document.getElementById("btn-settings").classList.toggle("active", id === "__settings__");

  if (isProvider(id)) {
    const wv = ensureWebview(id);
    unread[id] = 0; updateBadges();
    if (wv) setTimeout(() => { try { wv.focus(); } catch (e) {} }, 60);
  } else if (id === "__universal__") {
    setTimeout(() => { const t = document.getElementById("universal-input"); if (t) t.focus(); }, 60);
  }
  updateNavButtons();
}

function isProvider(id) { return providers.some((p) => p.id === id); }

function showPane(id) {
  ["pane-universal", "pane-media", "pane-memory", "pane-settings", "pane-search", "pane-webviews"].forEach((pid) =>
    document.getElementById(pid).classList.remove("show"));
  Object.values(webviews).forEach((wv) => wv.classList.remove("show"));

  if (id === "__universal__") document.getElementById("pane-universal").classList.add("show");
  else if (id === "__media__") { document.getElementById("pane-media").classList.add("show"); loadMedia(); }
  else if (id === "__memory__") { document.getElementById("pane-memory").classList.add("show"); renderMemory(); }
  else if (id === "__settings__") document.getElementById("pane-settings").classList.add("show");
  else if (id === "__search__") document.getElementById("pane-search").classList.add("show");
  else {
    document.getElementById("pane-webviews").classList.add("show");
    if (webviews[id]) webviews[id].classList.add("show");
  }
}

// -------------------------------------------------------------- webviews
function ensureWebview(id, initialURL) {
  if (webviews[id]) return webviews[id];
  const p = (providers.find((x) => x.id === id)) || (allKnown.find((x) => x.id === id));
  if (!p) return null;
  const wv = document.createElement("webview");
  // One shared, persistent session for all AIs, so a single Google (or other)
  // sign-in is recognized across every AI instead of logging in each one.
  wv.setAttribute("partition", "persist:uai");
  wv.setAttribute("preload", window.api.webviewPreload);
  wv.setAttribute("allowpopups", "");
  // Keep JS timers running while this AI is in the background (hidden with
  // display:none). Otherwise Chromium throttles/suspends the page and the
  // reply-finished detector never fires — so no badge/notification when you've
  // navigated to another AI, which is exactly when it's needed.
  wv.setAttribute("webpreferences", "backgroundThrottling=false");
  wv.setAttribute("src", initialURL || p.home);
  wv.dataset.id = id;
  paneWebviews.appendChild(wv);
  webviews[id] = wv;

  wv.addEventListener("ipc-message", (e) => onWebviewMessage(id, e));
  wv.addEventListener("page-title-updated", () => { /* could index here later */ });
  // Links an AI opens in a new tab/window → default browser (unless it's the
  // AI's own site or a sign-in page). Handled here on the webview element so
  // it works regardless of the main-process path.
  wv.addEventListener("new-window", (e) => {
    try { if (e.url && isExternalURL(e.url)) { e.preventDefault(); window.api.openExternal(e.url); } } catch (x) {}
  });
  if (current === id) wv.classList.add("show");
  return wv;
}

// Hosts that stay in-app: any AI's own site, plus common sign-in providers.
const IDENTITY_HOSTS = ["google.com", "accounts.google.com", "apple.com", "icloud.com",
  "microsoft.com", "microsoftonline.com", "live.com", "facebook.com", "meta.com", "x.com",
  "twitter.com", "github.com", "okta.com", "auth0.com", "clerk.com", "clerk.dev", "stytch.com",
  "workos.com", "openai.com", "anthropic.com", "x.ai", "duosecurity.com"];
function hostIn(host, list) { host = (host || "").toLowerCase(); return list.some((h) => host === h || host.endsWith("." + h)); }
function isExternalURL(url) {
  try {
    const u = new URL(url);
    if (!/^https?:$/.test(u.protocol)) return true;   // mailto:/app links → out
    const providerHosts = [];
    for (const pr of allKnown) providerHosts.push(...(pr.hosts || []));
    return !hostIn(u.host, providerHosts.concat(IDENTITY_HOSTS));
  } catch (e) { return false; }
}

function onWebviewMessage(id, e) {
  const p = providers.find((x) => x.id === id);
  if (e.channel === "reply") {
    const d = e.args[0] || {};
    // "Viewing" = this AI's pane is the active one. Don't also require the OS
    // window to be focused: when the cursor is inside the AI's web view the
    // host window reports unfocused, which wrongly kept bumping its badge.
    const viewing = current === id;
    addNotification(id, (p ? p.name : "AI"), d.preview || "Your answer is ready.");
    if (viewing) {
      unread[id] = 0; updateBadges();   // you're on it — keep it clear
    } else {
      unread[id] = (unread[id] || 0) + 1; updateBadges();
      window.api.notify({ title: `${p ? p.name : "AI"} replied`, body: d.preview || "Your answer is ready.", providerId: id });
      playChime();
    }
  } else if (e.channel === "media") {
    const d = e.args[0] || {};
    window.api.saveMedia({ dataURL: d.dataURL, name: d.name, role: d.role, providerName: p ? p.name : "Other" });
  } else if (e.channel === "prompt") {
    const d = e.args[0] || {};
    if (d && d.text) addGlobalRecent(id, p ? p.name : "AI", d.text);
  }
}

// Recent prompts from ALL AIs (and Universal), newest first.
let allRecents = [];
function addGlobalRecent(providerId, name, text) {
  text = String(text).replace(/\s+/g, " ").trim();
  if (!text) return;
  if (allRecents[0] && allRecents[0].text === text && allRecents[0].providerId === providerId) return; // dedupe repeats
  allRecents.unshift({ providerId, name, text, at: Date.now() });
  allRecents = allRecents.slice(0, 60);
  window.api.setState({ allRecents });
  renderRightBar();
}

// -------------------------------------------------------------- profile
let profile = {};
function setProfile(p) {
  // Keep the best info we've seen (don't overwrite a real name with blank).
  const merged = { name: p.name || profile.name || "", avatar: p.avatar || profile.avatar || "" };
  if (merged.name === profile.name && merged.avatar === profile.avatar) return;
  profile = merged;
  window.api.setState({ profile });
  renderProfile();
}
function renderProfile() {
  const el = document.getElementById("profile");
  if (!el) return;
  if (!profile.name && !profile.avatar) { el.innerHTML = ""; el.style.display = "none"; return; }
  el.style.display = "flex";
  el.innerHTML =
    (profile.avatar ? `<img src="${escapeAttr(profile.avatar)}" alt="" referrerpolicy="no-referrer"/>` : `<span class="pf-dot"></span>`) +
    `<span class="pf-name">${escapeHtml(profile.name || "Signed in")}</span>`;
}

// AIs that accept the prompt straight in the URL — the most reliable hand-off.
const PREFILL = {
  claude: (q) => `https://claude.ai/new?q=${encodeURIComponent(q)}`,
  chatgpt: (q) => `https://chatgpt.com/?q=${encodeURIComponent(q)}`,
  xai: (q) => `https://grok.com/?q=${encodeURIComponent(q)}`,
  vercel: (q) => `https://v0.app/?q=${encodeURIComponent(q)}`,
};

function deliver(id, text, files, forceInject) {
  files = files || [];
  // With files attached we must type into the composer and drop the files in,
  // so skip the URL-prefill path (a URL can't carry an upload). forceInject does
  // the same for long messages (e.g. the Claude working rules) that don't belong
  // in a URL.
  if (!forceInject && !files.length && PREFILL[id]) {
    const url = PREFILL[id](text);
    const existing = webviews[id];
    if (!existing) { ensureWebview(id, url); }
    else { try { existing.loadURL(url); } catch (e) { existing.setAttribute("src", url); } }
    return;
  }
  const wv = ensureWebview(id);
  if (!wv) return;
  try { navigator.clipboard.writeText(text); } catch (e) {}
  // Images go in by pasting from the real system clipboard (every major AI
  // accepts a pasted image). Other files use the composer's file <input>/drop.
  const images = files.filter((f) => (f.type || "").startsWith("image/"));
  const others = files.filter((f) => !(f.type || "").startsWith("image/"));
  const autoSend = files.length === 0;   // don't auto-send while anything is attached
  let n = 0, forwarded = false;
  const tryInject = () => {
    wv.executeJavaScript(deliverScript(text, others, n >= 24, autoSend)).then((ok) => {
      if (ok) {
        if (images.length && !forwarded) { forwarded = true; setTimeout(() => forwardImages(wv, images, 0), 500); }
      } else if (++n < 30) setTimeout(tryInject, 500);
    }).catch(() => { if (++n < 30) setTimeout(tryInject, 500); });
  };
  if (wv.isLoading && wv.isLoading()) wv.addEventListener("dom-ready", () => setTimeout(tryInject, 400), { once: true });
  else setTimeout(tryInject, 400);
}

// Paste attached images into the AI's composer, one at a time, via the real
// clipboard — the most reliable way to forward an image across AI web apps.
function forwardImages(wv, images, i) {
  if (!wv || i >= images.length) return;
  window.api.writeClipboardImage(images[i].dataURL).then((ok) => {
    const focusBox = `(() => { const v=el=>{const r=el.getBoundingClientRect();return r.width>80&&r.height>12&&el.offsetParent!==null;}; const b=[...document.querySelectorAll('textarea,[contenteditable="true"],div[role="textbox"]')].filter(v); if(!b.length) return false; b.sort((x,y)=>y.getBoundingClientRect().bottom-x.getBoundingClientRect().bottom); b[0].focus(); return true; })()`;
    wv.executeJavaScript(focusBox).then(() => {
      setTimeout(() => {
        try { wv.focus(); } catch (e) {}
        try { wv.paste(); } catch (e) {}
        setTimeout(() => forwardImages(wv, images, i + 1), 1000);  // let the upload register
      }, 250);
    }).catch(() => {});
  });
}

function deliverScript(text, files, allowDrop, autoSend) {
  files = files || [];
  return `(() => {
    const t = ${JSON.stringify(text)};
    const files = ${JSON.stringify(files)};
    const allowDrop = ${allowDrop ? "true" : "false"};
    const vis = el => { const r = el.getBoundingClientRect(); return r.width>80 && r.height>12 && el.offsetParent!==null && !el.disabled && !el.readOnly; };
    const boxes = [...document.querySelectorAll('textarea,[contenteditable="true"],div[role="textbox"]')].filter(vis);
    if (!boxes.length) return false;
    boxes.sort((a,b)=>b.getBoundingClientRect().bottom-a.getBoundingClientRect().bottom);
    const el = boxes[0]; el.focus();
    // Attach any files. Prefer the composer's real file <input> (ChatGPT, Claude,
    // Gemini and Grok all have one) — it's far more reliable than a synthetic
    // drop. Only simulate a drag-and-drop as a last resort (allowDrop), after
    // we've given the input a chance to render.
    let fileHandled = !files.length;
    if (files.length) {
      try {
        const toFile = (d, name, type) => { const a = d.split(','); const b = atob(a[1]); let n = b.length; const u = new Uint8Array(n); while(n--) u[n] = b.charCodeAt(n); return new File([u], name, { type }); };
        const dt = new DataTransfer();
        for (const f of files) dt.items.add(toFile(f.dataURL, f.name, f.type));
        for (const inp of document.querySelectorAll('input[type="file"]')) {
          try { inp.files = dt.files; inp.dispatchEvent(new Event('change', { bubbles: true })); fileHandled = true; break; } catch (e) {}
        }
        if (!fileHandled && allowDrop) {
          const r = el.getBoundingClientRect();
          const opt = { bubbles: true, cancelable: true, dataTransfer: dt, clientX: r.left + 20, clientY: r.top + 20 };
          el.dispatchEvent(new DragEvent('dragenter', opt));
          el.dispatchEvent(new DragEvent('dragover', opt));
          el.dispatchEvent(new DragEvent('drop', opt));
          fileHandled = true;
        }
      } catch (e) {}
    }
    if (t) {
      if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
        const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, t); el.dispatchEvent(new Event('input', { bubbles: true }));
      } else {
        el.textContent = t; el.dispatchEvent(new InputEvent('input', { bubbles: true }));
      }
    }
    if (${autoSend ? "true" : "false"}) setTimeout(() => {
      el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
      el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
    }, 500);
    // Not done until the files are in (so the caller keeps retrying while the
    // file input is still rendering); text-only is done once the box is found.
    return fileHandled;
  })()`;
}

// -------------------------------------------------------------- nav bar
function activeWebview() { return isProvider(current) ? webviews[current] : null; }
function updateNavButtons() {
  const wv = activeWebview();
  document.getElementById("back").disabled = !(wv && wv.canGoBack && wv.canGoBack());
  document.getElementById("forward").disabled = !(wv && wv.canGoForward && wv.canGoForward());
  document.getElementById("reload").disabled = !wv;
  // The "paste a login link" button only makes sense while viewing an AI.
  document.getElementById("reconnect").style.display = wv ? "inline-flex" : "none";
}
document.getElementById("back").onclick = () => { const w = activeWebview(); if (w && w.canGoBack()) w.goBack(); };
document.getElementById("forward").onclick = () => { const w = activeWebview(); if (w && w.canGoForward()) w.goForward(); };
document.getElementById("reload").onclick = () => { const w = activeWebview(); if (w) w.reload(); };

// -------------------------------------------------------------- badges
function updateBadges() {
  document.querySelectorAll("#rail-providers .rail-item").forEach((el) => {
    const n = unread[el.dataset.id] || 0;
    const b = el.querySelector(".badge");
    if (n > 0) { b.textContent = n > 9 ? "9+" : n; b.style.display = "flex"; }
    else b.style.display = "none";
  });
}

// Mount the animated spiral galaxy (from galaxy.js) into the rail icon and the
// Universal hero. UAIGalaxy.mount is a no-op if an element already has one.
function drawGalaxies() {
  UAIGalaxy.mountAll(".galaxy");
}

// Prepend your saved Memory notes as context, so Universal prompts carry them.
function withMemory(prompt) {
  if (!memory || !memory.length) return prompt;
  const ctx = memory.slice(0, 20).map((m) => "- " + m).join("\n");
  return `Context about me (please keep in mind):\n${ctx}\n\nRequest: ${prompt}`;
}

// -------------------------------------------------------------- universal
let attachments = [];   // [{name, type, dataURL}]
function renderAttachments() {
  const box = document.getElementById("attachments");
  box.innerHTML = attachments.map((a, i) => {
    const thumb = a.type.startsWith("image/") ? `<img src="${a.dataURL}" alt="">` : `<span>📄</span>`;
    return `<span class="att">${thumb}<span>${escapeHtml(a.name)}</span><span class="att-x" data-i="${i}">✕</span></span>`;
  }).join("");
  box.querySelectorAll(".att-x").forEach((x) => x.onclick = () => { attachments.splice(+x.dataset.i, 1); renderAttachments(); });
}
function addFiles(fileList) {
  for (const f of fileList) {
    if (f.size > 20 * 1024 * 1024) continue;   // 20MB cap
    const fr = new FileReader();
    fr.onload = () => { attachments.push({ name: f.name || "file", type: f.type || "application/octet-stream", dataURL: fr.result }); renderAttachments(); };
    fr.readAsDataURL(f);
  }
}
document.getElementById("attach-btn").onclick = () => document.getElementById("file-input").click();
document.getElementById("file-input").addEventListener("change", (e) => { addFiles(e.target.files); e.target.value = ""; });
document.getElementById("universal-input").addEventListener("paste", (e) => {
  const items = (e.clipboardData || {}).items || [];
  const files = []; for (const it of items) if (it.kind === "file") { const f = it.getAsFile(); if (f) files.push(f); }
  if (files.length) { e.preventDefault(); addFiles(files); }
});
document.getElementById("pane-universal").addEventListener("dragover", (e) => { e.preventDefault(); });
document.getElementById("pane-universal").addEventListener("drop", (e) => { e.preventDefault(); if (e.dataTransfer && e.dataTransfer.files.length) addFiles(e.dataTransfer.files); });

let routing = false;
async function runUniversal() {
  if (routing) return;                                  // ignore rapid double Enter
  const input = document.getElementById("universal-input");
  const prompt = input.value.trim();
  const files = attachments.slice();
  if (!prompt && !files.length) return;
  routing = true;
  input.value = "";
  const status = document.getElementById("universal-status");
  status.textContent = "Choosing the best AI…";
  try {
    const hasImage = files.some((a) => a.type.startsWith("image/"));
    let out;
    try {
      if (hasImage && !prompt) out = { provider: "gemini", reason: "image attached", local: true };
      else out = (await window.api.hasKey()) ? await window.api.route(prompt || "edit this image") : localRoute(prompt + (hasImage ? " image photo" : ""));
    } catch (err) {
      out = localRoute(prompt + (hasImage ? " image photo" : ""));
    }
    let p = providers.find((x) => x.id === out.provider) || providers[0];
    status.textContent = `Sent to ${p.name}${out.reason ? " — " + out.reason : ""}${out.local ? " (offline routing)" : ""}${files.length ? " · with " + files.length + " file(s)" : ""}`;
    if (prompt) { addRecent(prompt, p.id); addGlobalRecent(p.id, p.name, prompt); }
    deliver(p.id, withMemory(prompt), files);
    select(p.id);
    attachments = []; renderAttachments();
  } finally { routing = false; }
}
document.getElementById("universal-form").addEventListener("submit", (e) => { e.preventDefault(); runUniversal(); });
document.getElementById("universal-send").addEventListener("click", (e) => { e.preventDefault(); runUniversal(); });
// Enter sends (Shift+Enter = new line). Both a direct and a capture handler so
// it can't be missed on any platform.
function onUniversalEnter(e) {
  if (e.target && e.target.id === "universal-input" && e.key === "Enter" && !e.shiftKey) { e.preventDefault(); runUniversal(); }
}
document.getElementById("universal-input").addEventListener("keydown", onUniversalEnter);
document.addEventListener("keydown", onUniversalEnter, true);

// Offline keyword router — lets Universal work before an API key is added.
// Checked top to bottom; first match wins. Text tasks are listed before the
// broad "make/draw me a …" image rule so "write me an essay" → Claude while
// "make me an ice cream cone" → Gemini (image).
const HEURISTICS = [
  { id: "vercel", re: /\b(website|web ?app|landing page|react|next\.?js|tailwind|ui|component|dashboard|prototype|deploy|frontend)\b/i },
  { id: "deepseek", re: /\b(math|prove|theorem|equation|integral|derivative|algorithm|leetcode|calculus)\b/i },
  { id: "claude", re: /\b(code|debug|refactor|program|function|document|essay|write|rewrite|edit|proofread|summar|analy[sz]e|report|spreadsheet|contract|email|letter|plan|outline|schedule|list|table|translate)\b/i },
  { id: "xai", re: /\b(news|latest|today|real[- ]?time|current|breaking|stock|price|weather)\b/i },
  { id: "grok", re: /\b(tweet|x post|twitter|thread|trending on x)\b/i },
  { id: "gemini", re: /\b(image|picture|pic|photo|draw|drawing|logo|illustration|render|paint|painting|sketch|wallpaper|portrait|avatar|icon|cartoon|poster|video|veo|banana)\b/i },
  // Catch-all for visual/creative "make/create/generate/draw me a thing".
  { id: "gemini", re: /\b(make|create|generate|draw|design|show|give)\b.{0,20}\b(a|an|some|me)\b/i },
];
function localRoute(prompt) {
  const has = (id) => providers.some((p) => p.id === id);
  for (const h of HEURISTICS) if (h.re.test(prompt) && has(h.id)) return { provider: h.id, reason: "matched by keywords", local: true };
  const words = new Set((prompt.toLowerCase().match(/[a-z]{4,}/g)) || []);
  let best = null, score = 0;
  for (const p of providers) {
    const s = (p.strengths || "").toLowerCase();
    let n = 0; for (const w of words) if (s.includes(w)) n++;
    if (n > score) { score = n; best = p; }
  }
  if (best) return { provider: best.id, reason: "best match", local: true };
  // Nothing matched → a general assistant, not whatever happens to be first.
  const fallback = has("chatgpt") ? "chatgpt" : (providers[0] && providers[0].id) || "chatgpt";
  return { provider: fallback, reason: "general request", local: true };
}

// A short chime for replies — works even when Windows mutes toast sounds.
let audioCtx = null;
function playChime() {
  try {
    audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
    const now = audioCtx.currentTime;
    [880, 1320].forEach((freq, i) => {
      const o = audioCtx.createOscillator(), g = audioCtx.createGain();
      o.type = "sine"; o.frequency.value = freq;
      o.connect(g); g.connect(audioCtx.destination);
      const t = now + i * 0.12;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.18, t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.22);
      o.start(t); o.stop(t + 0.24);
    });
  } catch (e) {}
}

function addRecent(text, providerId) {
  recents.unshift({ text, providerId, at: Date.now() });
  recents = recents.slice(0, 12);
  window.api.setState({ universalRecents: recents });
  renderRecents();
  renderRightBar();
}
function renderRecents() {
  const box = document.getElementById("universal-recents");
  if (!recents.length) { box.innerHTML = ""; return; }
  box.innerHTML = `<div class="sr-ai" style="margin-bottom:6px">Recent</div>` +
    recents.map((r, i) => {
      const atts = Array.isArray(r.attachments) ? r.attachments : [];
      const chips = atts.slice(0, 4).map((a, ai) => {
        const t = a.thumb || a.dataURL;
        return t
          ? `<img class="recent-thumb" data-i="${i}" data-ai="${ai}" src="${t}" alt="" title="${escapeAttr(a.name || "")}">`
          : `<span class="recent-files" data-i="${i}" data-ai="${ai}" title="${escapeAttr(a.name || "file")}">📎</span>`;
      }).join("");
      const time = r.at ? `<span class="recent-time">${escapeHtml(fmtWhen(r.at))}</span>` : "";
      return `<div class="recent" data-i="${i}"><span class="recent-text">${escapeHtml(r.text)}</span>${chips}${time}</div>`;
    }).join("");
  box.querySelectorAll(".recent-thumb[data-ai], .recent-files[data-ai]").forEach((el) => {
    el.onclick = (ev) => {
      ev.stopPropagation();
      const r = recents[+el.dataset.i]; const a = r && r.attachments && r.attachments[+el.dataset.ai];
      if (a) openAttachment(a);
    };
  });
  box.querySelectorAll(".recent").forEach((el) => {
    el.onclick = () => { const r = recents[+el.dataset.i]; document.getElementById("universal-input").value = r.text; };
  });
}

// Open an attachment: images enlarge in a lightbox (with Download); other files
// open in the browser (where Storage serves them as a download).
function openAttachment(a) {
  if (!a) return;
  const thumb = a.thumb || a.dataURL;
  const isImg = (a.type || "").startsWith("image/") || (!!thumb && !a.type);
  if (isImg) { showLightbox(thumb || a.url, a); return; }
  if (a.url) window.api.openExternal(a.url);
}
function showLightbox(src, a) {
  if (!src) return;
  let lb = document.getElementById("uai-lightbox");
  if (!lb) { lb = document.createElement("div"); lb.id = "uai-lightbox"; lb.className = "uai-lightbox"; document.body.appendChild(lb); }
  lb.innerHTML = `<div class="lb-inner"><img src="${src}" alt=""><div class="lb-actions"><button class="lb-dl">Download</button><button class="lb-close">Close</button></div></div>`;
  lb.style.display = "flex";
  lb.querySelector(".lb-dl").onclick = () => {
    if (a.url) window.api.openExternal(a.url);
    else { try { const el = document.createElement("a"); el.href = src; el.download = a.name || "image.png"; document.body.appendChild(el); el.click(); el.remove(); } catch (e) {} }
  };
  lb.onclick = (e) => { if (e.target === lb || e.target.classList.contains("lb-close")) lb.style.display = "none"; };
}

// -------------------------------------------------------------- search
const search = document.getElementById("search");
const searchResults = document.getElementById("search-results");
let selIdx = 0, results = [];
search.addEventListener("input", renderSearchDropdown);
search.addEventListener("focus", renderSearchDropdown);
search.addEventListener("blur", () => setTimeout(() => searchResults.classList.remove("show"), 150));
search.addEventListener("keydown", (e) => {
  if (e.key === "Enter") { e.preventDefault(); const q = search.value.trim(); if (q) openSearchPage(q); searchResults.classList.remove("show"); }
  else if (e.key === "Escape") { searchResults.classList.remove("show"); search.blur(); }
  else if (results.length && e.key === "ArrowDown") { selIdx = Math.min(selIdx + 1, results.length - 1); markSel(); e.preventDefault(); }
  else if (results.length && e.key === "ArrowUp") { selIdx = Math.max(selIdx - 1, 0); markSel(); e.preventDefault(); }
});
function renderSearchDropdown() {
  const q = search.value.trim().toLowerCase();
  results = [];
  if (q) {
    for (const p of providers) if (p.name.toLowerCase().includes(q))
      results.push({ label: p.name, ai: "Open", run: () => { select(p.id); search.blur(); searchResults.classList.remove("show"); } });
    results.push({ label: `See all results for “${search.value.trim()}”`, ai: "Search", run: () => openSearchPage(search.value.trim()) });
  }
  selIdx = 0;
  searchResults.innerHTML = results.map((r, i) =>
    `<div class="sr-item ${i === 0 ? "sel" : ""}" data-i="${i}"><div>${escapeHtml(r.label)}</div><div class="sr-ai" style="margin-left:auto">${r.ai}</div></div>`).join("");
  searchResults.querySelectorAll(".sr-item").forEach((el) => { el.onmousedown = (e) => { e.preventDefault(); results[+el.dataset.i].run(); }; });
  searchResults.classList.toggle("show", results.length > 0);
}
function markSel() { searchResults.querySelectorAll(".sr-item").forEach((el, i) => el.classList.toggle("sel", i === selIdx)); }

// A dedicated results page: AIs, your recent prompts across all AIs, and media.
async function openSearchPage(q) {
  searchResults.classList.remove("show");
  select("__search__");
  const page = document.getElementById("search-page");
  const ql = q.toLowerCase();
  page.innerHTML = `<div class="search-head"><h2>Results for “${escapeHtml(q)}”</h2><button id="route-this" class="primary">Ask Universal AI</button></div><p class="rb-empty">Searching…</p>`;
  document.getElementById("route-this").onclick = () => { select("__universal__"); const t = document.getElementById("universal-input"); t.value = q; runUniversal(); };

  const ais = allKnown.filter((p) => `${p.name} ${p.maker || ""} ${p.strengths || ""}`.toLowerCase().includes(ql));
  const recentMatches = allRecents.filter((r) => r.text.toLowerCase().includes(ql)).slice(0, 40);
  let mediaMatches = [];
  try { mediaMatches = (await window.api.listMedia()).filter((m) => m.name.toLowerCase().includes(ql)).slice(0, 40); } catch (e) {}

  // Search the live page text of every AI you have open this session.
  const countJS = "(function(q){try{var t=((document.body&&document.body.innerText)||'').toLowerCase();var n=0,i=0;while((i=t.indexOf(q,i))>=0){n++;i+=q.length;}return n;}catch(e){return 0;}})(" + JSON.stringify(ql) + ")";
  const aiHits = [];
  for (const [id, wv] of Object.entries(webviews)) {
    try { const n = await wv.executeJavaScript(countJS); if (n > 0) aiHits.push({ id, n }); } catch (e) {}
  }

  const sec = (title, inner) => inner ? `<div class="res-sec"><h3>${title}</h3>${inner}</div>` : "";
  const nameOf = (id) => (allKnown.find((p) => p.id === id) || { name: id }).name;
  const hitHtml = aiHits.map((h) => `<div class="res-row" data-kind="hit" data-id="${h.id}"><span>${escapeHtml(nameOf(h.id))}</span><span class="muted">${h.n} match${h.n === 1 ? "" : "es"} · open &amp; jump to it</span></div>`).join("");
  const aiHtml = ais.map((p) => `<div class="res-row" data-kind="ai" data-id="${p.id}"><img src="${faviconFor(p)}" onerror="this.style.display='none'"/><span>${escapeHtml(p.name)}</span><span class="muted">${escapeHtml(p.maker || "")}</span></div>`).join("");
  const recHtml = recentMatches.map((r, i) => `<div class="res-row" data-kind="recent" data-i="${i}"><span class="muted" style="min-width:72px">${escapeHtml(r.name || "AI")}</span><span>${escapeHtml(r.text)}</span></div>`).join("");
  const medHtml = mediaMatches.map((m) => `<div class="res-row" data-kind="media" data-path="${escapeAttr(m.path)}"><span>${escapeHtml(m.name)}</span><span class="muted">${escapeHtml(m.folder)}</span></div>`).join("");

  const any = aiHits.length || ais.length || recentMatches.length || mediaMatches.length;
  page.innerHTML = `<div class="search-head"><h2>Results for “${escapeHtml(q)}”</h2><button id="route-this" class="primary">Ask Universal AI</button></div>` +
    (any
      ? sec("In your open AIs", hitHtml) + sec("AIs", aiHtml) + sec("Recent prompts", recHtml) + sec("Media", medHtml)
      : `<p class="rb-empty">No matches in your open AIs, recent prompts, or media. Only AIs you've opened this session can be searched inside — open an AI, then search. Or use “Ask Universal AI”.</p>`);
  page._recent = recentMatches;
  document.getElementById("route-this").onclick = () => { select("__universal__"); const t = document.getElementById("universal-input"); t.value = q; runUniversal(); };
  page.querySelectorAll('.res-row[data-kind="hit"]').forEach((el) => el.onclick = () => {
    const id = el.dataset.id; select(id);
    const wv = webviews[id];
    if (wv) setTimeout(() => { try { wv.stopFindInPage("clearSelection"); wv.findInPage(q); } catch (e) {} }, 200);
  });
  page.querySelectorAll('.res-row[data-kind="ai"]').forEach((el) => el.onclick = () => select(el.dataset.id));
  page.querySelectorAll('.res-row[data-kind="recent"]').forEach((el) => el.onclick = () => { const r = page._recent[+el.dataset.i]; if (r && r.providerId && !hidden.has(r.providerId)) select(r.providerId); });
  page.querySelectorAll('.res-row[data-kind="media"]').forEach((el) => el.onclick = () => window.api.openMediaFile(el.dataset.path));
}

// -------------------------------------------------------------- media
let mediaTab = "all";
const MEDIA_TABS = [["all", "All"], ["image", "Images"], ["video", "Videos"], ["document", "Documents"], ["screenshots", "Screenshots"], ["other", "Other"]];
function renderMediaTabs() {
  const box = document.getElementById("media-tabs");
  box.innerHTML = MEDIA_TABS.map(([k, label]) => `<button data-k="${k}" class="${k === mediaTab ? "active" : ""}">${label}</button>`).join("");
  box.querySelectorAll("button").forEach((b) => b.onclick = () => { mediaTab = b.dataset.k; renderMediaTabs(); loadMedia(); });
}
async function loadMedia() {
  const all = await window.api.listMedia();
  const items = all.filter((m) => {
    if (mediaTab === "screenshots") return m.isScreenshot;
    if (m.isScreenshot) return false;
    if (mediaTab === "all") return true;
    return m.kind === mediaTab;
  });
  const grid = document.getElementById("media-grid");
  document.getElementById("media-empty").classList.toggle("show", items.length === 0);
  grid.innerHTML = items.map((m) => tileHtml(m)).join("");
  grid.querySelectorAll(".tile").forEach((el) => {
    el.onclick = () => window.api.openMediaFile(el.dataset.path);
    el.oncontextmenu = (e) => { e.preventDefault(); window.api.revealMedia(el.dataset.path); };
  });
}
function fileURL(p) {
  // Windows paths use backslashes and a drive letter; turn them into a valid
  // file:/// URL (forward slashes, encoded spaces) so the preview loads.
  return "file:///" + encodeURI(String(p).replace(/\\/g, "/")).replace(/'/g, "%27");
}
function tileHtml(m) {
  const thumb = m.kind === "image"
    ? `<div class="thumb" style="background-image:url('${fileURL(m.path)}')"></div>`
    : `<div class="thumb">${m.kind === "video" ? "🎞" : m.kind === "document" ? "📄" : "📁"}</div>`;
  const kb = m.size > 1048576 ? (m.size / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(m.size / 1024)) + " KB";
  const date = m.created ? new Date(m.created).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" }) : "";
  return `<div class="tile" data-path="${escapeAttr(m.path)}">${thumb}
    <div class="meta"><div class="name">${escapeHtml(m.name)}</div><div class="sub">${escapeHtml(m.folder)} · ${date} · ${kb}</div></div></div>`;
}
document.getElementById("btn-media").onclick = () => select("__media__");
document.getElementById("media-folder").onclick = () => window.api.openMediaFolder();

// -------------------------------------------------------------- memory
document.getElementById("btn-memory").onclick = () => select("__memory__");
// A recommended memory note (the working rules), addable with one click.
const WORKING_RULES = `# Working rules

- No human reads this file. Optimize it for your own adherence, not readability.
- If my request is ambiguous, ask one clarifying question, then proceed with your best judgment. Only stop to ask when a wrong guess would be expensive to undo (API shape, data model, deleting things). For cheap choices (filenames, naming), decide and mention it.
- Don't change anything I didn't ask you to change. Before editing, name the smallest file/function you plan to touch and why.
- Before writing a fix, state the diagnosis in one sentence and confirm the root cause with evidence (log, payload, DB row, output). Don't build on an assumed premise.
- Never report a check as passing unless it ran as its own command and you read the exit code directly, not through a pipe into grep or tail.
- Separate what you measured directly from what you inferred from logs, dashboards, or notes. Mark inferred claims as "probably."
- After two failed attempts, stop and tell me what you've ruled out and what's blocking you, instead of trying a third time.
- Don't apologize. Fix it, tell me what changed, and if there was a clear reason for the mistake, say what it was.
- Don't use reasoning for things a script or tool can do deterministically.
- Preplan your tool calls and batch independent ones together; wait for all to return before reading any.
- When reporting status, be extremely concise. Sacrifice grammar for concision.
- When updating this file, replace outdated rules instead of adding new ones next to them.`;

function renderMemory() {
  const list = document.getElementById("memory-list");
  const rec = memory.some((m) => m === WORKING_RULES) ? ""
    : `<div class="mem-rec">💡 Recommended: working rules that make AIs more precise. <a href="#" id="mem-add-rules">Add working rules</a></div>`;
  list.innerHTML = rec + (memory.length
    ? memory.map((m, i) => `<div class="mem-row"><span>${escapeHtml(m)}</span><a href="#" class="mem-copy" data-i="${i}">Copy</a><a href="#" class="mem-del" data-i="${i}">Remove</a></div>`).join("")
    : `<p class="rb-empty">Nothing yet. Add a note above to reuse across your AIs.</p>`);
  const addRules = document.getElementById("mem-add-rules");
  if (addRules) addRules.onclick = (e) => { e.preventDefault(); memory.unshift(WORKING_RULES); window.api.setState({ memory }); renderMemory(); };
  list.querySelectorAll(".mem-copy").forEach((a) => a.onclick = (e) => { e.preventDefault(); try { navigator.clipboard.writeText(memory[+a.dataset.i]); } catch (x) {} a.textContent = "Copied"; setTimeout(() => a.textContent = "Copy", 1200); });
  list.querySelectorAll(".mem-del").forEach((a) => a.onclick = (e) => { e.preventDefault(); memory.splice(+a.dataset.i, 1); window.api.setState({ memory }); renderMemory(); });
}
function addMemory() {
  const inp = document.getElementById("memory-input");
  const v = inp.value.trim();
  if (!v) return;
  memory.unshift(v); inp.value = "";
  window.api.setState({ memory });
  renderMemory();
}
document.getElementById("memory-add").onclick = addMemory;
document.getElementById("memory-input").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); addMemory(); } });
document.getElementById("media-clear").onclick = async () => {
  if (confirm("Move all files in your UAI Media folder to the Recycle Bin?")) { await window.api.clearMedia(); loadMedia(); }
};

// -------------------------------------------------------------- settings
document.getElementById("btn-settings").onclick = () => { select("__settings__"); fillProfileSettings(); };
async function refreshApiKeyStatus() {
  const has = await window.api.hasKey();
  document.getElementById("apikey-status").textContent = has ? "A key is saved." : "No key saved.";
}
document.getElementById("apikey-save").onclick = async () => {
  const v = document.getElementById("apikey").value.trim();
  await window.api.setKey(v);
  document.getElementById("apikey").value = "";
  refreshApiKeyStatus();
};

// ---- profile settings ----
let pendingPhoto = null;
function fillProfileSettings() {
  const n = document.getElementById("profile-name"); if (n) n.value = profile.name || "";
  renderProfilePreview(profile.avatar || "");
}
function renderProfilePreview(url) {
  const el = document.getElementById("profile-preview"); if (!el) return;
  el.innerHTML = url ? `<img src="${escapeAttr(url)}" style="width:48px;height:48px;border-radius:50%;object-fit:cover" referrerpolicy="no-referrer"/>` : "";
}
document.getElementById("profile-photo").onclick = async () => {
  const d = await window.api.choosePhoto();
  if (d) { pendingPhoto = d; renderProfilePreview(d); }
};
document.getElementById("profile-save").onclick = () => {
  const name = document.getElementById("profile-name").value.trim();
  profile = { name, avatar: pendingPhoto || profile.avatar || "" };
  window.api.setState({ profile });
  renderProfile();
  pendingPhoto = null;
};
document.getElementById("profile-clear").onclick = () => {
  profile = {}; pendingPhoto = null;
  window.api.setState({ profile });
  renderProfile(); fillProfileSettings();
};

// -------------------------------------------------------------- updates
(async () => {
  try { const v = await window.api.appVersion(); const el = document.getElementById("about-version"); if (el) el.textContent = "v" + v; } catch (e) {}
})();
document.getElementById("update-check").onclick = async () => {
  document.getElementById("update-status").textContent = "Checking…";
  await window.api.checkUpdate();
};
let notifiedUpdateVersion = null;
function markUpdateAvailable(version) {
  const btn = document.getElementById("btn-settings");
  if (btn) btn.classList.add("has-update");   // red dot on the gear
  if (version && notifiedUpdateVersion !== version) {
    notifiedUpdateVersion = version;
    try { window.api.notify({ title: "UAI update available", body: `Version ${version} is ready — open Settings to install.` }); } catch (e) {}
  }
}
function clearUpdateDot() { const btn = document.getElementById("btn-settings"); if (btn) btn.classList.remove("has-update"); }

window.api.onUpdateStatus(({ status, info }) => {
  const s = document.getElementById("update-status");
  const installBtn = document.getElementById("update-install");
  if (!s) return;
  if (status === "checking") s.textContent = "Checking…";
  else if (status === "available") { s.textContent = `Downloading ${info && info.version ? "v" + info.version : "update"}…`; markUpdateAvailable(info && info.version); }
  else if (status === "downloading") s.textContent = `Downloading… ${info ? info.percent : 0}%`;
  else if (status === "none") { s.textContent = "You're on the latest version."; clearUpdateDot(); }
  else if (status === "error") s.textContent = "Update check failed: " + (info && info.message ? info.message : "");
  else if (status === "ready") {
    s.textContent = `Update ${info && info.version ? "v" + info.version : ""} ready.`;
    if (installBtn) { installBtn.style.display = ""; installBtn.onclick = () => window.api.installUpdate(); }
    markUpdateAvailable(info && info.version);
  }
});
function buildSettingsProviders() {
  const box = document.getElementById("settings-providers");
  // List every AI. Custom ones can be removed; built-in ones can be hidden
  // from the rail (and shown again).
  box.innerHTML = allKnown.map((p) => {
    const isHidden = hidden.has(p.id);
    const action = p.custom
      ? `<a href="#" class="sp-remove" data-id="${p.id}">Remove</a>`
      : `<a href="#" class="sp-toggle" data-id="${p.id}">${isHidden ? "Show" : "Hide"}</a>`;
    return `<div class="sp-row" style="${isHidden ? "opacity:.5" : ""}">
      <img src="${faviconFor(p)}" onerror="this.style.display='none'"/><span>${escapeHtml(p.name)}</span>${action}</div>`;
  }).join("");

  const refresh = async () => { await loadProviders(await window.api.getState()); buildRail(); buildSettingsProviders(); };
  box.querySelectorAll(".sp-remove").forEach((a) => a.onclick = async (e) => {
    e.preventDefault();
    if (!confirm("Remove this AI?")) return;
    await window.api.removeCustomAI(a.dataset.id);
    if (webviews[a.dataset.id]) { webviews[a.dataset.id].remove(); delete webviews[a.dataset.id]; }
    const wasCurrent = current === a.dataset.id;
    await refresh();
    if (wasCurrent) select("__universal__");
  });
  box.querySelectorAll(".sp-toggle").forEach((a) => a.onclick = async (e) => {
    e.preventDefault();
    const id = a.dataset.id;
    if (hidden.has(id)) hidden.delete(id); else hidden.add(id);
    await window.api.setState({ hiddenProviders: [...hidden] });
    if (hidden.has(id) && webviews[id]) { webviews[id].remove(); delete webviews[id]; }
    const wasCurrent = current === id;
    await refresh();
    if (wasCurrent && hidden.has(id)) select("__universal__");
  });
}

// -------------------------------------------------------------- add AI
const addDialog = document.getElementById("add-dialog");
document.getElementById("rail-add").onclick = () => { addDialog.showModal(); };
addDialog.addEventListener("close", async () => {
  if (addDialog.returnValue !== "ok") return;
  const name = document.getElementById("add-name").value.trim();
  let url = document.getElementById("add-url").value.trim();
  const strengths = document.getElementById("add-strengths").value.trim();
  if (!name || !url) return;
  if (!/^https?:\/\//i.test(url)) url = "https://" + url;
  await window.api.addCustomAI({ name, url, strengths });
  document.getElementById("add-name").value = "";
  document.getElementById("add-url").value = "";
  document.getElementById("add-strengths").value = "";
  await loadProviders(await window.api.getState());
  buildRail(); buildSettingsProviders();
});

// -------------------------------------------------------------- reconnect (paste login link)
const reconnectDialog = document.getElementById("reconnect-dialog");
document.getElementById("reconnect").onclick = async () => {
  if (!isProvider(current)) return;
  const p = providers.find((x) => x.id === current);
  document.getElementById("reconnect-ai").textContent = p ? p.name : "this AI";
  const input = document.getElementById("reconnect-url");
  input.value = "";
  // Prefill from the clipboard if it already holds a link, so one click is enough.
  try { const c = ((await navigator.clipboard.readText()) || "").trim(); if (/^https?:\/\//i.test(c)) input.value = c; } catch (e) {}
  reconnectDialog.showModal();
  setTimeout(() => input.focus(), 30);
};
reconnectDialog.addEventListener("close", () => {
  const input = document.getElementById("reconnect-url");
  let url = input.value.trim();
  input.value = "";
  if (reconnectDialog.returnValue !== "ok" || !url || !isProvider(current)) return;
  if (!/^https?:\/\//i.test(url)) url = "https://" + url;
  // Open the link inside THIS AI's window so the sign-in completes in-session.
  const wv = ensureWebview(current);
  if (wv) { try { wv.loadURL(url); } catch (e) { wv.setAttribute("src", url); } select(current); }
});

// -------------------------------------------------------------- claude working rules
const CLAUDE_RULES = `Please keep these working rules in mind for all of our conversations:

# Working rules

- No human reads this file. Optimize it for your own adherence, not readability.
- If my request is ambiguous, ask one clarifying question, then proceed with your best judgment. Only stop to ask when a wrong guess would be expensive to undo (API shape, data model, deleting things). For cheap choices (filenames, naming), decide and mention it.
- Don't change anything I didn't ask you to change. Before editing, name the smallest file/function you plan to touch and why.
- Before writing a fix, state the diagnosis in one sentence and confirm the root cause with evidence (log, payload, DB row, output). Don't build on an assumed premise.
- Never report a check as passing unless it ran as its own command and you read the exit code directly, not through a pipe into grep or tail.
- Separate what you measured directly from what you inferred from logs, dashboards, or notes. Mark inferred claims as "probably."
- After two failed attempts, stop and tell me what you've ruled out and what's blocking you, instead of trying a third time.
- Don't apologize. Fix it, tell me what changed, and if there was a clear reason for the mistake, say what it was.
- Don't use reasoning for things a script or tool can do deterministically.
- Preplan your tool calls and batch independent ones together; wait for all to return before reading any.
- When reporting status, be extremely concise. Sacrifice grammar for concision.
- When updating this file, replace outdated rules instead of adding new ones next to them.`;
document.getElementById("claude-rules-send").onclick = () => {
  const status = document.getElementById("claude-rules-status");
  if (!allKnown.some((p) => p.id === "claude")) { status.textContent = "Claude isn't in your AIs."; return; }
  select("claude");
  deliver("claude", CLAUDE_RULES, [], true);   // forceInject: don't use URL prefill
  status.textContent = "Sent to Claude.";
  setTimeout(() => { status.textContent = ""; }, 4000);
};

// -------------------------------------------------------------- universal rail btn
document.getElementById("rail-universal").onclick = () => select("__universal__");

// -------------------------------------------------------------- zoom
window.addEventListener("keydown", (e) => {
  if (!(e.ctrlKey || e.metaKey)) return;
  const wv = activeWebview();
  if (e.key === "=" || e.key === "+") { if (wv) wv.setZoomLevel(wv.getZoomLevel() + 0.5); e.preventDefault(); }
  else if (e.key === "-") { if (wv) wv.setZoomLevel(wv.getZoomLevel() - 0.5); e.preventDefault(); }
  else if (e.key === "0") { if (wv) wv.setZoomLevel(0); e.preventDefault(); }
});

// refresh nav button state periodically (webview nav changes aren't all evented)
setInterval(updateNavButtons, 800);

// -------------------------------------------------------------- utils
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function escapeAttr(s) { return escapeHtml(s); }

// -------------------------------------------------------------- right bar
function addNotification(providerId, name, preview) {
  notifications.unshift({ providerId, name, preview, at: Date.now() });
  notifications = notifications.slice(0, 50);
  window.api.setState({ notifications });
  renderRightBar();
}
function timeAgo(ts) {
  const s = Math.max(1, Math.round((Date.now() - ts) / 1000));
  if (s < 60) return s + "s";
  if (s < 3600) return Math.round(s / 60) + "m";
  if (s < 86400) return Math.round(s / 3600) + "h";
  return Math.round(s / 86400) + "d";
}
// Absolute, readable timestamp (e.g. "Oct 5, 7:02 PM") for the Recent list.
function fmtWhen(ts) {
  try {
    return new Date(ts).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  } catch (e) { return ""; }
}
function renderRightBar() {
  const nl = document.getElementById("rb-notif-list");
  nl.innerHTML = notifications.length
    ? notifications.map((n, i) => `<div class="rb-item" data-i="${i}">
        <div class="rb-title"><span>${escapeHtml(n.name)}</span><span class="rb-time">${timeAgo(n.at)}</span></div>
        <div class="rb-body">${escapeHtml(n.preview || "")}</div></div>`).join("")
    : `<div class="rb-empty">No replies yet. When an AI answers, it shows up here.</div>`;
  nl.querySelectorAll(".rb-item").forEach((el) => el.onclick = () => { const n = notifications[+el.dataset.i]; if (n) select(n.providerId); });

  // Recent: prompts you've sent across all the AIs. Click to reopen that AI.
  const rl = document.getElementById("rb-recent-list");
  rl.innerHTML = allRecents.length
    ? allRecents.slice(0, 40).map((r, i) => `<div class="rb-item" data-i="${i}">
        <div class="rb-title"><span>${escapeHtml(r.name || "AI")}</span><span class="rb-time">${timeAgo(r.at)}</span></div>
        <div class="rb-body">${escapeHtml(r.text)}</div></div>`).join("")
    : `<div class="rb-empty">Prompts you send in any AI show up here.</div>`;
  rl.querySelectorAll(".rb-item").forEach((el) => el.onclick = () => {
    const r = allRecents[+el.dataset.i]; if (!r) return;
    if (r.providerId && !hidden.has(r.providerId)) select(r.providerId);
  });

  // Suggestions: canned starter prompts. Click to drop into Universal AI.
  const sl = document.getElementById("rb-sugg-list");
  sl.innerHTML = SUGGESTIONS.map((s, i) => `<div class="rb-item rb-sugg" data-i="${i}">
      <div class="rb-body">${escapeHtml(s.icon)} ${escapeHtml(s.text)}</div></div>`).join("");
  sl.querySelectorAll(".rb-item").forEach((el) => el.onclick = () => {
    const s = SUGGESTIONS[+el.dataset.i]; if (!s) return;
    select("__universal__");
    const t = document.getElementById("universal-input");
    if (t) { t.value = s.text; t.focus(); }
  });
}
const SUGGESTIONS = [
  { icon: "🖼", text: "Make me an image of…" },
  { icon: "📈", text: "Summarize today's market news" },
  { icon: "</>", text: "Write a script to…" },
  { icon: "✉️", text: "Draft an email about…" },
  { icon: "🎬", text: "Create a short video of…" },
  { icon: "🔍", text: "Research and compare…" },
];
document.getElementById("rb-clear").onclick = () => { notifications = []; window.api.setState({ notifications }); renderRightBar(); };
document.getElementById("rb-recent-clear").onclick = () => { allRecents = []; window.api.setState({ allRecents }); renderRightBar(); };
document.getElementById("btn-rightbar").onclick = () => {
  const app = document.getElementById("app");
  app.classList.toggle("rb-hidden");
  window.api.setState({ rbHidden: app.classList.contains("rb-hidden") });
};

// Start up, and if anything goes wrong show it instead of a dead blank app.
if (!window.api) {
  document.body.innerHTML = '<div style="padding:40px;color:#e7e9ee;font:14px system-ui">UAI failed to start: the internal bridge didn\'t load. Please reinstall the latest build.</div>';
} else {
  boot().catch((err) => {
    const s = document.getElementById("status");
    if (s) s.textContent = "Startup error: " + (err && err.message ? err.message : err);
    console.error("UAI boot failed:", err);
  });
}
