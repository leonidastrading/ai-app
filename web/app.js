"use strict";

const BUILTIN = window.UAI_PROVIDERS;
const HEURISTICS = window.UAI_HEURISTICS;

function custom() { try { return JSON.parse(localStorage.getItem("uai.custom") || "[]"); } catch (e) { return []; } }
function saveCustom(list) {
  localStorage.setItem("uai.custom", JSON.stringify(list));
  try { window.UAI_sync && window.UAI_sync.push(); } catch (e) {}   // sync to the cloud
}
function allProviders() {
  return BUILTIN.concat(custom().map((c) => ({
    id: c.id, name: c.name, maker: hostOf(c.url), home: c.url, tint: "#8a6ddc", custom: true,
    prefill: null, strengths: c.strengths || "",
  })));
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
  for (const p of allProviders()) {
    const el = document.createElement("button");
    el.className = "card";
    el.innerHTML = `<span class="ic" style="--ring:${p.tint}"><img src="${favicon(p)}" alt="" onerror="this.style.display='none'"></span>
      <span class="nm">${esc(p.name)}</span><span class="mk">${esc(p.maker || "")}</span>`;
    el.onclick = () => openProvider(p, document.getElementById("ask").value.trim() || null);
    grid.appendChild(el);
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

// settings dialog
const dlg = document.getElementById("settings");
document.getElementById("settings-btn").onclick = () => { renderCustomList(); dlg.showModal(); };
document.getElementById("add-btn").onclick = () => {
  const name = document.getElementById("add-name").value.trim();
  let url = document.getElementById("add-url").value.trim();
  if (!name || !url) return;
  if (!/^https?:\/\//i.test(url)) url = "https://" + url;
  const list = custom(); list.push({ id: "c-" + Date.now().toString(36), name, url, strengths: "" });
  saveCustom(list);
  document.getElementById("add-name").value = ""; document.getElementById("add-url").value = "";
  renderCustomList(); renderGrid();
};
function renderCustomList() {
  const box = document.getElementById("custom-list");
  const list = custom();
  box.innerHTML = list.length ? list.map((c) => `<div class="cl-row"><span>${esc(c.name)}</span><span class="muted">${esc(hostOf(c.url))}</span><span class="x" data-id="${c.id}">Remove</span></div>`).join("") : "";
  box.querySelectorAll(".x").forEach((x) => x.onclick = () => { saveCustom(custom().filter((c) => c.id !== x.dataset.id)); renderCustomList(); renderGrid(); });
}

function toast(msg) {
  const t = document.getElementById("toast");
  t.textContent = msg; t.classList.add("show");
  clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.remove("show"), 2600);
}
function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }

document.getElementById("note").innerHTML =
  "This is the web launcher. Browsers block embedding your logged-in AI sites, so UAI opens each one in a new tab with your question pre-filled where the AI supports it (Claude, ChatGPT, xAI, v0). For the rest — and if a link opens the AI’s desktop app, which drops the pre-fill — your prompt is copied to the clipboard: just press ⌘/Ctrl+V. For the full in-app experience (each AI embedded, shared media, notifications), use the macOS or Windows app.";

renderGrid();

// Let the sync layer refresh the UI when cloud data arrives.
window.UAI_rerender = function () { renderGrid(); try { renderCustomList(); } catch (e) {} };
