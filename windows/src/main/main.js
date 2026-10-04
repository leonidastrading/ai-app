const { app, BrowserWindow, ipcMain, shell, Notification, session, safeStorage, nativeImage } = require("electron");
const path = require("path");
const fs = require("fs");
const https = require("https");
const { BUILTIN, IDENTITY_HOSTS, hostMatches } = require("../shared/providers");

const USER_DIR = app.getPath("userData");
const STATE_FILE = path.join(USER_DIR, "state.json");
const KEY_FILE = path.join(USER_DIR, "apikey.bin");
const MEDIA_DIR = path.join(app.getPath("documents"), "UAI Media");
const SCREENSHOT_DIR = path.join(MEDIA_DIR, "Screenshots");

app.setAppUserModelId("com.leonidastrading.uai"); // required for Windows notifications

// ---------------------------------------------------------------- state
function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")); } catch (e) { return {}; }
}
function saveState(patch) {
  const s = Object.assign(loadState(), patch);
  try { fs.mkdirSync(USER_DIR, { recursive: true }); fs.writeFileSync(STATE_FILE, JSON.stringify(s, null, 2)); } catch (e) {}
  return s;
}

function allProviders() {
  const custom = (loadState().customProviders || []).map((c) => ({
    id: c.id, name: c.name, maker: (() => { try { return new URL(c.url).host.replace(/^www\./, ""); } catch (e) { return ""; } })(),
    home: c.url, tint: c.tint || "#f173ad", strengths: c.strengths || "", hosts: (() => {
      try { return [new URL(c.url).host.replace(/^www\./, "")]; } catch (e) { return []; }
    })(), custom: true,
  }));
  return BUILTIN.concat(custom);
}

// All hosts that should stay inside UAI (any AI's own site + identity providers).
function inAppHosts() {
  const hs = [];
  for (const p of allProviders()) hs.push(...(p.hosts || []));
  return hs.concat(IDENTITY_HOSTS);
}

// ---------------------------------------------------------------- api key
function saveKey(key) {
  try {
    if (!key) { fs.rmSync(KEY_FILE, { force: true }); return true; }
    const buf = safeStorage.isEncryptionAvailable()
      ? safeStorage.encryptString(key)
      : Buffer.from("plain:" + key, "utf8");
    fs.mkdirSync(USER_DIR, { recursive: true });
    fs.writeFileSync(KEY_FILE, buf);
    return true;
  } catch (e) { return false; }
}
function readKey() {
  try {
    const buf = fs.readFileSync(KEY_FILE);
    if (buf.slice(0, 6).toString() === "plain:") return buf.slice(6).toString("utf8");
    return safeStorage.decryptString(buf);
  } catch (e) { return ""; }
}

// ---------------------------------------------------------------- anthropic
function anthropicStructured({ system, user, schema, effort = "low", maxTokens = 2048 }) {
  return new Promise((resolve, reject) => {
    const key = readKey();
    if (!key) return reject(new Error("Add an Anthropic API key in Settings first."));
    const payload = JSON.stringify({
      model: "claude-opus-5-5",
      max_tokens: maxTokens,
      system,
      messages: [{ role: "user", content: user }],
      output_config: { effort, format: { type: "json_schema", schema } },
      fallbacks: "default",
    });
    const req = https.request({
      hostname: "api.anthropic.com", path: "/v1/messages", method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "server-side-fallback-2026-07-01",
        "Content-Length": Buffer.byteLength(payload),
      },
    }, (res) => {
      let data = "";
      res.on("data", (d) => (data += d));
      res.on("end", () => {
        try {
          const json = JSON.parse(data);
          if (res.statusCode !== 200) return reject(new Error(json.error?.message || `API error ${res.statusCode}`));
          if (json.stop_reason === "refusal") return reject(new Error("Claude declined this request."));
          const block = (json.content || []).reverse().find((b) => b.type === "text");
          if (!block) return reject(new Error("Unexpected answer format"));
          resolve(JSON.parse(block.text));
        } catch (e) { reject(e); }
      });
    });
    req.on("error", reject);
    req.setTimeout(60000, () => req.destroy(new Error("Request timed out")));
    req.write(payload);
    req.end();
  });
}

