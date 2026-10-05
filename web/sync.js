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
  const KEYS = { custom: "uai.custom" };
  let lastBlob = {};

  function rerender() { try { window.UAI_rerender && window.UAI_rerender(); } catch (e) {} }

  if (!configured || !window.firebase) {
    window.UAI_sync = { push() {}, configured: false };
    return;
  }

  let auth, db;
  try {
    firebase.initializeApp(cfg);
    auth = firebase.auth();
    db = firebase.firestore();
  } catch (e) {
    window.UAI_sync = { push() {}, configured: false };   // don't trap behind a dead gate
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

  function push() {
    if (!docRef || applyingRemote) return;
    const blob = Object.assign({}, lastBlob);
    for (const k in KEYS) {
      try { const v = JSON.parse(localStorage.getItem(KEYS[k]) || "null"); if (v != null) blob[k] = v; } catch (e) {}
    }
    docRef.set({ data: JSON.stringify(blob), updatedAt: firebase.firestore.FieldValue.serverTimestamp() }, { merge: true })
      .catch(function () {});
  }
  window.UAI_sync = { push: push, configured: true };

  auth.onAuthStateChanged(function (user) {
    if (!user) { document.documentElement.classList.add("signed-out"); docRef = null; return; }
    document.documentElement.classList.remove("signed-out");
    mountAccountChip(user);
    docRef = db.collection("users").doc(user.uid);
    docRef.onSnapshot(function (snap) {
      if (snap.exists) {
        let blob = {};
        try { blob = JSON.parse((snap.data() || {}).data || "{}") || {}; } catch (e) {}
        lastBlob = blob;
        applyBlob(blob);
      } else { lastBlob = {}; push(); }
    }, function () {});
  });
})();
