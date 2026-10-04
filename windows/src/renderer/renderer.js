"use strict";

const paneWebviews = document.getElementById("pane-webviews");
const railProviders = document.getElementById("rail-providers");

let providers = [];        // ordered list of provider objects
let current = "__universal__";
const webviews = {};       // id -> <webview>
const unread = {};         // id -> count
let recents = [];

// -------------------------------------------------------------- startup
async function boot() {
  const state = await window.api.getState();
  recents = state.universalRecents || [];
  await loadProviders(state);
  buildRail();
  renderRecents();
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
    ensureWebview(id);
    unread[id] = 0; updateBadges();
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
  wv.setAttribute("partition", "persist:" + id);
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
    const viewing = current === id && document.hasFocus();
    if (!viewing) {
      unread[id] = (unread[id] || 0) + 1; updateBadges();
      const d = e.args[0] || {};
      window.api.notify({ title: `${p ? p.name : "AI"} replied`, body: d.preview || "Your answer is ready.", providerId: id });
    }
  } else if (e.channel === "media") {
    const d = e.args[0] || {};
    window.api.saveMedia({ dataURL: d.dataURL, name: d.name, role: d.role, providerName: p ? p.name : "Other" });
  }
}

function deliver(id, text) {
  const wv = ensureWebview(id);
  if (!wv) return;
  const run = () => wv.executeJavaScript(deliverScript(text)).catch(() => {});
  if (wv.isLoading && wv.isLoading()) wv.addEventListener("dom-ready", run, { once: true });
  else { run(); setTimeout(run, 1200); }
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
  if (!(await window.api.hasKey())) {
    status.innerHTML = `Add an Anthropic API key in <a href="#" id="go-settings">Settings</a> to use routing — or click an AI on the left.`;
    document.getElementById("go-settings").onclick = () => select("__settings__");
    return;
  }
  status.textContent = "Choosing the best AI…";
  try {
    const out = await window.api.route(prompt);
    const p = providers.find((x) => x.id === out.provider) || providers[0];
    status.textContent = `Sent to ${p.name}${out.reason ? " — " + out.reason : ""}`;
    addRecent(prompt, p.id);
    select(p.id);
    deliver(p.id, prompt);
    document.getElementById("universal-input").value = "";
  } catch (err) {
    status.textContent = "Routing failed: " + (err && err.message ? err.message : err);
  }
});

function addRecent(text, providerId) {
  recents.unshift({ text, providerId, at: Date.now() });
  recents = recents.slice(0, 12);
  window.api.setState({ universalRecents: recents });
  renderRecents();
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
function tileHtml(m) {
  const thumb = m.kind === "image"
    ? `<div class="thumb" style="background-image:url('file://${encodeURI(m.path).replace(/'/g, "%27")}')"></div>`
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
document.getElementById("btn-settings").onclick = () => select("__settings__");
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
