const LIMIT = 999;
const ORIGINS = new Set([
  "https://flowcue.altn.vision",
  "http://127.0.0.1:8811",
  "http://localhost:8811"
]);

function cors(request) {
  const origin = request.headers.get("Origin") || "";
  const allow = ORIGINS.has(origin) ? origin : "https://flowcue.altn.vision";
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin"
  };
}

function json(body, status, headers) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...headers }
  });
}

function validEmail(value) {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (email.length < 5 || email.length > 254) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

async function ipHash(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "";
  const salt = env.FOUNDING_SALT || "flowcue-founding-v1";
  const data = new TextEncoder().encode(`${salt}:${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)].slice(0, 12).map(b => b.toString(16).padStart(2, "0")).join("");
}

async function counts(env) {
  const row = await env.DB.prepare("SELECT COUNT(*) AS claimed FROM founding_users").first();
  const claimed = Number(row?.claimed || 0);
  return { claimed, remaining: Math.max(0, LIMIT - claimed), open: claimed < LIMIT };
}

export default {
  async fetch(request, env) {
    const headers = cors(request);
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });
    if (url.pathname === "/api/founding/status" && request.method === "GET") {
      return json({ ok: true, limit: LIMIT, ...(await counts(env)) }, 200, headers);
    }
    if (url.pathname === "/api/founding/claim" && request.method === "POST") {
      let body;
      try { body = await request.json(); } catch { return json({ ok: false, error: "bad_json" }, 400, headers); }
      const email = validEmail(body?.email);
      if (!email) return json({ ok: false, error: "invalid_email" }, 400, headers);

      const state = await counts(env);
      const existing = await env.DB.prepare("SELECT id FROM founding_users WHERE email = ?").bind(email).first();
      if (existing) {
        return json({ ok: true, duplicate: true, seat: Number(existing.id), limit: LIMIT, ...state }, 200, headers);
      }
      if (!state.open) return json({ ok: false, error: "full", limit: LIMIT, ...state }, 409, headers);

      const hash = await ipHash(request, env);
      const recent = await env.DB.prepare(
        "SELECT COUNT(*) AS c FROM founding_users WHERE ip_hash = ? AND created_at > datetime('now','-10 minutes')"
      ).bind(hash).first();
      if (Number(recent?.c || 0) >= 3) return json({ ok: false, error: "rate_limited" }, 429, headers);

      await env.DB.prepare("INSERT INTO founding_users (email, ip_hash) VALUES (?, ?)").bind(email, hash).run();
      const row = await env.DB.prepare("SELECT id FROM founding_users WHERE email = ?").bind(email).first();
      const seat = Number(row?.id || 0);
      if (!seat || seat > LIMIT) {
        if (seat) await env.DB.prepare("DELETE FROM founding_users WHERE id = ?").bind(seat).run();
        return json({ ok: false, error: "full", limit: LIMIT, ...(await counts(env)) }, 409, headers);
      }
      const after = await counts(env);
      return json({ ok: true, seat, limit: LIMIT, ...after }, 201, headers);
    }
    return json({ ok: false, error: "not_found" }, 404, headers);
  }
};
