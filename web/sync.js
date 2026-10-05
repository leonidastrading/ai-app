"use strict";
// Google sign-in gate + cloud sync for the UAI web app.
// Uses the Firebase compat SDKs loaded in index.html. Signs the user in with
// Google and mirrors their UAI data (currently: custom AIs) to Firestore under
// users/{uid}, so it syncs with the Mac and Windows apps on the same account.

(function () {
  const cfg = window.UAI_FIREBASE || {};
  const configured = cfg.apiKey && !/^PASTE/.test(cfg.apiKey);

  // Keys we sync: localStorage key -> field name in the user's Firestore doc.
  const SYNCED = { "uai.custom": "custom" };

  // Re-render hooks the app registers (set at the end of app.js).
  function rerender() { try { window.UAI_rerender && window.UAI_rerender(); } catch (e) {} }

  if (!configured || !window.firebase) {
    // Not set up yet — run as a plain launcher, no sign-in required.
    window.UAI_sync = { push() {}, configured: false };
    return;
  }

  let auth, db;
  try {
    firebase.initializeApp(cfg);
    auth = firebase.auth();
    db = firebase.firestore();
  } catch (e) {
    // If Firebase can't start, don't trap the user behind a dead gate — run as
    // a plain launcher.
    window.UAI_sync = { push() {}, configured: false };
    return;
  }
  let docRef = null;
  let applyingRemote = false;   // guard so remote writes don't echo back

  // ---- sign-in gate ----
  const gate = document.createElement("div");
  gate.id = "auth-gate";
  gate.innerHTML =
    '<div class="auth-card">' +
    '  <div class="galaxy big" aria-hidden="true"></div>' +
    "  <h1>UAI</h1>" +
    "  <p>Sign in with Google to sync your AIs, memory and settings across the Mac, Windows and web apps.</p>" +
    '  <button id="google-signin" class="primary">Sign in with Google</button>' +
    '  <p class="auth-err" id="auth-err"></p>' +
    "</div>";
  document.body.appendChild(gate);
  document.documentElement.classList.add("signed-out");

  document.getElementById("google-signin").onclick = function () {
    const provider = new firebase.auth.GoogleAuthProvider();
    auth.signInWithPopup(provider).catch(function (e) {
      document.getElementById("auth-err").textContent = e && e.message ? e.message : "Sign-in failed.";
    });
  };

  // ---- a small account chip + sign out, added to the top bar ----
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

  // ---- sync ----
  function pull(data) {
    applyingRemote = true;
    try {
      let changed = false;
      for (const key in SYNCED) {
        const field = SYNCED[key];
        // Only apply real values — never overwrite local with a null/undefined
        // remote field (that used to blank out the AI list).
        if (data && data[field] != null) {
          const next = JSON.stringify(data[field]);
          if (localStorage.getItem(key) !== next) { localStorage.setItem(key, next); changed = true; }
        }
      }
      if (changed) rerender();
    } catch (e) {} finally { applyingRemote = false; }
  }

  function push() {
    if (!docRef || applyingRemote) return;
    const payload = { updatedAt: firebase.firestore.FieldValue.serverTimestamp() };
    for (const key in SYNCED) {
      try {
        const v = JSON.parse(localStorage.getItem(key) || "null");
        if (v != null) payload[SYNCED[key]] = v;   // never write null (it blanked the list)
      } catch (e) {}
    }
    docRef.set(payload, { merge: true }).catch(function () {});
  }
  window.UAI_sync = { push: push, configured: true };

  auth.onAuthStateChanged(function (user) {
    if (!user) {
      document.documentElement.classList.add("signed-out");
      docRef = null;
      return;
    }
    document.documentElement.classList.remove("signed-out");
    mountAccountChip(user);
    docRef = db.collection("users").doc(user.uid);
    // Live-sync: apply remote changes as they happen; seed the cloud from local
    // on first sign-in if the cloud doc is empty.
    docRef.onSnapshot(function (snap) {
      if (snap.exists) pull(snap.data());
      else push();   // first time on this account: upload what's here
    }, function () {});
  });
})();
