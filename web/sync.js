"use strict";
// Google sign-in gate + cloud sync for the UAI web app.
// Stores all synced UAI data as a single JSON blob in users/{uid}.data, so the
// Mac and Windows apps (which talk to Firestore over REST) use the same shape.
// This client only manages the keys it knows (custom AIs); it preserves the
// rest of the blob so it never clobbers data the desktop apps wrote.

(function () {
  const cfg = window.UAI_FIREBASE || {};
  const configured = cfg.apiKey && !/^PASTE/.test(cfg.apiKey);

  // blob key -> localStorage key (the data this web client manages)
  const KEYS = { custom: "uai.custom", hidden: "uai.hidden" };
  let lastBlob = {};

  function rerender() { try { window.UAI_rerender && window.UAI_rerender(); } catch (e) {} }

  // Merge recent entries: dedupe, newest-first, bounded, and keep image
  // thumbnails only for the newest few so the synced blob stays small.
  function mergeRecents(list) {
    const seen = new Set(); const out = [];
    for (const r of list) {
      if (!r || typeof r !== "object") continue;
      const key = (r.providerId || "") + "|" + (r.at || 0) + "|" + String(r.text || "").slice(0, 60);
      if (seen.has(key)) continue;
      seen.add(key); out.push(r);
    }
    out.sort((a, b) => (b.at || 0) - (a.at || 0));
    const capped = out.slice(0, 80);
    capped.forEach((r, i) => {
      // Beyond the newest few, drop the inline preview thumbnail but keep the
      // Storage URL so the file can still be opened/downloaded.
      if (i >= 12 && Array.isArray(r.attachments)) r.attachments = r.attachments.map((a) => ({ name: a.name, type: a.type, url: a.url }));
    });
    return capped;
  }
  // Add an entry to Recent locally (works signed out too; syncs when able).
  function localAddRecent(entry) {
    window.UAI_recents = mergeRecents([entry].concat(window.UAI_recents || []));
    window.UAI_recentsJSON = JSON.stringify(window.UAI_recents);
    rerender();
  }

  if (!configured || !window.firebase) {
    window.UAI_sync = { push() {}, addRecent: localAddRecent, configured: false };
    return;
  }

  let auth, db;
  try {
    firebase.initializeApp(cfg);
    auth = firebase.auth();
    db = firebase.firestore();
  } catch (e) {
    window.UAI_sync = { push() {}, addRecent: localAddRecent, configured: false };   // don't trap behind a dead gate
    return;
  }
  let docRef = null, applyingRemote = false;

  // ---- sign-in gate ----
  const gate = document.createElement("div");
  gate.id = "auth-gate";
  gate.innerHTML =
    '<div class="auth-card">' +
    '  <div class="galaxy big" aria-hidden="true"></div>' +
    "  <h1>UAI</h1>" +
    "  <p>Sign in with Google to sync your AIs and settings across the Mac, Windows and web apps.</p>" +
    '  <button id="google-signin" class="primary">Sign in with Google</button>' +
    '  <p class="auth-err" id="auth-err"></p>' +
    "</div>";
  document.body.appendChild(gate);
  try { window.UAIGalaxy && UAIGalaxy.mountAll(".galaxy"); } catch (e) {}
  document.documentElement.classList.add("signed-out");
  document.getElementById("google-signin").onclick = function () {
    auth.signInWithPopup(new firebase.auth.GoogleAuthProvider()).catch(function (e) {
      document.getElementById("auth-err").textContent = e && e.message ? e.message : "Sign-in failed.";
    });
  };

  function mountAccountChip(user) {
    if (document.getElementById("acct-chip")) return;
    const bar = document.querySelector(".topbar");
    if (!bar) return;
    const chip = document.createElement("div");
    chip.id = "acct-chip";
    chip.className = "acct-chip";
    const photo = user.photoURL ? '<img src="' + user.photoURL + '" alt="">' : "";
    chip.innerHTML = photo + "<span>" + (user.displayName || user.email || "Account") + "</span>" +
      '<button id="signout" class="ghost small">Sign out</button>';
    bar.appendChild(chip);
    document.getElementById("signout").onclick = function () { auth.signOut(); };
  }

  function applyBlob(blob) {
    applyingRemote = true;
    try {
      let changed = false;
      for (const k in KEYS) {
        if (blob && blob[k] != null) {
          const next = JSON.stringify(blob[k]);
          if (localStorage.getItem(KEYS[k]) !== next) { localStorage.setItem(KEYS[k], next); changed = true; }
        }
      }
      if (changed) rerender();
    } catch (e) {} finally { applyingRemote = false; }
  }

  // Recents live in their OWN Firestore field, so custom-AI / hide / memory
  // writes can never clobber them. Merge remote with anything added locally.
  function applyRecents(remoteRecents) {
    const mergedRecents = mergeRecents((Array.isArray(remoteRecents) ? remoteRecents : []).concat(window.UAI_recents || []));
    const recentsNext = JSON.stringify(mergedRecents);
    if (window.UAI_recentsJSON !== recentsNext) { window.UAI_recentsJSON = recentsNext; window.UAI_recents = mergedRecents; rerender(); }
  }

  // Writes ONLY the data field (custom/hidden/…) — never touches recents.
  function push() {
    if (!docRef || applyingRemote) return;
    const blob = Object.assign({}, lastBlob);
    for (const k in KEYS) {
      try { const v = JSON.parse(localStorage.getItem(KEYS[k]) || "null"); if (v != null) blob[k] = v; } catch (e) {}
    }
    docRef.set({ data: JSON.stringify(blob), updatedAt: firebase.firestore.FieldValue.serverTimestamp() }, { merge: true })
      .catch(function () {});
  }

  // Writes ONLY the recents field. Uses a transaction so a concurrent write
  // (another device) is merged, never overwritten.
  function pushRecents() {
    if (!docRef) return;
    const local = window.UAI_recents || [];
    db.runTransaction(function (tx) {
      return tx.get(docRef).then(function (snap) {
        let remote = [];
        try { remote = JSON.parse((snap.exists && snap.data().recents) || "[]") || []; } catch (e) {}
        const merged = mergeRecents(local.concat(remote));
        window.UAI_recents = merged; window.UAI_recentsJSON = JSON.stringify(merged);
        tx.set(docRef, { recents: JSON.stringify(merged), updatedAt: firebase.firestore.FieldValue.serverTimestamp() }, { merge: true });
      });
    }).catch(function () {
      // Fallback: plain write so a prompt is never lost if the transaction fails.
      try {
        docRef.set({ recents: JSON.stringify(window.UAI_recents || []), updatedAt: firebase.firestore.FieldValue.serverTimestamp() }, { merge: true }).catch(function () {});
      } catch (e) {}
    });
  }

  // Add an entry to Recent and sync it so it shows on every signed-in device.
  function addRecent(entry) {
    localAddRecent(entry);   // update local UI immediately
    pushRecents();
  }

  window.UAI_sync = { push: push, addRecent: addRecent, configured: true };

  auth.onAuthStateChanged(function (user) {
    if (!user) { document.documentElement.classList.add("signed-out"); docRef = null; return; }
    document.documentElement.classList.remove("signed-out");
    mountAccountChip(user);
    docRef = db.collection("users").doc(user.uid);
    docRef.onSnapshot(function (snap) {
      if (snap.exists) {
        const d = snap.data() || {};
        let blob = {};
        try { blob = JSON.parse(d.data || "{}") || {}; } catch (e) {}
        lastBlob = blob;
        applyBlob(blob);
        // Recents from their own field, falling back to the old in-blob location.
        let remoteRecents = null;
        try { remoteRecents = d.recents != null ? JSON.parse(d.recents) : (Array.isArray(blob.recents) ? blob.recents : null); } catch (e) {}
        applyRecents(remoteRecents || []);
      } else { lastBlob = {}; push(); }
    }, function () {});
  });
})();
