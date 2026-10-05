const { contextBridge, ipcRenderer } = require("electron");
const path = require("path");
const { pathToFileURL } = require("url");

// Absolute file:// URL to the script injected into each AI webview. Works in
// dev and inside the packaged app (asar).
const WEBVIEW_PRELOAD = pathToFileURL(path.join(__dirname, "webview-preload.js")).toString();

contextBridge.exposeInMainWorld("api", {
  webviewPreload: WEBVIEW_PRELOAD,
  providers: () => ipcRenderer.invoke("providers:list"),
  getState: () => ipcRenderer.invoke("state:get"),
  setState: (patch) => ipcRenderer.invoke("state:set", patch),
  addCustomAI: (c) => ipcRenderer.invoke("customAI:add", c),
  removeCustomAI: (id) => ipcRenderer.invoke("customAI:remove", id),
  hasKey: () => ipcRenderer.invoke("apikey:has"),
  setKey: (k) => ipcRenderer.invoke("apikey:set", k),
  route: (prompt) => ipcRenderer.invoke("route", prompt),
  notify: (payload) => ipcRenderer.invoke("notify", payload),
  listMedia: () => ipcRenderer.invoke("media:list"),
  openMediaFolder: () => ipcRenderer.invoke("media:open"),
  revealMedia: (p) => ipcRenderer.invoke("media:reveal", p),
  openMediaFile: (p) => ipcRenderer.invoke("media:openFile", p),
  clearMedia: () => ipcRenderer.invoke("media:clear"),
  saveMedia: (payload) => ipcRenderer.invoke("media:save", payload),
  openExternal: (url) => ipcRenderer.invoke("open-external", url),
  writeClipboardImage: (dataURL) => ipcRenderer.invoke("clipboard:writeImage", dataURL),
  onMediaChanged: (cb) => ipcRenderer.on("media-changed", cb),
  onOpenProvider: (cb) => ipcRenderer.on("open-provider", (_e, id) => cb(id)),
  choosePhoto: () => ipcRenderer.invoke("profile:choosePhoto"),
  checkUpdate: () => ipcRenderer.invoke("update:check"),
  installUpdate: () => ipcRenderer.invoke("update:install"),
  onUpdateStatus: (cb) => ipcRenderer.on("update-status", (_e, p) => cb(p)),
  appVersion: () => ipcRenderer.invoke("app:version"),
});
