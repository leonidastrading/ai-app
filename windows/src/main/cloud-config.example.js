// Template for cloud-config.js (which is gitignored and generated in CI from
// GitHub Actions secrets). For local development, copy this to cloud-config.js
// and fill in your Firebase + Google OAuth (Desktop client) values.
module.exports = {
  firebaseApiKey: "YOUR_FIREBASE_API_KEY",
  projectId: "YOUR_FIREBASE_PROJECT_ID",
  googleClientId: "YOUR_GOOGLE_DESKTOP_CLIENT_ID",
  googleClientSecret: "YOUR_GOOGLE_DESKTOP_CLIENT_SECRET",
};
