import { signLicense } from "./license.js";
import { priceMap, verifyPaddleSignature, fetchCustomerEmail, tierForSeat } from "./paddle.js";

const LIMIT = 1999;
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
    "Access-Control-Allow-Headers": "Content-Type, Paddle-Signature",
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

async function soldCount(env) {
  const row = await env.DB.prepare("SELECT COUNT(*) AS sold FROM orders WHERE status = 'completed'").first();
  return Number(row?.sold || 0);
}

function prices(env) {
  return {
    usd: { "9": env.PADDLE_PRICE_USD_9 || null, "19": env.PADDLE_PRICE_USD_19 || null },
    cny: { "69": env.PADDLE_PRICE_CNY_69 || null, "139": env.PADDLE_PRICE_CNY_139 || null }
  };
}

function configured(env) {
  const p = prices(env);
  return Boolean(
    env.PADDLE_CLIENT_TOKEN &&
    env.PADDLE_WEBHOOK_SECRET &&
    env.PADDLE_API_KEY &&
    env.LICENSE_PRIVATE_KEY &&
    env.RESEND_API_KEY &&
    env.RESEND_FROM &&
    p.usd["9"] && p.usd["19"] && p.cny["69"] && p.cny["139"]
  );
}

function nextTier(sold) {
  if (sold < 999) return { tier: 1, usd: 9.9, cny: 69, remaining: 999 - sold };
  if (sold < LIMIT) return { tier: 2, usd: 19.9, cny: 139, remaining: LIMIT - sold };
  return { tier: 0, usd: null, cny: null, remaining: 0 };
}

async function sendLicenseEmail(env, to, token, seat, tier) {
  if (!env.RESEND_API_KEY || !env.RESEND_FROM || !to) return { ok: false, reason: "email_not_configured" };
  const price = tier === 1 ? "$9.9" : "$19.9";
  const text = [
    "Thanks for buying FlowCue Mac Pro.",
    "",
    `Seat: #${seat} · ${price} lifetime`,
    "",
    "Your license:",
    token,
    "",
    "How to activate:",
    "1. Open FlowCue for Mac.",
    "2. Settings → Pro → Mac license.",
    "3. Paste the license above and press Activate.",
    "",
    "Keep this email. The license works offline.",
    "",
    "If anything goes wrong, reply to this email or write to hello@altn.vision."
  ].join("\n");
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      from: env.RESEND_FROM,
      to,
      subject: "Your FlowCue Mac Pro license",
      text
    })
  });
  return { ok: response.ok, status: response.status };
}

async function handleWebhook(request, env, ctx) {
  const raw = await request.text();
  const signature = request.headers.get("Paddle-Signature") || "";
  const valid = await verifyPaddleSignature(raw, signature, env.PADDLE_WEBHOOK_SECRET);
  if (!valid) return json({ ok: false, error: "invalid_signature" }, 401);

  let event;
  try {
    event = JSON.parse(raw);
  } catch {
    return json({ ok: false, error: "bad_json" }, 400);
  }
  if (event?.event_type !== "transaction.completed") {
    return json({ ok: true, ignored: event?.event_type || "unknown" }, 200);
  }

  const txn = event.data;
  if (!txn?.id || txn.status !== "completed") return json({ ok: true, ignored: "not_completed" }, 200);
  const priceId = txn.items?.[0]?.price?.id;
  const mapped = priceMap(env).get(priceId);
  if (!mapped) return json({ ok: true, ignored: "unknown_price" }, 200);

  const existing = await env.DB.prepare("SELECT id, seat FROM orders WHERE id = ?").bind(txn.id).first();
  if (existing) return json({ ok: true, duplicate: true, seat: existing.seat }, 200);

  const sold = await soldCount(env);
  const seat = sold + 1;
  if (seat > LIMIT) {
    await env.DB.prepare(
      "INSERT OR IGNORE INTO orders (id, email, customer_id, price_id, currency, amount, seat, tier, status, created_at, raw) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'over_limit', ?, ?)"
    ).bind(txn.id, null, txn.customer_id || null, priceId, txn.currency_code || null, null, seat, mapped.tier, new Date().toISOString(), JSON.stringify(txn)).run();
    return json({ ok: false, error: "over_limit" }, 200);
  }

  const email = (txn.custom_data && txn.custom_data.email) || (await fetchCustomerEmail(env, txn.customer_id));
  const amount = Number(txn.details?.totals?.grand_total || txn.details?.totals?.total || mapped.amount);
  const tier = mapped.tier;
  const now = new Date().toISOString();
  const licenseId = `lic_${txn.id}`;
  const payload = { v: 1, id: licenseId, email, product: "mac-pro", seat, tier, issued_at: now };
  const token = await signLicense(payload, env.LICENSE_PRIVATE_KEY);

  try {
    await env.DB.prepare(
      "INSERT INTO orders (id, email, customer_id, price_id, currency, amount, seat, tier, status, created_at, raw) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'completed', ?, ?)"
    ).bind(txn.id, email, txn.customer_id || null, priceId, txn.currency_code || null, amount, seat, tier, now, JSON.stringify(txn)).run();
  } catch {
    const row = await env.DB.prepare("SELECT id, seat FROM orders WHERE id = ?").bind(txn.id).first();
    if (row) return json({ ok: true, duplicate: true, seat: row.seat }, 200);
    return json({ ok: false, error: "order_failed" }, 500);
  }

  try {
    await env.DB.prepare(
      "INSERT OR IGNORE INTO licenses (id, order_id, email, seat, tier, token, issued_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
    ).bind(licenseId, txn.id, email, seat, tier, token, now).run();
  } catch {
    return json({ ok: false, error: "license_failed" }, 500);
  }

  ctx.waitUntil(sendLicenseEmail(env, email, token, seat, tier));
  return json({ ok: true, seat, tier, email: Boolean(email) }, 201);
}

export default {
  async fetch(request, env, ctx) {
    const headers = cors(request);
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers });

    if (url.pathname === "/api/founding/config" && request.method === "GET") {
      return json({
        ok: true,
        configured: configured(env),
        environment: env.PADDLE_ENVIRONMENT === "production" ? "production" : "sandbox",
        clientToken: env.PADDLE_CLIENT_TOKEN || null,
        prices: prices(env),
        limit: LIMIT,
        successUrl: `${env.SITE_ORIGIN || "https://flowcue.altn.vision"}/license/success`
      }, 200, headers);
    }

    if (url.pathname === "/api/founding/status" && request.method === "GET") {
      const sold = await soldCount(env);
      const next = nextTier(sold);
      return json({
        ok: true,
        limit: LIMIT,
        sold,
        claimed: sold,
        remaining: Math.max(0, LIMIT - sold),
        open: configured(env) && sold < LIMIT,
        configured: configured(env),
        next
      }, 200, headers);
    }

    if (url.pathname === "/api/paddle/webhook" && request.method === "POST") {
      try {
        return await handleWebhook(request, env, ctx);
      } catch {
        return json({ ok: false, error: "webhook_failed" }, 500);
      }
    }

    return json({ ok: false, error: "not_found" }, 404, headers);
  }
};
