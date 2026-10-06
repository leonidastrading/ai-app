// UAI cloud sign-in + sync for the Windows app.
//
// Google sign-in uses the system browser with a loopback redirect (the standard
// desktop OAuth flow), exchanges the code for a Google ID token, signs in to
// Firebase (signInWithIdp), and keeps the Firebase refresh token (encrypted with
// safeStorage) so you stay signed in. Sync reads/writes users/{uid}.data in
// Firestore over REST — the same single-JSON-blob shape the web app uses.

const { shell, safeStorage, app } = require("electron");
const http = require("http");
const https = require("https");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { URL, URLSearchParams } = require("url");
// cloud-config.js is generated from CI secrets (and gitignored); fall back to
// the example template so a missing file degrades to a clear sign-in error
// instead of crashing the whole app at startup.
let CFG;
try { CFG = require("./cloud-config"); }
catch (e) { try { CFG = require("./cloud-config.example"); } catch (e2) { CFG = {}; } }
const CONFIGURED = CFG.googleClientId && !/^YOUR_/.test(CFG.googleClientId);

const TOKEN_FILE = () => path.join(app.getPath("userData"), "uai-auth.bin");

let session = null; // { uid, idToken, refreshToken, email, name, photo, expiresAt }

// ---- small HTTPS JSON helper ----
function request(urlStr, { method = "GET", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(urlStr);
    const data = body == null ? null : (typeof body === "string" ? body : JSON.stringify(body));
    const req = https.request(
      { method, hostname: u.hostname, path: u.pathname + u.search, headers },
      (res) => {
        let buf = "";
        res.on("data", (c) => (buf += c));
        res.on("end", () => {
          let json = null;
          try { json = buf ? JSON.parse(buf) : null; } catch (e) {}
          if (res.statusCode >= 200 && res.statusCode < 300) resolve({ status: res.statusCode, json, raw: buf });
          else reject(new Error((json && json.error && (json.error.message || json.error)) || ("HTTP " + res.statusCode + ": " + buf)));
        });
      }
    );
    req.on("error", reject);
    if (data) req.write(data);
    req.end();
  });
}
function form(obj) { return new URLSearchParams(obj).toString(); }
const b64url = (b) => b.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// ---- persistence of the Firebase refresh token ----
function saveRefresh(token) {
  try {
    const bytes = safeStorage.isEncryptionAvailable()
      ? safeStorage.encryptString(token)
      : Buffer.from("plain:" + token, "utf8");
    fs.writeFileSync(TOKEN_FILE(), bytes);
  } catch (e) {}
}
function loadRefresh() {
  try {
    const bytes = fs.readFileSync(TOKEN_FILE());
    if (bytes.slice(0, 6).toString() === "plain:") return bytes.slice(6).toString("utf8");
    return safeStorage.decryptString(bytes);
  } catch (e) { return null; }
}
function clearRefresh() { try { fs.unlinkSync(TOKEN_FILE()); } catch (e) {} }

// ---- Firebase token exchange / refresh ----
async function firebaseSignInWithGoogleIdToken(googleIdToken) {
  const r = await request(
    "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=" + CFG.firebaseApiKey,
    { method: "POST", headers: { "Content-Type": "application/json" },
      body: { postBody: "id_token=" + googleIdToken + "&providerId=google.com", requestUri: "http://localhost", returnSecureToken: true } }
  );
  const j = r.json;
  session = {
    uid: j.localId, idToken: j.idToken, refreshToken: j.refreshToken,
    email: j.email || "", name: j.displayName || "", photo: j.photoUrl || "",
    expiresAt: Date.now() + (parseInt(j.expiresIn || "3600", 10) - 60) * 1000,
  };
  saveRefresh(j.refreshToken);
  return publicSession();
}
async function refreshToken() {
  const rt = (session && session.refreshToken) || loadRefresh();
  if (!rt) return null;
  const r = await request(
    "https://securetoken.googleapis.com/v1/token?key=" + CFG.firebaseApiKey,
    { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form({ grant_type: "refresh_token", refresh_token: rt }) }
  );
  const j = r.json;
  session = Object.assign(session || {}, {
    uid: j.user_id, idToken: j.id_token, refreshToken: j.refresh_token,
    expiresAt: Date.now() + (parseInt(j.expires_in || "3600", 10) - 60) * 1000,
  });
  saveRefresh(j.refresh_token);
  return session.idToken;
}
async function validToken() {
  if (session && session.idToken && Date.now() < session.expiresAt) return session.idToken;
  return refreshToken();
}
function publicSession() {
  return session ? { uid: session.uid, email: session.email, name: session.name, photo: session.photo } : null;
}

