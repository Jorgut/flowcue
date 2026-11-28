import { DurableObject } from "cloudflare:workers";

const maxBodyBytes = 256 * 1024;
const validID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const reply = (data, status = 200) => Response.json(data, {
  status,
  headers: { "cache-control": "no-store" },
});

async function readPayload(request) {
  if (Number(request.headers.get("content-length")) > maxBodyBytes) return null;
  const reader = request.body?.getReader();
  if (!reader) return null;
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBodyBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return new Blob(chunks).arrayBuffer();
}

// Unknown outcomes remain claimed so a dropped acknowledgment cannot
// cause a second execution.
export class Mailbox extends DurableObject {
  async fetch(request) {
    const [, , operation, requestID] = new URL(request.url).pathname.split("/");
    const payload = operation === "submit" || operation === "complete"
      ? await request.arrayBuffer()
      : undefined;
    const digest = payload === undefined
      ? undefined
      : new Uint8Array(await crypto.subtle.digest("SHA-256", payload)).toHex();

    return this.ctx.storage.transaction(async transaction => {
      if (operation === "claim") {
        const pending = await transaction.list({ prefix: "pending:", limit: 1 });
        const next = pending.keys().next().value;
        if (!next) return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
        const id = pending.get(next);
        const requestKey = `request:${id}`;
        const item = await transaction.get(requestKey);
        await transaction.delete(next);
        await transaction.put(requestKey, { state: "claimed", requestDigest: item.requestDigest });
        return new Response(item.payload, {
          headers: { "cache-control": "no-store", "x-flowcue-request-id": id },
        });
      }

      const requestKey = `request:${requestID.toLowerCase()}`;
      const item = await transaction.get(requestKey);
      switch (operation) {
        case "submit":
          if (item) {
            if (item.requestDigest !== digest) return reply({ error: "request_id_conflict" }, 409);
            return reply({ state: item.state });
          }
          await transaction.put(requestKey, { state: "pending", payload, requestDigest: digest });
          const sequenceKey = "pending-sequence";
          const sequence = (await transaction.get(sequenceKey) ?? 0) + 1;
          await transaction.put(sequenceKey, sequence);
          await transaction.put(`pending:${String(sequence).padStart(16, "0")}`, requestID.toLowerCase());
          return reply({ state: "pending" }, 202);
        case "complete":
          if (item?.state === "completed" && item.responseDigest === digest) return reply({ state: "completed" });
          if (item?.state !== "claimed") return reply({ state: item?.state ?? "unknown" }, item ? 409 : 404);
          await transaction.put(requestKey, {
            state: "completed",
            requestDigest: item.requestDigest,
            responseDigest: digest,
            response: payload,
          });
          return reply({ state: "completed" });
        case "result":
          if (!item) return reply({ state: "unknown" }, 404);
          if (item.state !== "completed") return reply({ state: item.state }, 202);
          return new Response(item.response, { headers: { "cache-control": "no-store" } });
        default:
          return reply({ error: "not_found" }, 404);
      }
    });
  }
}

const routes = {
  submit: ["POST", "PHONE_TOKEN"],
  claim: ["POST", "MAC_TOKEN"],
  complete: ["POST", "MAC_TOKEN"],
  result: ["GET", "PHONE_TOKEN"],
};

export default {
  async fetch(request, env) {
    const [, prefix, operation, id, extra] = new URL(request.url).pathname.split("/");
    const validPath = operation === "claim" ? id === undefined : validID.test(id ?? "");
    if (prefix !== "prototype" || extra !== undefined || !validPath || !Object.hasOwn(routes, operation)) {
      return reply({ error: "not_found" }, 404);
    }
    const [method, tokenName] = routes[operation];
    if (method !== request.method) return reply({ error: "method_not_allowed" }, 405);
    const token = env[tokenName];
    if (!token || request.headers.get("Authorization") !== `Bearer ${token}`) {
      return reply({ error: "unauthorized" }, 401);
    }
    const mailbox = env.MAILBOX.getByName("test-pair");
    if (operation === "submit" || operation === "complete") {
      const payload = await readPayload(request);
      if (payload === null) return reply({ error: "invalid_payload" }, 413);
      return mailbox.fetch(request.url, { method, body: payload });
    }
    return mailbox.fetch(request.url, { method });
  },
};
