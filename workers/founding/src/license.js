const encoder = new TextEncoder();

function bytesToBase64(bytes) {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function base64ToBytes(value) {
  const binary = atob(value);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
  return out;
}

export function base64url(bytes) {
  return bytesToBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64urlToBytes(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((value.length + 3) % 4);
  return base64ToBytes(padded);
}

export async function importPrivateKey(base64) {
  return crypto.subtle.importKey("pkcs8", base64ToBytes(base64), { name: "Ed25519" }, false, ["sign"]);
}

export async function importPublicKey(base64) {
  return crypto.subtle.importKey("spki", base64ToBytes(base64), { name: "Ed25519" }, false, ["verify"]);
}

export async function signLicense(payload, privateKeyBase64) {
  const key = await importPrivateKey(privateKeyBase64);
  const body = JSON.stringify(payload);
  const signature = new Uint8Array(await crypto.subtle.sign("Ed25519", key, encoder.encode(body)));
  return `FC1-${base64url(encoder.encode(body))}.${base64url(signature)}`;
}

export async function verifyLicense(token, publicKeyBase64) {
  if (typeof token !== "string" || !token.startsWith("FC1-")) return null;
  const rest = token.slice(4);
  const dot = rest.indexOf(".");
  if (dot < 1) return null;
  const body = base64urlToBytes(rest.slice(0, dot));
  const signature = base64urlToBytes(rest.slice(dot + 1));
  const key = await importPublicKey(publicKeyBase64);
  const ok = await crypto.subtle.verify("Ed25519", key, signature, body);
  if (!ok) return null;
  try {
    return JSON.parse(new TextDecoder().decode(body));
  } catch {
    return null;
  }
}
