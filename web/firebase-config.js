// Firebase project config for UAI sign-in + sync.
//
// Fill these in from your Firebase project:
//   Firebase console -> Project settings (gear) -> General -> "Your apps" ->
//   Web app -> SDK setup and configuration -> "Config".
// These values are PUBLIC (safe to commit); security comes from Firestore rules.
// Until real values are set, the app runs without sign-in (launcher only).
window.UAI_FIREBASE = {
  apiKey: "PASTE_API_KEY",
  authDomain: "PASTE_PROJECT_ID.firebaseapp.com",
  projectId: "PASTE_PROJECT_ID",
  appId: "PASTE_APP_ID",
};
