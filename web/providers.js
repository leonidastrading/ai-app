// Shared AI catalog for the web launcher. `prefill` builds a deep link that
// opens the AI with the question already typed in (only where the site
// supports a URL query); otherwise we open the home page and copy the prompt
// to the clipboard so you can paste it.
window.UAI_PROVIDERS = [
  { id: "claude", name: "Claude", maker: "Anthropic", home: "https://claude.ai/new",
    tint: "#d9785a", prefill: (q) => `https://claude.ai/new?q=${encodeURIComponent(q)}`,
    strengths: "coding, debugging, long documents, careful writing and editing, analysis, reports" },
  { id: "chatgpt", name: "ChatGPT", maker: "OpenAI", home: "https://chatgpt.com/",
    tint: "#10a37f", prefill: (q) => `https://chatgpt.com/?q=${encodeURIComponent(q)}`,
    strengths: "general questions, brainstorming, voice chat, image generation as a second choice" },
  { id: "gemini", name: "Gemini", maker: "Google", home: "https://gemini.google.com/app",
    tint: "#4285f4", prefill: null,
    strengths: "image generation and photo editing (Nano Banana, the best image model), video generation (Veo), Google Search grounded research, YouTube, Gmail, Docs, Maps" },
  { id: "deepseek", name: "DeepSeek", maker: "DeepSeek", home: "https://chat.deepseek.com/",
    tint: "#4d6bfc", prefill: null,
    strengths: "math, step-by-step reasoning, competitive programming puzzles" },
  { id: "muse", name: "Muse", maker: "muse.ai", home: "https://muse.ai/",
    tint: "#8a47dc", prefill: null,
    strengths: "a personal AI assistant with long-term memory and an avatar: everyday help, reminders, proactive updates, web browsing, multi-step tasks across your connected accounts" },
  { id: "xai", name: "xAI", maker: "xAI", home: "https://grok.com/",
    tint: "#1a1a1a", prefill: (q) => `https://grok.com/?q=${encodeURIComponent(q)}`,
    strengths: "xAI's standalone assistant: deep reasoning, real-time web search, image and video generation (Imagine)" },
  { id: "grok", name: "Grok Bot", maker: "X", home: "https://x.com/i/grok",
    tint: "#0d0d0d", prefill: null,
    strengths: "the Grok bot inside X: explaining X posts, trends and breaking news on X/Twitter, accounts and threads" },
  { id: "vercel", name: "Vercel", maker: "Vercel v0", home: "https://v0.app/",
    tint: "#111111", prefill: (q) => `https://v0.app/?q=${encodeURIComponent(q)}`,
    strengths: "building websites, web apps and UI from a description: React, Next.js, Tailwind, landing pages, dashboards, prototypes, deploying to Vercel" },
];

// Keyword heuristics used when the server has no API key (offline routing).
window.UAI_HEURISTICS = [
  { id: "gemini", re: /\b(image|picture|photo|draw|logo|video|veo|banana|edit (a|the|my) (photo|image))\b/i },
  { id: "vercel", re: /\b(website|web app|landing page|react|next\.?js|tailwind|ui|component|dashboard|prototype|deploy)\b/i },
  { id: "deepseek", re: /\b(math|prove|theorem|equation|integral|algorithm|leetcode|competitive)\b/i },
  { id: "claude", re: /\b(code|debug|refactor|document|essay|write|edit|analyze|report|spreadsheet|contract)\b/i },
  { id: "xai", re: /\b(news|latest|today|real[- ]?time|current|breaking|stock|price)\b/i },
  { id: "grok", re: /\b(tweet|x post|twitter|thread|trending on x)\b/i },
];
