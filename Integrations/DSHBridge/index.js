/**
 * FlowCue DSH bridge — experimental.
 *
 * Runs inside the DSH host. Registers a single approval/request answerer and
 * exposes pending decisions on localhost for the FlowCue Mac app to proxy to
 * the paired iPhone. The bridge never binds beyond 127.0.0.1 and requires a
 * per-install bearer token stored in ~/.flowcue/dsh-bridge.json.
 */
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const name = "flowcue-dsh-bridge";
export const inject = ["approval"];

const HOST = "127.0.0.1";
const PORT = Number(process.env.FLOWCUE_DSH_PORT || 47823);
const STATE_DIR = join(homedir(), ".flowcue");
const STATE_FILE = join(STATE_DIR, "dsh-bridge.json");

async function loadToken() {
  try {
    const raw = await readFile(STATE_FILE, "utf8");
    const parsed = JSON.parse(raw);
    if (typeof parsed.token === "string" && parsed.token.length >= 24) return parsed.token;
  } catch {}
  const token = randomBytes(24).toString("hex");
  await mkdir(STATE_DIR, { recursive: true, mode: 0o700 });
  await writeFile(STATE_FILE, JSON.stringify({ token, port: PORT }, null, 2), { mode: 0o600 });
  return token;
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
  });
  res.end(payload);
}

async function readJSON(req) {
  let body = "";
  for await (const chunk of req) body += chunk;
  if (body.length > 16_384) throw new Error("payload too large");
  return JSON.parse(body || "{}");
}

export function apply(ctx) {
  if (process.env.FLOWCUE_DSH_BRIDGE_DISABLE === "1") return;

  /** @type {Map<string, { request: any, resolve: (outcome: string) => void, createdAt: number }>} */
  const pending = new Map();
  let closed = false;

  const tokenReady = loadToken();

  const server = createServer(async (req, res) => {
    try {
      if (!req.url?.startsWith("/v1/")) return json(res, 404, { error: "not found" });
      const token = await tokenReady;
      const auth = req.headers.authorization || "";
      if (auth !== `Bearer ${token}`) return json(res, 401, { error: "unauthorized" });

      if (req.method === "GET" && req.url === "/v1/pending") {
        return json(res, 200, {
          pending: [...pending.entries()].map(([id, item]) => ({
            id,
            toolName: item.request.toolName ?? null,
            callId: item.request.callId ?? null,
            reason: item.request.reason ?? null,
            displayReason: item.request.displayReason ?? null,
            createdAt: new Date(item.createdAt).toISOString(),
          })),
        });
      }

      if (req.method === "POST" && req.url === "/v1/decide") {
        const body = await readJSON(req);
        const item = pending.get(body.id);
        if (!item) return json(res, 404, { error: "request is no longer pending" });
        if (body.decision !== "allowed-once" && body.decision !== "rejected") {
          return json(res, 400, { error: "decision must be allowed-once or rejected" });
        }
        pending.delete(body.id);
        item.resolve(body.decision);
        return json(res, 200, { ok: true });
      }

      return json(res, 404, { error: "not found" });
    } catch (error) {
      return json(res, 500, { error: error instanceof Error ? error.message : "bridge error" });
    }
  });

  server.on("error", (error) => {
    ctx.logger?.warn?.(`flowcue-dsh-bridge: ${error.message}`);
  });
  server.listen(PORT, HOST);

  ctx.effect(function* () {
    yield ctx.on("approval/request", async (request, next) => {
      if (closed) return next();
      const id = randomBytes(12).toString("hex");
      const bridged = new Promise((resolve) => {
        pending.set(id, { request, resolve, createdAt: Date.now() });
        request.signal?.addEventListener?.("abort", () => {
          if (!pending.has(id)) return;
          pending.delete(id);
          resolve("cancelled");
        }, { once: true });
      });
      // Keep the desktop approval path alive: if the normal DSH answerer
      // resolves first, stop waiting for the phone. If it reports unavailable,
      // wait for the bridge so a phone-only setup still works.
      const downstream = next().then((outcome) => {
        if (outcome !== "unavailable") pending.delete(id);
        return outcome;
      }, () => "unavailable");
      const first = await Promise.race([bridged, downstream]);
      return first === "unavailable" ? await bridged : first;
    });

    yield async () => {
      closed = true;
      for (const item of pending.values()) item.resolve("unavailable");
      pending.clear();
      await new Promise((resolve) => server.close(() => resolve()));
    };
  });
}
