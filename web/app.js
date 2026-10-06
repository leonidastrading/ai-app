"use strict";

const BUILTIN = window.UAI_PROVIDERS;
const HEURISTICS = window.UAI_HEURISTICS;

function custom() {
  try { const v = JSON.parse(localStorage.getItem("uai.custom") || "[]"); return Array.isArray(v) ? v : []; }
  catch (e) { return []; }
}
function saveCustom(list) {
  localStorage.setItem("uai.custom", JSON.stringify(list));
  try { window.UAI_sync && window.UAI_sync.push(); } catch (e) {}   // sync to the cloud
}
// Hidden AI ids (synced across apps via the shared blob's "hidden" key).
function hidden() {
  try { const v = JSON.parse(localStorage.getItem("uai.hidden") || "[]"); return Array.isArray(v) ? v : []; }
  catch (e) { return []; }
}
function saveHidden(list) {
  localStorage.setItem("uai.hidden", JSON.stringify(list));
  try { window.UAI_sync && window.UAI_sync.push(); } catch (e) {}
}
function toggleHidden(id) {
  const set = new Set(hidden());
  if (set.has(id)) set.delete(id); else set.add(id);
  saveHidden([...set]);
}
function allProviders() {
  return BUILTIN.concat(custom().map((c) => ({
    id: c.id, name: c.name, maker: hostOf(c.url), home: c.url, tint: "#8a6ddc", custom: true,
    prefill: null, strengths: c.strengths || "",
  })));
}
// Providers shown in the grid (hidden ones filtered out).
function visibleProviders() {
  const h = new Set(hidden());
  return allProviders().filter((p) => !h.has(p.id));
}
function hostOf(u) { try { return new URL(u).host.replace(/^www\./, ""); } catch (e) { return ""; } }
function favicon(p) { try { return `https://www.google.com/s2/favicons?sz=128&domain=${new URL(p.home).host}`; } catch (e) { return ""; } }
function byId(id) { return allProviders().find((p) => p.id === id); }

// ---------------------------------------------------------- open an AI
// Always copy the prompt to the clipboard FIRST (synchronously, inside the
// click), so the hand-off works no matter what opens — a browser tab, or the
// AI's desktop app (which ignores the web ?q= param). Where the site supports
// a query param we also pre-fill it so it types itself in.
function openProvider(p, prompt) {
  if (prompt) {
    copy(prompt);
    const url = p.prefill ? p.prefill(prompt) : p.home;
    toast(p.prefill ? `Opening ${p.name} — prompt copied as a backup` : `Prompt copied — press ⌘/Ctrl+V in ${p.name}`);
    window.open(url, "_blank", "noopener");
  } else {
    window.open(p.home, "_blank", "noopener");
  }
}
// Fire-and-forget clipboard write. Must be called while the click gesture is
// still active (i.e. before any await), or the browser rejects it.
function copy(text) { try { navigator.clipboard.writeText(text); } catch (e) {} }

// ---------------------------------------------------------- routing
async function route(prompt) {
  // Try the server (uses an Anthropic key if one is configured on Vercel).
  try {
    const r = await fetch("/api/route", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ prompt, providers: allProviders().map((p) => ({ id: p.id, name: p.name, strengths: p.strengths })) }),
    });
    if (r.ok) { const j = await r.json(); if (j.provider && byId(j.provider)) return j; }
  } catch (e) { /* fall through to local */ }
  return localRoute(prompt);
}

// Offline fallback: keyword heuristics over the provider strengths.
function localRoute(prompt) {
  for (const h of HEURISTICS) if (h.re.test(prompt) && byId(h.id)) return { provider: h.id, reason: "matched by keywords", local: true };
  // score by word overlap with strengths
  const words = new Set(prompt.toLowerCase().match(/[a-z]{4,}/g) || []);
  let best = allProviders()[0], score = -1;
  for (const p of allProviders()) {
    const s = (p.strengths || "").toLowerCase();
    let n = 0; for (const w of words) if (s.includes(w)) n++;
    if (n > score) { score = n; best = p; }
  }
  return { provider: best.id, reason: "best keyword match", local: true };
}

