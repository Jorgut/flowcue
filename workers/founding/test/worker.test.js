import test from "node:test";
import assert from "node:assert/strict";
import { createHmac, generateKeyPairSync, randomBytes } from "node:crypto";
import { verifyPaddleSignature, priceMap, tierForSeat } from "../src/paddle.js";
import { signLicense, verifyLicense } from "../src/license.js";

test("paddle signature accepts a valid h1 and rejects tampering", async () => {
  const secret = "pdl_test_secret";
  const body = JSON.stringify({ event_type: "transaction.completed", data: { id: "txn_test" } });
  const ts = "1764000000";
  const sig = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");
  assert.equal(await verifyPaddleSignature(body, `ts=${ts};h1=${sig}`, secret), true);
  assert.equal(await verifyPaddleSignature(body + " ", `ts=${ts};h1=${sig}`, secret), false);
  assert.equal(await verifyPaddleSignature(body, `ts=${ts};h1=${sig}`, "wrong"), false);
});

test("paddle signature supports multiple h1 values", async () => {
  const secret = "pdl_test_secret";
  const body = "{}";
  const ts = "1764000000";
  const sig = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");
  assert.equal(await verifyPaddleSignature(body, `ts=${ts};h1=deadbeef;h1=${sig}`, secret), true);
});

test("license signs and verifies", async () => {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const privB64 = privateKey.export({ type: "pkcs8", format: "der" }).toString("base64");
  const pubB64 = publicKey.export({ type: "spki", format: "der" }).toString("base64");
  const payload = { v: 1, id: "lic_test", product: "mac-pro", seat: 7, tier: 1 };
  const token = await signLicense(payload, privB64);
  const decoded = await verifyLicense(token, pubB64);
  assert.deepEqual(decoded, payload);
  assert.equal(await verifyLicense(token.slice(0, -1) + (token.endsWith("A") ? "B" : "A"), pubB64), null);
});

test("tier boundaries", () => {
  assert.equal(tierForSeat(1), 1);
  assert.equal(tierForSeat(999), 1);
  assert.equal(tierForSeat(1000), 2);
  assert.equal(tierForSeat(1999), 2);
  const map = priceMap({
    PADDLE_PRICE_USD_9: "pri_9",
    PADDLE_PRICE_USD_19: "pri_19",
    PADDLE_PRICE_CNY_69: "pri_cny69",
    PADDLE_PRICE_CNY_139: "pri_cny139"
  });
  assert.equal(map.get("pri_19").tier, 2);
  assert.equal(map.get("pri_cny69").currency, "CNY");
});
