"use strict";

const paneWebviews = document.getElementById("pane-webviews");
const railProviders = document.getElementById("rail-providers");

let providers = [];        // ordered list of provider objects
let current = "__universal__";
const webviews = {};       // id -> <webview>
const unread = {};         // id -> count
let recents = [];
let notifications = [];

// -------------------------------------------------------------- startup
async function boot() {
  const state = await window.api.getState();
  recents = state.universalRecents || [];
  notifications = state.notifications || [];
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
  const order = state.railOrder || [];
  const byId = Object.fromEntries(all.map((p) => [p.id, p]));
  const ordered = [];
  for (const id of order) if (byId[id]) { ordered.push(byId[id]); delete byId[id]; }
  for (const p of all) if (byId[p.id]) ordered.push(byId[p.id]);
  providers = ordered;
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
  ["pane-universal", "pane-media", "pane-settings", "pane-webviews"].forEach((pid) =>
    document.getElementById(pid).classList.remove("show"));
  Object.values(webviews).forEach((wv) => wv.classList.remove("show"));

  if (id === "__universal__") document.getElementById("pane-universal").classList.add("show");
  else if (id === "__media__") { document.getElementById("pane-media").classList.add("show"); loadMedia(); }
  else if (id === "__settings__") document.getElementById("pane-settings").classList.add("show");
  else {
    document.getElementById("pane-webviews").classList.add("show");
    if (webviews[id]) webviews[id].classList.add("show");
  }
}

// -------------------------------------------------------------- webviews
function ensureWebview(id) {
  if (webviews[id]) return webviews[id];
  const p = providers.find((x) => x.id === id);
  if (!p) return null;
  const wv = document.createElement("webview");
  // One shared, persistent session for all AIs, so a single Google (or other)
  // sign-in is recognized across every AI instead of logging in each one.
  wv.setAttribute("partition", "persist:uai");
  wv.setAttribute("preload", window.api.webviewPreload);
  wv.setAttribute("allowpopups", "");
  wv.setAttribute("src", p.home);
  wv.dataset.id = id;
  paneWebviews.appendChild(wv);
  webviews[id] = wv;

  wv.addEventListener("ipc-message", (e) => onWebviewMessage(id, e));
  wv.addEventListener("page-title-updated", () => { /* could index here later */ });
  if (current === id) wv.classList.add("show");
  return wv;
}

