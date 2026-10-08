// Vercel serverless function: picks the best AI for a prompt via the Anthropic
// Messages API. Uses the ANTHROPIC_API_KEY environment variable set on the
// Vercel project. If no key is configured, responds 501 so the client falls
// back to its offline keyword router. The key is never sent to the browser.
module.exports = async (req, res) => {
  if (req.method !== "POST") { res.status(405).json({ error: "POST only" }); return; }
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) { res.status(501).json({ error: "No API key configured" }); return; }

  let body = req.body;
  if (typeof body === "string") { try { body = JSON.parse(body); } catch (e) { body = {}; } }
  const prompt = (body && body.prompt ? String(body.prompt) : "").slice(0, 4000);
  const providers = (body && Array.isArray(body.providers)) ? body.providers : [];
  if (!prompt || !providers.length) { res.status(400).json({ error: "prompt and providers required" }); return; }

  const menu = providers.map((p) => `- ${p.id}: ${p.name} — ${p.strengths || ""}`).join("\n");
  const schema = {
    type: "object",
    properties: {
      provider: { type: "string", enum: providers.map((p) => p.id) },
      reason: { type: "string" },
    },
    required: ["provider", "reason"],
    additionalProperties: false,
  };

  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "server-side-fallback-2026-07-01",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5",
        max_tokens: 1024,
        system: "You route a user's request to the single best AI assistant. Choose only from the list. Answer with JSON.",
        messages: [{ role: "user", content: `AIs:\n${menu}\n\nRequest:\n${prompt}\n\nPick the best one.` }],
        output_config: { effort: "low", format: { type: "json_schema", schema } },
        fallbacks: "default",
      }),
    });
    const json = await r.json();
    if (!r.ok) { res.status(502).json({ error: json.error?.message || `API error ${r.status}` }); return; }
    const block = (json.content || []).reverse().find((b) => b.type === "text");
    const out = block ? JSON.parse(block.text) : null;
    if (!out || !out.provider) { res.status(502).json({ error: "Unexpected answer" }); return; }
    res.status(200).json(out);
  } catch (e) {
    res.status(502).json({ error: String(e && e.message ? e.message : e) });
  }
};
