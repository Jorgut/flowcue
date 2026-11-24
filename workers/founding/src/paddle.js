const encoder = new TextEncoder();

function constantTimeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifyPaddleSignature(rawBody, header, secret) {
  if (!rawBody || !header || !secret) return false;
  const parts = header.split(";");
  let ts = null;
  const signatures = [];
  for (const part of parts) {
    const index = part.indexOf("=");
    if (index < 0) continue;
    const key = part.slice(0, index).trim();
    const value = part.slice(index + 1).trim();
    if (key === "ts") ts = value;
    if (key === "h1" && value) signatures.push(value.toLowerCase());
  }
  if (!ts || signatures.length === 0) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${ts}:${rawBody}`)));
  const expected = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return signatures.some((signature) => constantTimeEqual(signature, expected));
}

export function priceMap(env) {
  const map = new Map();
  if (env.PADDLE_PRICE_USD_9) map.set(env.PADDLE_PRICE_USD_9, { tier: 1, price: 9.9, currency: "USD", amount: 990 });
  if (env.PADDLE_PRICE_USD_19) map.set(env.PADDLE_PRICE_USD_19, { tier: 2, price: 19.9, currency: "USD", amount: 1990 });
  if (env.PADDLE_PRICE_CNY_69) map.set(env.PADDLE_PRICE_CNY_69, { tier: 1, price: 9.9, currency: "CNY", amount: 6900 });
  if (env.PADDLE_PRICE_CNY_139) map.set(env.PADDLE_PRICE_CNY_139, { tier: 2, price: 19.9, currency: "CNY", amount: 13900 });
  return map;
}

export function tierForSeat(seat) {
  return seat <= 999 ? 1 : 2;
}

export function seatsRemaining(tier, sold) {
  if (tier === 1) return Math.max(0, 999 - sold);
  return Math.max(0, 1999 - sold);
}

export async function fetchCustomerEmail(env, customerId) {
  if (!customerId || !env.PADDLE_API_KEY) return null;
  const base = env.PADDLE_ENVIRONMENT === "production" ? "https://api.paddle.com" : "https://sandbox-api.paddle.com";
  const response = await fetch(`${base}/customers/${customerId}`, {
    headers: { Authorization: `Bearer ${env.PADDLE_API_KEY}` }
  });
  if (!response.ok) return null;
  const json = await response.json();
  return json?.data?.email || null;
}
