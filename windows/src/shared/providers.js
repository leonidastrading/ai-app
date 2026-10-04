// The built-in AIs, mirrored from the macOS app so both versions match.
// `tint` is the rail ring / badge color; the icon itself is the site favicon.
const BUILTIN = [
  {
    id: "claude", name: "Claude", maker: "Anthropic",
    home: "https://claude.ai/new",
    tint: "#d9785a",
    strengths: "coding, debugging, long documents, careful writing and editing, analysis, reports",
    hosts: ["claude.ai", "anthropic.com"],
  },
  {
    id: "chatgpt", name: "ChatGPT", maker: "OpenAI",
    home: "https://chatgpt.com/",
    tint: "#10a37f",
    strengths: "general questions, brainstorming, voice chat, image generation as a second choice",
    hosts: ["chatgpt.com", "openai.com"],
  },
  {
    id: "gemini", name: "Gemini", maker: "Google",
    home: "https://gemini.google.com/app",
    tint: "#4285f4",
    strengths: "image generation and photo editing (Nano Banana, the best image model), video generation (Veo), Google Search grounded research, YouTube, Gmail, Docs, Maps",
    hosts: ["gemini.google.com", "google.com"],
  },
  {
    id: "deepseek", name: "DeepSeek", maker: "DeepSeek",
    home: "https://chat.deepseek.com/",
    tint: "#4d6bfc",
    strengths: "math, step-by-step reasoning, competitive programming puzzles",
    hosts: ["deepseek.com"],
  },
  {
    id: "muse", name: "Muse", maker: "muse.ai",
    home: "https://muse.ai/",
    tint: "#8a47dc",
    strengths: "a personal AI assistant with long-term memory and an avatar: everyday help, reminders, proactive updates, web browsing, and multi-step tasks across your connected accounts",
    hosts: ["muse.ai"],
  },
  {
    id: "xai", name: "xAI", maker: "xAI",
    home: "https://grok.com/",
    tint: "#1a1a1a",
    strengths: "xAI's standalone assistant: deep reasoning, real-time web search, image and video generation (Imagine)",
    hosts: ["grok.com", "x.ai"],
  },
  {
    id: "grok", name: "Grok Bot", maker: "X",
    home: "https://x.com/i/grok",
    tint: "#0d0d0d",
    strengths: "the Grok bot inside X: explaining X posts, trends and breaking news on X/Twitter, accounts and threads",
    hosts: ["x.com", "twitter.com"],
  },
  {
    id: "vercel", name: "Vercel", maker: "Vercel v0",
    home: "https://v0.app/",
    tint: "#111111",
    strengths: "building websites, web apps and UI from a description: React, Next.js, Tailwind, landing pages, dashboards, prototypes, deploying to Vercel",
    hosts: ["v0.app", "v0.dev", "vercel.com"],
  },
];

// Hosts that run sign-in for other sites — these stay in-app so logins work.
const IDENTITY_HOSTS = [
  "google.com", "accounts.google.com", "apple.com", "icloud.com", "microsoft.com",
  "microsoftonline.com", "live.com", "facebook.com", "meta.com", "x.com", "twitter.com",
  "github.com", "okta.com", "auth0.com", "clerk.com", "clerk.dev", "stytch.com",
  "workos.com", "openai.com", "anthropic.com", "x.ai", "duosecurity.com",
];

function hostMatches(host, list) {
  if (!host) return false;
  host = host.toLowerCase();
  return list.some((h) => host === h || host.endsWith("." + h));
}

function faviconURL(home) {
  try {
    const h = new URL(home).host;
    return `https://www.google.com/s2/favicons?sz=128&domain=${h}`;
  } catch (e) {
    return "";
  }
}

module.exports = { BUILTIN, IDENTITY_HOSTS, hostMatches, faviconURL };