// ---- interactive Google sign-in via loopback ----
function signIn() {
  return new Promise((resolve, reject) => {
    if (!CONFIGURED) { reject(new Error("Sign-in isn't configured in this build. Please reinstall the latest UAI.")); return; }
    const verifier = b64url(crypto.randomBytes(32));
    const challenge = b64url(crypto.createHash("sha256").update(verifier).digest());
    const state = b64url(crypto.randomBytes(16));

    // Captured once the server is listening. Must be read BEFORE server.close(),
    // because server.address() returns null after the server is closed (Node 20),
    // which caused "Cannot read properties of null (reading 'port')".
    let boundPort = null;

    const server = http.createServer(async (req, res) => {
      try {
        const u = new URL(req.url, "http://127.0.0.1");
        if (!u.searchParams.get("code") && !u.searchParams.get("error")) { res.end(); return; }
        res.writeHead(200, { "Content-Type": "text/html" });
        res.end("<!doctype html><meta charset=utf-8><title>UAI</title><body style='font:16px system-ui;background:#0b0b14;color:#e7e9ee;display:flex;height:100vh;align-items:center;justify-content:center'><div style='text-align:center'><h2>You're signed in to UAI</h2><p>You can close this tab and return to the app.</p></div>");
        server.close();
        if (u.searchParams.get("error")) return reject(new Error(u.searchParams.get("error")));
        if (u.searchParams.get("state") !== state) return reject(new Error("State mismatch"));
        const code = u.searchParams.get("code");
        const port = boundPort;
        const tok = await request("https://oauth2.googleapis.com/token", {
          method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: form({
            code, client_id: CFG.googleClientId, client_secret: CFG.googleClientSecret,
            redirect_uri: "http://127.0.0.1:" + port, grant_type: "authorization_code", code_verifier: verifier,
          }),
        });
        if (!tok.json || !tok.json.id_token) return reject(new Error("No Google ID token"));
        resolve(await firebaseSignInWithGoogleIdToken(tok.json.id_token));
      } catch (e) { reject(e); }
    });

    server.listen(0, "127.0.0.1", () => {
      boundPort = server.address().port;
      const port = boundPort;
      const authUrl = "https://accounts.google.com/o/oauth2/v2/auth?" + form({
        client_id: CFG.googleClientId, redirect_uri: "http://127.0.0.1:" + port,
        response_type: "code", scope: "openid email profile",
        code_challenge: challenge, code_challenge_method: "S256", state, prompt: "select_account",
      });
      shell.openExternal(authUrl);
    });
    server.on("error", reject);
    setTimeout(() => { try { server.close(); } catch (e) {} reject(new Error("Sign-in timed out")); }, 300000);
  });
}

async function restore() {
  if (!loadRefresh()) return null;
  try { await refreshToken(); return publicSession(); } catch (e) { return null; }
}
function signOut() { session = null; clearRefresh(); }

// ---- Firestore REST (single JSON blob in users/{uid}.data) ----
function docUrl(uid) {
  return "https://firestore.googleapis.com/v1/projects/" + CFG.projectId + "/databases/(default)/documents/users/" + uid;
}
async function pull() {
  const token = await validToken();
  if (!token || !session) return {};
  try {
    const r = await request(docUrl(session.uid), { headers: { Authorization: "Bearer " + token } });
    const s = r.json && r.json.fields && r.json.fields.data && r.json.fields.data.stringValue;
    return s ? (JSON.parse(s) || {}) : {};
  } catch (e) { return {}; }   // 404 = no doc yet
}
async function push(blob) {
  const token = await validToken();
  if (!token || !session) return false;
  const url = docUrl(session.uid) + "?updateMask.fieldPaths=data&updateMask.fieldPaths=updatedAt";
  const body = { fields: { data: { stringValue: JSON.stringify(blob || {}) }, updatedAt: { timestampValue: new Date().toISOString() } } };
  try {
    await request(url, { method: "PATCH", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token }, body });
    return true;
  } catch (e) { return false; }
}

// Recents live in their own `recents` field (falling back to the old in-blob
// location) so data-blob writes never clobber them.
async function pullRecents() {
  const token = await validToken();
  if (!token || !session) return [];
  try {
    const r = await request(docUrl(session.uid), { headers: { Authorization: "Bearer " + token } });
    const f = (r.json && r.json.fields) || {};
    // Union the new `recents` field AND the old in-blob location (migration-safe).
    let out = [];
    try { if (f.recents && f.recents.stringValue) { const a = JSON.parse(f.recents.stringValue); if (Array.isArray(a)) out = out.concat(a); } } catch (e) {}
    try { if (f.data && f.data.stringValue) { const b = JSON.parse(f.data.stringValue); if (Array.isArray(b.recents)) out = out.concat(b.recents); } } catch (e) {}
    return out;
  } catch (e) { return []; }
}
async function pushRecents(arr) {
  const token = await validToken();
  if (!token || !session) return false;
  const url = docUrl(session.uid) + "?updateMask.fieldPaths=recents&updateMask.fieldPaths=updatedAt";
  const body = { fields: { recents: { stringValue: JSON.stringify(Array.isArray(arr) ? arr : []) }, updatedAt: { timestampValue: new Date().toISOString() } } };
  try {
    await request(url, { method: "PATCH", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token }, body });
    return true;
  } catch (e) { return false; }
}

module.exports = { signIn, signOut, restore, current: publicSession, pull, push, pullRecents, pushRecents };