function onWebviewMessage(id, e) {
  const p = providers.find((x) => x.id === id);
  if (e.channel === "reply") {
    const d = e.args[0] || {};
    const viewing = current === id && document.hasFocus();
    addNotification(id, (p ? p.name : "AI"), d.preview || "Your answer is ready.");
    if (!viewing) {
      unread[id] = (unread[id] || 0) + 1; updateBadges();
      window.api.notify({ title: `${p ? p.name : "AI"} replied`, body: d.preview || "Your answer is ready.", providerId: id });
      playChime();
    }
  } else if (e.channel === "media") {
    const d = e.args[0] || {};
    window.api.saveMedia({ dataURL: d.dataURL, name: d.name, role: d.role, providerName: p ? p.name : "Other" });
  } else if (e.channel === "profile") {
    const d = e.args[0] || {};
    if (d && (d.name || d.avatar)) setProfile(d);
  }
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
  const wv = ensureWebview(id);
  if (!wv) return;
  // 1) Best: navigate the AI to a URL that carries the prompt.
  if (PREFILL[id]) {
    const url = PREFILL[id](text);
    try { wv.loadURL(url); } catch (e) { wv.setAttribute("src", url); }
    return;
  }
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

// -------------------------------------------------------------- universal
document.getElementById("universal-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const prompt = document.getElementById("universal-input").value.trim();
  if (!prompt) return;
  const status = document.getElementById("universal-status");
  status.textContent = "Choosing the best AI…";
  let out;
  try {
    out = (await window.api.hasKey()) ? await window.api.route(prompt) : localRoute(prompt);
  } catch (err) {
    out = localRoute(prompt);   // API error → fall back to offline keyword routing
  }
  const p = providers.find((x) => x.id === out.provider) || providers[0];
  status.textContent = `Sent to ${p.name}${out.reason ? " — " + out.reason : ""}${out.local ? " (offline routing)" : ""}`;
  addRecent(prompt, p.id);
  select(p.id);
  deliver(p.id, prompt);
  document.getElementById("universal-input").value = "";
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

// Enter sends the prompt; Shift+Enter makes a new line.
document.getElementById("universal-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    document.getElementById("universal-form").requestSubmit();
  }
});

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
search.addEventListener("input", () => renderSearch());
search.addEventListener("focus", () => renderSearch());
search.addEventListener("blur", () => setTimeout(() => searchResults.classList.remove("show"), 150));
search.addEventListener("keydown", (e) => {
  if (!results.length) return;
  if (e.key === "ArrowDown") { selIdx = Math.min(selIdx + 1, results.length - 1); markSel(); e.preventDefault(); }
  else if (e.key === "ArrowUp") { selIdx = Math.max(selIdx - 1, 0); markSel(); e.preventDefault(); }
  else if (e.key === "Enter") { e.preventDefault(); results[selIdx] && results[selIdx].run(); }
  else if (e.key === "Escape") { searchResults.classList.remove("show"); search.blur(); }
});
function renderSearch() {
  const q = search.value.trim();
  results = [];
  if (q) {
    for (const p of providers) {
      if (p.name.toLowerCase().includes(q.toLowerCase()))
        results.push({ label: p.name, ai: "Open", run: () => { select(p.id); closeSearch(); } });
    }
    results.push({ label: `Ask Universal AI: “${q}”`, ai: "Route", run: () => { select("__universal__"); document.getElementById("universal-input").value = q; closeSearch(); document.getElementById("universal-form").requestSubmit(); } });
  }
  selIdx = 0;
  searchResults.innerHTML = results.map((r, i) =>
    `<div class="sr-item ${i === 0 ? "sel" : ""}" data-i="${i}"><div>${escapeHtml(r.label)}</div><div class="sr-ai" style="margin-left:auto">${r.ai}</div></div>`).join("");
  searchResults.querySelectorAll(".sr-item").forEach((el) => { el.onmousedown = (e) => { e.preventDefault(); results[+el.dataset.i].run(); }; });
  searchResults.classList.toggle("show", results.length > 0);
}
function markSel() { searchResults.querySelectorAll(".sr-item").forEach((el, i) => el.classList.toggle("sel", i === selIdx)); }
function closeSearch() { search.value = ""; searchResults.classList.remove("show"); search.blur(); }

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
  return `<div class="tile" data-path="${escapeAttr(m.path)}">${thumb}
    <div class="meta"><div class="name">${escapeHtml(m.name)}</div><div class="sub">${escapeHtml(m.folder)} · ${kb}</div></div></div>`;
}
document.getElementById("btn-media").onclick = () => select("__media__");
document.getElementById("media-folder").onclick = () => window.api.openMediaFolder();
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
  box.innerHTML = providers.map((p) =>
    `<div class="sp-row"><img src="${faviconFor(p)}" onerror="this.style.display='none'"/><span>${escapeHtml(p.name)}</span>` +
    (p.custom ? `<a href="#" class="sp-remove" data-id="${p.id}">Remove</a>` : "") + `</div>`).join("");
  box.querySelectorAll(".sp-remove").forEach((a) => a.onclick = async (e) => {
    e.preventDefault();
    await window.api.removeCustomAI(a.dataset.id);
    if (webviews[a.dataset.id]) { webviews[a.dataset.id].remove(); delete webviews[a.dataset.id]; }
    await loadProviders(await window.api.getState());
    buildRail(); buildSettingsProviders();
    if (current === a.dataset.id) select("__universal__");
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

  // Suggestions: things you can ask. Click one to drop it into Universal AI.
  const sl = document.getElementById("rb-sugg-list");
  sl.innerHTML = SUGGESTIONS.map((s, i) => `<div class="rb-item" data-i="${i}"><div class="rb-body">${escapeHtml(s)}</div></div>`).join("");
  sl.querySelectorAll(".rb-item").forEach((el) => el.onclick = () => {
    const s = SUGGESTIONS[+el.dataset.i]; if (!s) return;
    select("__universal__");
    const t = document.getElementById("universal-input");
    t.value = s; t.focus();
  });
}
// A rotating set of starter prompts (shuffled per launch so it feels fresh).
const SUGGESTION_POOL = [
  "Summarize this article: (paste a link)",
  "Write a Python script to rename files in a folder",
  "Generate an image of a city skyline at night",
  "Explain this error and how to fix it: (paste it)",
  "Draft a polite follow-up email to a client",
  "What's the latest news on (topic)?",
  "Build a simple landing page for my product",
  "Solve this step by step: (paste a math problem)",
  "Turn these notes into a clear summary",
  "Compare two options and recommend one",
  "Write unit tests for this function",
  "Plan a 3-day trip to (place)",
];
const SUGGESTIONS = SUGGESTION_POOL.slice().sort(() => Math.random() - 0.5).slice(0, 8);
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