// ---------------------------------------------------------- UI
function renderGrid() {
  const grid = document.getElementById("grid");
  grid.innerHTML = "";
  for (const p of visibleProviders()) {
    const el = document.createElement("button");
    el.className = "card";
    el.innerHTML = `<span class="ic" style="--ring:${p.tint}"><img src="${favicon(p)}" alt="" onerror="this.style.display='none'"></span>
      <span class="nm">${esc(p.name)}</span><span class="mk">${esc(p.maker || "")}</span>`;
    el.onclick = () => openProvider(p, document.getElementById("ask").value.trim() || null);
    grid.appendChild(el);
  }
  // "Add an AI" card at the end of the grid.
  const add = document.createElement("button");
  add.className = "card card-add";
  add.innerHTML = `<span class="ic add-ic">+</span><span class="nm">Add an AI</span><span class="mk">Custom</span>`;
  add.onclick = () => { renderCustomList(); dlg.showModal(); };
  grid.appendChild(add);
  renderRecents();
}

// Recent prompts from all your apps (synced). Read-only here — click one to
// reopen that AI with the prompt.
// Exact timestamp, e.g. "Oct 5, 2026 at 7:11 PM" — matches the desktop apps.
function fmtWhen(ms) {
  if (!ms) return "";
  try {
    const d = new Date(ms);
    const date = d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
    const time = d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    return `${date} at ${time}`;
  } catch (e) { return ""; }
}
function renderRecents() {
  const wrap = document.getElementById("recents-wrap");
  const box = document.getElementById("recents");
  if (!wrap || !box) return;
  const list = Array.isArray(window.UAI_recents) ? window.UAI_recents : [];
  if (!list.length) { wrap.style.display = "none"; box.innerHTML = ""; return; }
  wrap.style.display = "";
  box.innerHTML = "";
  for (const r of list.slice(0, 20)) {
    const p = r.providerId ? byId(r.providerId) : null;
    // Entries sent to UAI (no provider) show the UAI galaxy mark, not a routed AI.
    const icon = p ? `<img src="${favicon(p)}" alt="" onerror="this.style.display='none'">` : `<img src="icon.png" alt="UAI">`;
    const atts = Array.isArray(r.attachments) ? r.attachments : [];
    const thumbs = atts.filter((a) => a && a.dataURL).slice(0, 4).map((a) => `<img class="rr-thumb" src="${a.dataURL}" alt="">`).join("");
    const nonImg = atts.filter((a) => a && !a.dataURL).length;
    const attLabel = nonImg ? `<span class="rr-attlabel">📎 ${nonImg} file${nonImg > 1 ? "s" : ""}</span>` : "";
    const meta = [p ? "Routed to " + esc(p.name) : "UAI", r.at ? esc(fmtWhen(r.at)) : ""].filter(Boolean).join(" · ");
    const row = document.createElement("button");
    row.className = "recent-row";
    row.innerHTML = `<span class="rr-ic">${icon}</span><span class="rr-main"><span class="rr-text">${esc(r.text)}</span><span class="rr-meta">${meta}</span></span>${thumbs ? `<span class="rr-thumbs">${thumbs}</span>` : ""}${attLabel}`;
    if (p) row.onclick = () => openProvider(p, r.text);
    box.appendChild(row);
  }
}

document.getElementById("ask-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const prompt = document.getElementById("ask").value.trim();
  const status = document.getElementById("status");
  const btn = document.getElementById("ask-btn");
  if (!prompt) return;
  // Copy NOW, while the click gesture is still active — routing is async and
  // would otherwise invalidate the clipboard permission.
  copy(prompt);
  btn.disabled = true; status.textContent = "Choosing the best AI…";
  try {
    const out = await route(prompt);
    const p = byId(out.provider);
    const url = p.prefill ? p.prefill(prompt) : p.home;
    window.open(url, "_blank", "noopener");
    const hint = p.prefill ? "" : " — your prompt is copied, press ⌘/Ctrl+V to paste";
    status.innerHTML = `Opened <strong>${esc(p.name)}</strong>${out.reason ? " — " + esc(out.reason) : ""}${out.local ? ' <span class="muted">(offline)</span>' : ""}${hint}`;
  } catch (err) {
    status.textContent = "Couldn’t route that. Pick an AI below (your prompt is copied).";
  } finally { btn.disabled = false; }
});

