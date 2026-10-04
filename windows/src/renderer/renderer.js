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

// -------------------------------------------------------------- startup
drawGalaxies();   // render the spiral galaxy SVG into the rail icon + hero
async function boot() {
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

function deliver(id, text) {
  // 1) Best: navigate the AI to a URL that carries the prompt. Create the
  //    webview straight at that URL when it doesn't exist yet (avoids a
  //    loadURL-before-ready race that dropped the prompt).
  if (PREFILL[id]) {
    const url = PREFILL[id](text);
    const existing = webviews[id];
    if (!existing) { ensureWebview(id, url); }
    else { try { existing.loadURL(url); } catch (e) { existing.setAttribute("src", url); } }
    return;
  }
  const wv = ensureWebview(id);
  if (!wv) return;
  // 2) Otherwise type it into the composer, retrying until it appears, and
  //    copy it so you can paste if the site blocks scripted input.
  try { navigator.clipboard.writeText(text); } catch (e) {}
  let n = 0;
  const tryInject = () => {
    wv.executeJavaScript(deliverScript(text)).then((ok) => {
      if (!ok && ++n < 24) setTimeout(tryInject, 500);
    }).catch(() => { if (++n < 24) setTimeout(tryInject, 500); });
  };
  if (wv.isLoading && wv.isLoading()) wv.addEventListener("dom-ready", () => setTimeout(tryInject, 300), { once: true });
  else setTimeout(tryInject, 300);
}

function deliverScript(text) {
  return `(() => {
    const t = ${JSON.stringify(text)};
    const vis = el => { const r = el.getBoundingClientRect(); return r.width>80 && r.height>12 && el.offsetParent!==null && !el.disabled && !el.readOnly; };
    const boxes = [...document.querySelectorAll('textarea,[contenteditable="true"],div[role="textbox"]')].filter(vis);
    if (!boxes.length) return false;
    boxes.sort((a,b)=>b.getBoundingClientRect().bottom-a.getBoundingClientRect().bottom);
    const el = boxes[0]; el.focus();
    if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
      const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, t); el.dispatchEvent(new Event('input', { bubbles: true }));
    } else {
      el.textContent = t; el.dispatchEvent(new InputEvent('input', { bubbles: true }));
    }
    setTimeout(() => {
      el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
      el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
    }, 500);
    return true;
  })()`;
}

// -------------------------------------------------------------- nav bar
function activeWebview() { return isProvider(current) ? webviews[current] : null; }
function updateNavButtons() {
  const wv = activeWebview();
  document.getElementById("back").disabled = !(wv && wv.canGoBack && wv.canGoBack());
  document.getElementById("forward").disabled = !(wv && wv.canGoForward && wv.canGoForward());
  document.getElementById("reload").disabled = !wv;
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

// Draw a real spiral galaxy (matching the app icon) as SVG, for the rail icon
// and the Universal hero — the old CSS gradient just looked like a blob.
function galaxySVG() {
  const cx = 50, cy = 50, R = 46;
  const seeded = (i) => { const v = Math.sin(i * 12.9898) * 43758.5453; return v - Math.floor(v); };
  let s = `<svg viewBox="0 0 100 100" width="100%" height="100%" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg">`;
  s += `<defs><radialGradient id="gcore" cx="50%" cy="50%" r="50%">
    <stop offset="0%" stop-color="#ffffff"/><stop offset="55%" stop-color="#f173ad" stop-opacity="0.85"/><stop offset="100%" stop-color="#f173ad" stop-opacity="0"/></radialGradient></defs>`;
  s += `<circle cx="50" cy="50" r="50" fill="#0a081a"/>`;
  for (let i = 0; i < 26; i++) {
    const x = seeded(i * 7) * 100, y = seeded(i * 13) * 100, rr = 0.3 + seeded(i) * 0.7;
    s += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${rr.toFixed(2)}" fill="#fff" opacity="${(0.25 + seeded(i * 3) * 0.5).toFixed(2)}"/>`;
  }
  s += `<circle cx="50" cy="50" r="18" fill="url(#gcore)"/>`;
  const tilt = Math.PI / 9, cosT = Math.cos(tilt), sinT = Math.sin(tilt), flat = 0.75;
  for (const [off, color] of [[0, "#f173ad"], [Math.PI, "#7fd1e0"]]) {
    for (let i = 0; i < 60; i++) {
      const t = i / 60, ang = off + t * 3.3 * Math.PI, r = R * (0.12 + 0.88 * t);
      const jit = (seeded(i + off * 100) - 0.5) * R * 0.08;
      const px = Math.cos(ang) * (r + jit), py = Math.sin(ang) * (r + jit) * flat;
      const x = cx + px * cosT - py * sinT, y = cy + px * sinT + py * cosT;
      const dot = R * (0.07 - 0.045 * t);
      const fill = t < 0.22 ? "#ffffff" : color;
      s += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${Math.max(0.4, dot).toFixed(2)}" fill="${fill}" opacity="${(0.95 - 0.5 * t).toFixed(2)}"/>`;
    }
  }
  s += `</svg>`;
  return s;
}
function drawGalaxies() {
  const svg = galaxySVG();
  document.querySelectorAll(".galaxy").forEach((el) => { el.innerHTML = svg; });
}

// Prepend your saved Memory notes as context, so Universal prompts carry them.
function withMemory(prompt) {
  if (!memory || !memory.length) return prompt;
  const ctx = memory.slice(0, 20).map((m) => "- " + m).join("\n");
  return `Context about me (please keep in mind):\n${ctx}\n\nRequest: ${prompt}`;
}

// -------------------------------------------------------------- universal
let routing = false;
async function runUniversal() {
  if (routing) return;                                  // ignore rapid double Enter
  const input = document.getElementById("universal-input");
  const prompt = input.value.trim();
  if (!prompt) return;
  routing = true;
  input.value = "";                                     // clear now so a 2nd Enter no-ops
  const status = document.getElementById("universal-status");
  status.textContent = "Choosing the best AI…";
  try {
    let out;
    try {
      out = (await window.api.hasKey()) ? await window.api.route(prompt) : localRoute(prompt);
    } catch (err) {
      out = localRoute(prompt);   // API error → fall back to offline keyword routing
    }
    const p = providers.find((x) => x.id === out.provider) || providers[0];
    status.textContent = `Sent to ${p.name}${out.reason ? " — " + out.reason : ""}${out.local ? " (offline routing)" : ""}`;
    addRecent(prompt, p.id);
    addGlobalRecent(p.id, p.name, prompt);
    deliver(p.id, withMemory(prompt));   // include your memory as context; create/navigate webview
    select(p.id);                        // then reveal it
  } finally { routing = false; }
}
document.getElementById("universal-form").addEventListener("submit", (e) => { e.preventDefault(); runUniversal(); });
// Enter sends (Shift+Enter = new line). Attached directly to the textarea on
// keydown; no isComposing guard (Windows can flag the first Enter as composing,
// which was forcing a second press).
document.getElementById("universal-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); runUniversal(); }
});

// Offline keyword router — lets Universal work before an API key is added.
const HEURISTICS = [
  { id: "gemini", re: /\b(image|picture|photo|draw|logo|video|veo|banana)\b/i },
  { id: "vercel", re: /\b(website|web app|landing page|react|next\.?js|tailwind|ui|component|dashboard|prototype|deploy)\b/i },
  { id: "deepseek", re: /\b(math|prove|theorem|equation|integral|algorithm|leetcode)\b/i },
  { id: "claude", re: /\b(code|debug|refactor|document|essay|write|edit|analyze|report|spreadsheet|contract)\b/i },
  { id: "xai", re: /\b(news|latest|today|real[- ]?time|current|breaking|stock|price)\b/i },
  { id: "grok", re: /\b(tweet|x post|twitter|thread)\b/i },
];
function localRoute(prompt) {
  const has = (id) => providers.some((p) => p.id === id);
  for (const h of HEURISTICS) if (h.re.test(prompt) && has(h.id)) return { provider: h.id, reason: "matched by keywords", local: true };
  const words = new Set((prompt.toLowerCase().match(/[a-z]{4,}/g)) || []);
  let best = providers[0], score = -1;
  for (const p of providers) {
    const s = (p.strengths || "").toLowerCase();
    let n = 0; for (const w of words) if (s.includes(w)) n++;
    if (n > score) { score = n; best = p; }
  }
  return { provider: best ? best.id : "claude", reason: "best match", local: true };
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
    recents.map((r, i) => `<div class="recent" data-i="${i}">${escapeHtml(r.text)}</div>`).join("");
  box.querySelectorAll(".recent").forEach((el) => {
    el.onclick = () => { const r = recents[+el.dataset.i]; document.getElementById("universal-input").value = r.text; };
  });
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
function renderMemory() {
  const list = document.getElementById("memory-list");
  list.innerHTML = memory.length
    ? memory.map((m, i) => `<div class="mem-row"><span>${escapeHtml(m)}</span><a href="#" class="mem-copy" data-i="${i}">Copy</a><a href="#" class="mem-del" data-i="${i}">Remove</a></div>`).join("")
    : `<p class="rb-empty">Nothing yet. Add a note above to reuse across your AIs.</p>`;
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
window.api.onUpdateStatus(({ status, info }) => {
  const s = document.getElementById("update-status");
  const installBtn = document.getElementById("update-install");
  if (!s) return;
  if (status === "checking") s.textContent = "Checking…";
  else if (status === "available") s.textContent = `Downloading ${info && info.version ? "v" + info.version : "update"}…`;
  else if (status === "downloading") s.textContent = `Downloading… ${info ? info.percent : 0}%`;
  else if (status === "none") s.textContent = "You're on the latest version.";
  else if (status === "error") s.textContent = "Update check failed: " + (info && info.message ? info.message : "");
  else if (status === "ready") {
    s.textContent = `Update ${info && info.version ? "v" + info.version : ""} ready.`;
    if (installBtn) { installBtn.style.display = ""; installBtn.onclick = () => window.api.installUpdate(); }
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
function renderRightBar() {
  const nl = document.getElementById("rb-notif-list");
  nl.innerHTML = notifications.length
    ? notifications.map((n, i) => `<div class="rb-item" data-i="${i}">
        <div class="rb-title"><span>${escapeHtml(n.name)}</span><span class="rb-time">${timeAgo(n.at)}</span></div>
        <div class="rb-body">${escapeHtml(n.preview || "")}</div></div>`).join("")
    : `<div class="rb-empty">No replies yet. When an AI answers, it shows up here.</div>`;
  nl.querySelectorAll(".rb-item").forEach((el) => el.onclick = () => { const n = notifications[+el.dataset.i]; if (n) select(n.providerId); });

  // Recent: prompts you've sent across all the AIs. Click to reopen that AI.
  const sl = document.getElementById("rb-sugg-list");
  sl.innerHTML = allRecents.length
    ? allRecents.slice(0, 40).map((r, i) => `<div class="rb-item" data-i="${i}">
        <div class="rb-title"><span>${escapeHtml(r.name || "AI")}</span><span class="rb-time">${timeAgo(r.at)}</span></div>
        <div class="rb-body">${escapeHtml(r.text)}</div></div>`).join("")
    : `<div class="rb-empty">Prompts you send in any AI show up here.</div>`;
  sl.querySelectorAll(".rb-item").forEach((el) => el.onclick = () => {
    const r = allRecents[+el.dataset.i]; if (!r) return;
    if (r.providerId && !hidden.has(r.providerId)) select(r.providerId);
  });
}
document.getElementById("rb-clear").onclick = () => { notifications = []; window.api.setState({ notifications }); renderRightBar(); };
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