// ---------------------------------------------------------------- window
let mainWindow;
function createWindow() {
  const b = loadState().bounds || {};
  mainWindow = new BrowserWindow({
    width: b.width || 1280, height: b.height || 860,
    x: b.x, y: b.y, minWidth: 900, minHeight: 600,
    backgroundColor: "#0f1115",
    title: "UAI",
    icon: path.join(__dirname, "../../assets/icon.ico"),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      webviewTag: true,
      contextIsolation: true,
      nodeIntegration: false,
      spellcheck: true,
    },
  });
  mainWindow.loadFile(path.join(__dirname, "../renderer/index.html"));

  const persist = () => { if (mainWindow && !mainWindow.isDestroyed()) saveState({ bounds: mainWindow.getBounds() }); };
  mainWindow.on("resize", persist);
  mainWindow.on("move", persist);
  mainWindow.on("close", persist);
}

// Open external links (anything that isn't an AI's own site or a sign-in page)
// in the user's default browser — mirrors the macOS behavior.
function isExternal(targetUrl) {
  try {
    const u = new URL(targetUrl);
    if (!/^https?:$/.test(u.protocol)) return false; // mailto:, etc. handled separately
    return !hostMatches(u.host, inAppHosts());
  } catch (e) { return false; }
}

app.on("web-contents-created", (_event, contents) => {
  contents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url) && isExternal(url)) { shell.openExternal(url); return { action: "deny" }; }
    if (!/^https?:|^about:/.test(url)) { shell.openExternal(url); return { action: "deny" }; }
    return { action: "allow" }; // sign-in popups / own-site tabs stay in-app
  });
  contents.on("will-navigate", (e, url) => {
    // Only redirect real top-level link clicks to external sites.
    if (contents.getType() === "webview" && isExternal(url)) {
      e.preventDefault();
      shell.openExternal(url);
    }
  });
});

// Save downloaded files into the Media folder so they show in the Media tab.
app.on("session-created", (s) => wireDownloads(s));
function wireDownloads(s) {
  s.on("will-download", (_e, item) => {
    try {
      fs.mkdirSync(MEDIA_DIR, { recursive: true });
      const name = item.getFilename() || "download";
      item.setSavePath(uniquePath(MEDIA_DIR, name));
      item.once("done", () => { if (mainWindow) mainWindow.webContents.send("media-changed"); });
    } catch (e) {}
  });
}