// ---------------------------------------------------------- attachments + Send to UAI
let askAttachments = []; // { name, type, dataURL? (thumbnail for images) }

function renderAskAttachments() {
  const box = document.getElementById("ask-attachments");
  if (!box) return;
  if (!askAttachments.length) { box.innerHTML = ""; box.style.display = "none"; return; }
  box.style.display = "";
  box.innerHTML = askAttachments.map((a, i) => {
    const thumb = a.dataURL ? `<img src="${a.dataURL}" alt="">` : `<span class="att-doc">📄</span>`;
    return `<span class="att-chip">${thumb}<span class="att-name">${esc(a.name)}</span><span class="att-x" data-i="${i}">✕</span></span>`;
  }).join("");
  box.querySelectorAll(".att-x").forEach((x) => x.onclick = () => { askAttachments.splice(+x.dataset.i, 1); renderAskAttachments(); });
}

// Downscale an image to a small JPEG data URL so it stays tiny in the synced blob.
function imageThumb(file, max = 320, quality = 0.7) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, max / Math.max(img.width, img.height));
      const w = Math.max(1, Math.round(img.width * scale)), h = Math.max(1, Math.round(img.height * scale));
      const c = document.createElement("canvas"); c.width = w; c.height = h;
      try { c.getContext("2d").drawImage(img, 0, 0, w, h); URL.revokeObjectURL(url); resolve(c.toDataURL("image/jpeg", quality)); }
      catch (e) { URL.revokeObjectURL(url); resolve(null); }
    };
    img.onerror = () => { URL.revokeObjectURL(url); resolve(null); };
    img.src = url;
  });
}
async function addAskFiles(fileList) {
  for (const f of fileList) {
    if (!f) continue;
    const att = { name: f.name || "file", type: f.type || "application/octet-stream" };
    if ((f.type || "").startsWith("image/")) { const t = await imageThumb(f); if (t) att.dataURL = t; }
    askAttachments.push(att);
    if (askAttachments.length >= 6) break; // keep it light
  }
  renderAskAttachments();
}
document.getElementById("attach-btn").onclick = () => document.getElementById("ask-file").click();
document.getElementById("ask-file").addEventListener("change", (e) => { addAskFiles(e.target.files); e.target.value = ""; });
document.getElementById("ask").addEventListener("paste", (e) => {
  const items = (e.clipboardData || {}).items || [];
  const files = []; for (const it of items) if (it.kind === "file") { const f = it.getAsFile(); if (f) files.push(f); }
  if (files.length) { e.preventDefault(); addAskFiles(files); }
});
// Drag-and-drop files onto the prompt box.
const askField = document.querySelector(".ask-field");
if (askField) {
  ["dragenter", "dragover"].forEach((ev) => askField.addEventListener(ev, (e) => {
    if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
    e.preventDefault(); e.stopPropagation(); askField.classList.add("drag");
  }));
  askField.addEventListener("dragleave", (e) => { if (!askField.contains(e.relatedTarget)) askField.classList.remove("drag"); });
  askField.addEventListener("drop", (e) => {
    e.preventDefault(); e.stopPropagation(); askField.classList.remove("drag");
    const files = (e.dataTransfer && e.dataTransfer.files) || [];
    if (files.length) addAskFiles(files);
  });
}

document.getElementById("send-uai-btn").onclick = () => {
  const text = document.getElementById("ask").value.trim();
  if (!text && !askAttachments.length) return;
  // "Send to UAI" is not routed to any AI — it's just saved to your Recent.
  const entry = {
    id: "r-" + Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
    text: text || "(attachment)",
    providerId: null,
    at: Date.now(),
    attachments: askAttachments.slice(),
  };
  try { window.UAI_sync && window.UAI_sync.addRecent && window.UAI_sync.addRecent(entry); } catch (e) {}
  document.getElementById("ask").value = "";
  askAttachments = []; renderAskAttachments();
  toast("Sent to UAI — saved to your Recent on every signed-in device");
};

