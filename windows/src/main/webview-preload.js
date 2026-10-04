// Runs inside each AI's web page. Talks back to the UAI shell with
// ipcRenderer.sendToHost(...). Mirrors the macOS injected scripts:
//  - detect when a reply finishes (the "Stop" button appears then goes away)
//  - capture generated images, and screenshots you attach, into Media
//  - put the cursor in the message box, and turn off OS autocorrect
const { ipcRenderer } = require("electron");

function start() {
  replyWatcher();
  mediaCapture();
  autofocus();
  noAutocorrect();
  profileScrape();
}

// On Google pages (Gemini signs you in with Google), read the account name and
// photo so UAI can show who's signed in. Only runs on *.google.com.
function profileScrape() {
  if (!/(^|\.)google\.com$/.test(location.hostname)) return;
  const sendIf = () => {
    let name = "", avatar = "";
    const btn = document.querySelector('[aria-label*="Google Account" i]');
    if (btn) {
      const label = (btn.getAttribute("aria-label") || "").replace(/Google Account[:]?/i, "").trim();
      name = (label.split(/[\n(]/)[0] || "").trim();
      const img = btn.querySelector("img");
      if (img) avatar = img.currentSrc || img.src || "";
    }
    if (!avatar) {
      const img = [...document.querySelectorAll('img[src*="googleusercontent.com"]')]
        .find((i) => { const w = i.naturalWidth || i.width; return w >= 24 && w <= 256; });
      if (img) avatar = img.currentSrc || img.src || "";
    }
    if (name || avatar) { ipcRenderer.sendToHost("profile", { name, avatar }); return true; }
    return false;
  };
  let tries = 0;
  const iv = setInterval(() => { if (sendIf() || ++tries > 20) clearInterval(iv); }, 1500);
}

// ---- reply detection -------------------------------------------------
function replyWatcher() {
  const stopSel = [
    'button[aria-label*="Stop" i]', 'button[data-testid*="stop" i]',
    '[role="button"][aria-label*="Stop" i]', 'button[title*="Stop" i]',
  ].join(",");
  const replySel = [
    '[data-message-author-role="assistant"]', ".font-claude-response", ".font-claude-message",
    "model-response", ".ds-markdown", '[data-testid="assistant-message"]', ".message-bubble",
  ].join(",");
  let busy = false, since = 0;
  setInterval(() => {
    const stop = [...document.querySelectorAll(stopSel)].find((b) => {
      const label = (b.getAttribute("aria-label") || b.title || "").toLowerCase();
      return b.offsetParent !== null && !label.includes("record") && !label.includes("dictat");
    });
    const now = Date.now();
    if (stop && !busy) { busy = true; since = now; return; }
    if (!stop && busy) {
      busy = false;
      if (now - since < 2000) return;
      const replies = document.querySelectorAll(replySel);
      const last = replies.length ? replies[replies.length - 1].innerText : "";
      ipcRenderer.sendToHost("reply", {
        title: document.title,
        preview: (last || "").replace(/\s+/g, " ").trim().slice(0, 220),
      });
    }
  }, 1000);
}

// ---- media + screenshots --------------------------------------------
function mediaCapture() {
  const seen = new Set();
  const skip = /avatar|favicon|logo|icon|emoji|profile|sprite|thumb_small|spinner|badge/i;
  const send = (name, dataURL, role) => ipcRenderer.sendToHost("media", { name, dataURL, role });

  const roleOf = (el) => {
    for (let n = el, i = 0; n && i < 14; n = n.parentElement, i++) {
      const r = (n.getAttribute && (n.getAttribute("data-message-author-role") || "")).toLowerCase();
      if (r === "user") return "user";
      if (r === "assistant" || r === "model") return "assistant";
      const cls = (n.className && typeof n.className === "string") ? n.className.toLowerCase() : "";
      if (/user-query|from-user|human-turn|user-message|query-content|request-/.test(cls)) return "user";
      if (/assistant|model-response|agent-|response-|markdown/.test(cls)) return "assistant";
    }
    return "assistant";
  };
  const viaCanvas = (img) => {
    try {
      const c = document.createElement("canvas");
      c.width = img.naturalWidth; c.height = img.naturalHeight;
      c.getContext("2d").drawImage(img, 0, 0);
      return c.toDataURL("image/png");
    } catch (e) { return null; }
  };
  const grab = async (src, name, role) => {
    const clone = new Image();
    clone.crossOrigin = "anonymous";
    let dataURL = await new Promise((res) => {
      clone.onload = () => res(viaCanvas(clone));
      clone.onerror = () => res(null);
      setTimeout(() => res(null), 6000);
      clone.src = src;
    });
    if (!dataURL) {
      for (const opts of [{}, { credentials: "include" }]) {
        try {
          const r = await fetch(src, opts); if (!r.ok) continue;
          const blob = await r.blob(); if (blob.size < 12000) return;
          dataURL = await new Promise((res, rej) => {
            const fr = new FileReader(); fr.onloadend = () => res(fr.result); fr.onerror = rej; fr.readAsDataURL(blob);
          });
          break;
        } catch (e) {}
      }
    }
    if (dataURL) send(name, dataURL, role);
  };

  let armed = false;
  const tryImg = (img) => {
    const src = img.currentSrc || img.src;
    if (!src || seen.has(src) || skip.test(src)) return;
    if (/^data:image\/(gif|svg)/.test(src)) return;
    const w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
    if (w < 256 || h < 256) return;
    seen.add(src);
    if (!armed) return;
    const name = (img.getAttribute("alt") || "").slice(0, 60);
    const role = roleOf(img);
    if (src.startsWith("data:image")) { send(name, src, role); return; }
    grab(src, name, role);
  };
  const watch = (node) => {
    if (node.tagName === "IMG") { (node.complete && node.naturalWidth) ? tryImg(node) : node.addEventListener("load", () => tryImg(node)); }
    if (node.querySelectorAll) node.querySelectorAll("img").forEach((i) => { (i.complete && i.naturalWidth) ? tryImg(i) : i.addEventListener("load", () => tryImg(i)); });
  };

  // Images you attach (paste / drag / file picker) → captured immediately.
  const sawFile = (file) => {
    if (!file || !/^image\//.test(file.type || "")) return;
    const key = "up:" + (file.name || "") + ":" + file.size;
    if (seen.has(key)) return; seen.add(key);
    const fr = new FileReader();
    fr.onload = () => send(file.name || "screenshot", fr.result, "user");
    fr.readAsDataURL(file);
  };
  document.addEventListener("paste", (e) => { for (const it of (e.clipboardData || {}).items || []) if (it.kind === "file") sawFile(it.getAsFile()); }, true);
  document.addEventListener("drop", (e) => { for (const f of ((e.dataTransfer || {}).files) || []) sawFile(f); }, true);
  document.addEventListener("change", (e) => {
    const t = e.target;
    if (t && t.tagName === "INPUT" && (t.type || "").toLowerCase() === "file" && t.files) for (const f of t.files) sawFile(f);
  }, true);

  watch(document);
  let pending = false;
  new MutationObserver(() => {
    if (pending) return; pending = true;
    setTimeout(() => { pending = false; watch(document); }, 800);
  }).observe(document.documentElement, { childList: true, subtree: true });
  setTimeout(() => { armed = true; }, 3500);
}

function autofocus() {
  const script = () => {
    const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 80 && r.height > 12 && el.offsetParent !== null && !el.disabled && !el.readOnly; };
    const boxes = [...document.querySelectorAll('textarea, [contenteditable="true"], div[role="textbox"]')].filter(vis);
    if (!boxes.length) return;
    boxes.sort((a, b) => b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom);
    boxes[0].focus();
  };
  [600, 1400, 2500].forEach((d) => setTimeout(script, d));
}

function noAutocorrect() {
  const fix = (el) => {
    if (!el || !el.setAttribute) return;
    const tag = el.tagName;
    if (tag === "TEXTAREA" || el.isContentEditable || (tag === "INPUT" && /^(text|search|email|url|)$/i.test(el.getAttribute("type") || ""))) {
      el.setAttribute("autocorrect", "off");
      el.setAttribute("autocapitalize", "off");
      if (!el.hasAttribute("spellcheck")) el.setAttribute("spellcheck", "true");
    }
  };
  const scan = () => { try { document.querySelectorAll("textarea, input, [contenteditable]").forEach(fix); } catch (e) {} };
  scan();
  let pending = false;
  new MutationObserver(() => { if (pending) return; pending = true; setTimeout(() => { pending = false; scan(); }, 600); })
    .observe(document.documentElement, { childList: true, subtree: true });
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
else start();