function uniquePath(dir, filename) {
  const safe = (filename || "download").replace(/[\\/:*?"<>|]/g, "-");
  let p = path.join(dir, safe);
  const ext = path.extname(safe);
  const stem = path.basename(safe, ext);
  let n = 2;
  while (fs.existsSync(p)) { p = path.join(dir, `${stem} ${n}${ext}`); n++; }
  return p;
}

// ---------------------------------------------------------------- IPC
ipcMain.handle("providers:list", () => allProviders());
ipcMain.handle("state:get", () => loadState());
ipcMain.handle("state:set", (_e, patch) => saveState(patch));

ipcMain.handle("customAI:add", (_e, c) => {
  const s = loadState();
  const list = s.customProviders || [];
  const id = "custom-" + Date.now().toString(36);
  list.push({ id, name: c.name, url: c.url, strengths: c.strengths || "" });
  saveState({ customProviders: list });
  return id;
});
ipcMain.handle("customAI:remove", (_e, id) => {
  const s = loadState();
  saveState({ customProviders: (s.customProviders || []).filter((c) => c.id !== id) });
  return true;
});

ipcMain.handle("apikey:has", () => !!readKey());
ipcMain.handle("apikey:set", (_e, key) => saveKey(key));

ipcMain.handle("route", async (_e, prompt) => {
  const providers = allProviders();
  const menu = providers.map((p) => `- ${p.id}: ${p.name} — ${p.strengths}`).join("\n");
  const schema = {
    type: "object",
    properties: {
      provider: { type: "string", enum: providers.map((p) => p.id) },
      reason: { type: "string" },
    },
    required: ["provider", "reason"],
    additionalProperties: false,
  };
  const out = await anthropicStructured({
    system: "You route a user's request to the single best AI assistant. Choose only from the list. Answer with JSON.",
    user: `AIs:\n${menu}\n\nRequest:\n${prompt}\n\nPick the best one.`,
    schema,
  });
  return out;
});

ipcMain.handle("notify", (_e, { title, body, providerId }) => {
  if (!Notification.isSupported()) return false;
  const n = new Notification({ title, body, silent: false });
  n.on("click", () => { if (mainWindow) { mainWindow.show(); mainWindow.webContents.send("open-provider", providerId); } });
  n.show();
  return true;
});

ipcMain.handle("media:list", () => listMedia());
ipcMain.handle("media:open", () => { shell.openPath(MEDIA_DIR); });
ipcMain.handle("media:reveal", (_e, p) => { shell.showItemInFolder(p); });
ipcMain.handle("media:openFile", (_e, p) => { shell.openPath(p); });
ipcMain.handle("media:clear", () => {
  try { for (const m of listMedia()) shell.trashItem(m.path); } catch (e) {}
  return listMedia();
});

// Save an image the page handed us (generated media, or a screenshot you added).
ipcMain.handle("media:save", (_e, { dataURL, name, role, providerName }) => {
  try {
    const m = /^data:([^;]+);base64,(.*)$/s.exec(dataURL || "");
    if (!m) return false;
    const buf = Buffer.from(m[2], "base64");
    if (buf.length < 12000) return false;
    const isShot = role === "user";
    const dir = isShot ? SCREENSHOT_DIR : path.join(MEDIA_DIR, providerName || "Other");
    fs.mkdirSync(dir, { recursive: true });
    const ext = (m[1].split("/")[1] || "png").replace("jpeg", "jpg").slice(0, 5);
    let base = (name || "image").replace(/[\\/:*?"<>|]/g, "-");
    if (!path.extname(base)) base += "." + ext;
    fs.writeFileSync(uniquePath(dir, base), buf);
    if (mainWindow) mainWindow.webContents.send("media-changed");
    return true;
  } catch (e) { return false; }
});

ipcMain.handle("open-external", (_e, url) => { if (url) shell.openExternal(url); });

function listMedia() {
  const out = [];
  const walk = (dir) => {
    let entries = [];
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
    for (const ent of entries) {
      const full = path.join(dir, ent.name);
      if (ent.isDirectory()) { walk(full); continue; }
      let st; try { st = fs.statSync(full); } catch (e) { continue; }
      const folder = path.basename(path.dirname(full));
      const ext = path.extname(ent.name).toLowerCase().slice(1);
      out.push({
        path: full, name: ent.name, folder,
        isScreenshot: folder === "Screenshots",
        kind: kindOf(ext), ext,
        size: st.size, created: st.birthtimeMs || st.ctimeMs,
      });
    }
  };
  walk(MEDIA_DIR);
  return out.sort((a, b) => b.created - a.created);
}
function kindOf(ext) {
  if (["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "heic"].includes(ext)) return "image";
  if (["mp4", "webm", "mov", "m4v", "avi", "mkv"].includes(ext)) return "video";
  if (["pdf", "txt", "md", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "csv", "rtf"].includes(ext)) return "document";
  return "other";
}

app.whenReady().then(() => {
  wireDownloads(session.defaultSession);
  createWindow();
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});
app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