// settings dialog
const dlg = document.getElementById("settings");
document.getElementById("settings-btn").onclick = () => { renderSettings(); dlg.showModal(); };
document.getElementById("add-btn").onclick = () => {
  const name = document.getElementById("add-name").value.trim();
  let url = document.getElementById("add-url").value.trim();
  const strengths = document.getElementById("add-strengths").value.trim();
  if (!name || !url) return;
  if (!/^https?:\/\//i.test(url)) url = "https://" + url;
  const list = custom(); list.push({ id: "c-" + Date.now().toString(36), name, url, strengths });
  saveCustom(list);
  document.getElementById("add-name").value = ""; document.getElementById("add-url").value = ""; document.getElementById("add-strengths").value = "";
  renderSettings(); renderGrid();
};

// Same starter set as the desktop apps' "Add an AI" suggestions.
const ADD_SUGGESTIONS = [
  { name: "Perplexity", url: "https://www.perplexity.ai/", strengths: "web research with sources" },
  { name: "Mistral", url: "https://chat.mistral.ai/", strengths: "fast open-weight chat" },
  { name: "Copilot", url: "https://copilot.microsoft.com/", strengths: "Microsoft Copilot" },
  { name: "Qwen", url: "https://chat.qwen.ai/", strengths: "multilingual, coding" },
  { name: "Kimi", url: "https://www.kimi.com/", strengths: "long-document analysis" },
  { name: "Midjourney", url: "https://www.midjourney.com/", strengths: "image generation" },
];
function renderSettings() { renderSuggestions(); renderProvidersList(); }
function renderSuggestions() {
  const box = document.getElementById("add-suggestions");
  if (!box) return;
  const existing = new Set(allProviders().map((p) => hostOf(p.home)));
  box.innerHTML = ADD_SUGGESTIONS.map((s, i) => {
    const have = existing.has(hostOf(s.url));
    return `<button type="button" class="sugg-chip${have ? " have" : ""}" data-i="${i}"${have ? " disabled" : ""}>${esc(s.name)}</button>`;
  }).join("");
  box.querySelectorAll(".sugg-chip:not([disabled])").forEach((b) => b.onclick = () => {
    const s = ADD_SUGGESTIONS[+b.dataset.i];
    document.getElementById("add-name").value = s.name;
    document.getElementById("add-url").value = s.url;
    document.getElementById("add-strengths").value = s.strengths;
  });
}
function renderProvidersList() {
  const box = document.getElementById("providers-list");
  if (!box) return;
  const h = new Set(hidden());
  box.innerHTML = allProviders().map((p) => {
    const hid = h.has(p.id);
    const rm = p.custom ? `<span class="x" data-rm="${p.id}">Remove</span>` : "";
    return `<div class="cl-row"><span class="cl-name">${esc(p.name)}</span><span class="muted">${esc(p.maker || hostOf(p.home))}</span>` +
      `<span class="cl-actions"><button type="button" class="tog${hid ? "" : " on"}" data-tog="${p.id}">${hid ? "Hidden" : "Shown"}</button>${rm}</span></div>`;
  }).join("");
  box.querySelectorAll("[data-tog]").forEach((b) => b.onclick = () => { toggleHidden(b.dataset.tog); renderProvidersList(); renderGrid(); });
  box.querySelectorAll("[data-rm]").forEach((x) => x.onclick = () => { saveCustom(custom().filter((c) => c.id !== x.dataset.rm)); renderProvidersList(); renderGrid(); });
}
function renderCustomList() { renderSettings(); }  // back-compat

function toast(msg) {
  const t = document.getElementById("toast");
  t.textContent = msg; t.classList.add("show");
  clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.remove("show"), 2600);
}
function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }

document.getElementById("note").innerHTML =
  "This is the web launcher. Browsers block embedding your logged-in AI sites, so UAI opens each one in a new tab with your question pre-filled where the AI supports it (Claude, ChatGPT, xAI, v0). For the rest — and if a link opens the AI’s desktop app, which drops the pre-fill — your prompt is copied to the clipboard: just press ⌘/Ctrl+V. For the full in-app experience (each AI embedded, shared media, notifications), use the macOS or Windows app.";

renderGrid();

// Mount the animated galaxy (same renderer as the desktop apps).
try { window.UAIGalaxy && UAIGalaxy.mountAll(".galaxy"); } catch (e) {}

// Let the sync layer refresh the UI when cloud data arrives.
window.UAI_rerender = function () { renderGrid(); try { renderCustomList(); } catch (e) {} };
