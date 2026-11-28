import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { unstable_dev } from "../remote/node_modules/wrangler/wrangler-dist/cli.js";

const phone = randomUUID();
const mac = randomUUID();
const sandbox = await mkdtemp(join(tmpdir(), "flowcue-mailbox-"));
const config = join(sandbox, "wrangler.json");
const script = fileURLToPath(new URL("./mailbox.mjs", import.meta.url));
let relay;

const request = (operation, id, token, body) => relay.fetch(
  operation === "claim" ? "/prototype/claim" : `/prototype/${operation}/${id}`,
  {
    method: operation === "result" ? "GET" : "POST",
    headers: { Authorization: `Bearer ${token}` },
    body,
  },
);

try {
  await writeFile(config, JSON.stringify({
    name: "flowcue-mailbox-test",
    main: script,
    compatibility_date: "2026-01-01",
    durable_objects: { bindings: [{ name: "MAILBOX", class_name: "Mailbox" }] },
    migrations: [{ tag: "v1", new_sqlite_classes: ["Mailbox"] }],
  }));
  relay = await unstable_dev(script, {
    config,
    local: true,
    persist: false,
    inspect: false,
    port: 0,
    vars: { PHONE_TOKEN: phone, MAC_TOKEN: mac },
    experimental: { disableExperimentalWarning: true, disableDevRegistry: true, watch: false },
  });

  const id = randomUUID();
  const payload = randomBytes(240 * 1024);
  const response = randomBytes(240 * 1024);

  assert.equal((await request("submit", id, mac, payload)).status, 401);
  assert.equal((await request("submit", id, phone, randomBytes(256 * 1024 + 1))).status, 413);
  assert.equal((await request("submit", id, phone, payload)).status, 202);
  assert.equal((await request("submit", id, phone, payload)).status, 200);
  assert.equal((await request("submit", id, phone, "different")).status, 409);
  assert.equal((await request("claim", id, phone)).status, 401);
  assert.deepEqual(await (await request("result", id, phone)).json(), { state: "pending" });

  const claims = await Promise.all([request("claim", id, mac), request("claim", id, mac)]);
  assert.deepEqual(claims.map(result => result.status).sort(), [200, 204]);
  const claimed = claims.find(result => result.status === 200);
  assert.equal(claimed.headers.get("x-flowcue-request-id"), id);
  assert.deepEqual(Buffer.from(await claimed.arrayBuffer()), payload);
  assert.deepEqual(await (await request("result", id, phone)).json(), { state: "claimed" });
  assert.deepEqual(await (await request("submit", id, phone, payload)).json(), { state: "claimed" });
  assert.equal((await request("claim", id, mac)).status, 204);

  assert.equal((await request("complete", id, phone, response)).status, 401);
  assert.equal((await request("complete", id, mac, response)).status, 200);
  assert.equal((await request("complete", id, mac, response)).status, 200);
  assert.equal((await request("complete", id, mac, "different")).status, 409);
  assert.deepEqual(Buffer.from(await (await request("result", id, phone)).arrayBuffer()), response);
  assert.deepEqual(Buffer.from(await (await request("result", id, phone)).arrayBuffer()), response);
  assert.deepEqual(await (await request("submit", id, phone, payload)).json(), { state: "completed" });
  assert.equal((await request("claim", id, mac)).status, 204);
  assert.equal((await request("result", randomUUID(), phone)).status, 404);
  const first = "ffffffff-ffff-ffff-ffff-ffffffffffff";
  const second = "00000000-0000-0000-0000-000000000000";
  assert.equal((await request("submit", first, phone, "first")).status, 202);
  assert.equal((await request("submit", second, phone, "second")).status, 202);
  for (const requestID of [first, second]) {
    const delivery = await request("claim", undefined, mac);
    assert.equal(delivery.headers.get("x-flowcue-request-id"), requestID);
    await delivery.arrayBuffer();
  }
  const historyID = randomUUID();
  const sendID = randomUUID();
  const history = { messages: [{ id: "fixture-history", role: "assistant", text: "Existing test history" }], total: 1, start: 0 };
  assert.equal((await request("submit", historyID, phone, "GET synthetic history")).status, 202);
  assert.equal((await request("claim", undefined, mac)).headers.get("x-flowcue-request-id"), historyID);
  assert.equal((await request("complete", historyID, mac, JSON.stringify(history))).status, 200);
  assert.deepEqual(await (await request("result", historyID, phone)).json(), history);

  const message = "POST synthetic message";
  assert.equal((await request("submit", sendID, phone, message)).status, 202);
  const delivery = await request("claim", undefined, mac);
  assert.equal(delivery.headers.get("x-flowcue-request-id"), sendID);
  assert.equal(await delivery.text(), message);
  const beforeReceipt = await request("result", sendID, phone);
  assert.equal(beforeReceipt.status, 202);
  assert.deepEqual(await beforeReceipt.json(), { state: "claimed" });
  assert.equal((await request("claim", undefined, mac)).status, 204);
  assert.equal((await request("complete", sendID, mac, "delivered")).status, 200);
  assert.equal(await (await request("result", sendID, phone)).text(), "delivered");
  assert.equal((await request("claim", undefined, mac)).status, 204);
  console.log("Synthetic chat verified: history loaded, late receipt recovered by original ID, no second delivery");
  console.log("HTTPS mailbox verified: 240 KiB request/receipt, authorization, single claim, idempotency, and repeatable result");
} finally {
  await relay?.stop();
  await rm(sandbox, { recursive: true, force: true });
}
