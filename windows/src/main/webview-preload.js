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
  captureSends();
}

// Report prompts you send in any AI, so UAI can list recent prompts across
// all of them. Captured on Enter (before the box clears) and on send clicks.
function captureSends() {
  const textOf = (el) => (el ? (el.value || el.innerText || "").trim() : "");
  const isBox = (el) => el && (el.tagName === "TEXTAREA" || el.isContentEditable || (el.getAttribute && el.getAttribute("role") === "textbox"));
  const report = (text) => { if (text && text.length <= 2000) ipcRenderer.sendToHost("prompt", { text }); };
  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && isBox(document.activeElement)) report(textOf(document.activeElement));
  }, true);
  document.addEventListener("click", (e) => {
    const btn = e.target.closest && e.target.closest('button,[role="button"]');
    if (!btn) return;
    const label = ((btn.getAttribute("aria-label") || "") + " " + (btn.title || "") + " " + (btn.textContent || "")).toLowerCase();
    if (/\bsend\b|submit/.test(label)) {
      const box = [...document.querySelectorAll('textarea,[contenteditable="true"],div[role="textbox"]')].find((b) => textOf(b));
      report(textOf(box));
    }
  }, true);
}

// (Google profile auto-detect was removed — it grabbed the wrong account and
//  photo. The profile name + photo are set manually in Settings instead.)

// ---- reply detection -------------------------------------------------
function replyWatcher() {
  // Detect a finished reply by watching the reply text stop growing, not only
  // by the site's "Stop" button (which sites keep changing). Guards against a
  // single big jump (opening an existing chat) and dedupes repeats.
  const stopSel = [
    'button[aria-label*="Stop" i]', 'button[data-testid*="stop" i]',
    '[role="button"][aria-label*="Stop" i]', 'button[title*="Stop" i]',
    'button[aria-label*="generating" i]', '[data-testid="stop-button"]',
  ].join(",");
  // Known containers first, then broad class-name conventions so sites we don't
  // special-case (e.g. Muse) are still covered.
  const replySel = [
    '[data-message-author-role="assistant"]', ".font-claude-response", ".font-claude-message",
    "model-response", ".model-response-text", ".ds-markdown", '[data-testid="assistant-message"]',
    '[data-testid="markdown"]', ".message-bubble", ".markdown", ".prose",
    '[class*="assistant" i]', '[class*="message" i]', '[class*="response" i]', '[class*="bubble" i]',
  ].join(",");
  const measure = () => {
    const els = document.querySelectorAll(replySel);
    let total = 0;                         // textContent: cheap, no reflow
    for (const e of els) total += (e.textContent || "").length;
    return { total, count: els.length, lastEl: els.length ? els[els.length - 1] : null };
  };
  let lastFired = "";
  const fire = (m) => {
    const preview = ((m.lastEl && m.lastEl.innerText) || "").replace(/\s+/g, " ").trim().slice(0, 220);
    if (preview && preview !== lastFired) {
      lastFired = preview;
      ipcRenderer.sendToHost("reply", { title: document.title, preview });
    }
  };
  // Two independent signals:
  //  1) Stop button (definitive): it shows while generating; when it goes away
  //     the reply is done — fire ~1.5s later, no matter what else changes on the
  //     page. This is the reliable path for ChatGPT/Claude/Gemini/Grok.
  //  2) Text growth (fallback): for sites with no recognizable stop button, fire
  //     when the reply text has grown and then held steady. Only runs when no
  //     stop button is involved, so busy pages can't block the stop path.
  let stopBusy = false, stopGone = 0;
  let lastTotal = -1, lastCount = -1, grow = 0, growActive = false, growSince = 0;
  setInterval(() => {
    const now = Date.now();
    const stop = [...document.querySelectorAll(stopSel)].find((b) => {
      const label = (b.getAttribute("aria-label") || b.title || "").toLowerCase();
      return b.offsetParent !== null && !label.includes("record") && !label.includes("dictat");
    });
    const m = measure();

    if (stop) { stopBusy = true; stopGone = 0; }
    else if (stopBusy) {
      if (!stopGone) stopGone = now;
      if (now - stopGone > 1500) {
        stopBusy = false; stopGone = 0; grow = 0; growActive = false;
        lastTotal = m.total; lastCount = m.count;
        fire(m);
        return;
      }
    }

    if (lastTotal < 0) { lastTotal = m.total; lastCount = m.count; return; }
    if (!stop && !stopBusy) {
      const grew = m.total > lastTotal || m.count > lastCount;
      if (grew) { grow++; growSince = now; if (grow >= 3) growActive = true; }
      else grow = 0;
      if (growActive && now - growSince > 3000) { growActive = false; grow = 0; fire(m); }
    } else {
      grow = 0; growActive = false;   // the stop-button path owns this cycle
    }
    lastTotal = m.total; lastCount = m.count;
  }, 700);
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
