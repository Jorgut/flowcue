/**
 * FlowCue DSH bridge — experimental.
 *
 * Runs inside the DSH host. Registers a single approval/request answerer and
 * exposes pending decisions on localhost for the FlowCue Mac app to proxy to
 * the paired iPhone. The bridge never binds beyond 127.0.0.1 and requires a
 * per-install bearer token stored in ~/.flowcue/dsh-bridge.json.
 */
import { randomBytes, randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const name = "flowcue-dsh-bridge";
export const inject = ["approval", "agents", "attachments"];

const HOST = "127.0.0.1";
const PORT = Number(process.env.FLOWCUE_DSH_PORT || 47823);
const HOST_BASE = `http://${HOST}:${PORT}`;
// 手机在这个窗口内轮询过，就只等手机（不再同时弹桌面卡）。
const PHONE_WINDOW_MS = Number(process.env.FLOWCUE_BRIDGE_PHONE_WINDOW_MS || 15_000);
// 等手机多久；超时回退到桌面审批。手机锁屏时靠推送唤醒，给 45 秒。
const PHONE_GRACE_MS = Number(process.env.FLOWCUE_BRIDGE_PHONE_GRACE_MS || 45_000);
// 手机在这个窗口内出现过（轮询或决定），就优先只走手机。
// 桌面卡一旦弹出，手机再批准时那张卡不会自动消失——所以宁可等手机。
const PHONE_PAIR_WINDOW_MS = Number(process.env.FLOWCUE_BRIDGE_PHONE_PAIR_MS || 10 * 60_000);
// 等问题卡回答多久；超时落回桌面。测试里可以调短。
const QUESTION_TIMEOUT_MS = Number(process.env.FLOWCUE_BRIDGE_QUESTION_MS || 60_000);
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

// Auto review may send displayReason as a localized object; clients expect text.
function text(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    return value.zh ?? value.en ?? Object.values(value).find((v) => typeof v === "string") ?? null;
  }
  return null;
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

// 默认 16 KB 够审批用；发消息带图片时要大得多，所以按路由给上限。
// DSH 的提问结构在不同调用方略有差异，这里统一成手机能直接渲染的形状。
function normalizeQuestions(request) {
  const raw = Array.isArray(request?.questions) ? request.questions
    : Array.isArray(request) ? request
    : request?.questions ? [request.questions] : [];
  return raw.map((question, index) => ({
    id: String(question?.id ?? index),
    title: String(question?.prompt ?? question?.title ?? question?.question ?? ""),
    detail: question?.detail ?? question?.description ?? null,
    multiSelect: question?.multiSelect === true,
    options: (Array.isArray(question?.options) ? question.options : []).map((option) => {
      if (typeof option === "string") return { label: option, detail: null };
      return {
        label: String(option?.label ?? option?.title ?? option?.value ?? ""),
        detail: option?.description ?? option?.detail ?? null,
      };
    }),
  }));
}

async function readJSON(req, limit = 16_384) {
  let body = "";
  for await (const chunk of req) body += chunk;
  if (body.length > limit) throw new Error("payload too large");
  return JSON.parse(body || "{}");
}

export function apply(ctx) {
  if (process.env.FLOWCUE_DSH_BRIDGE_DISABLE === "1") return;

  /** @type {Map<string, { request: any, resolve: (outcome: string) => void, createdAt: number }>} */
  const pending = new Map();
  /** @type {Map<string, { request: any, resolve: (answers: any) => void, createdAt: number }>} */
  const pendingQuestions = new Map();
  let closed = false;
  /** Last time the paired phone polled or decided; used to skip the desktop prompt. */
  let lastPhoneActivity = 0;
  /** Last time the phone was seen at all; keeps desktop-only approval from stealing the card. */
  let lastPhoneSeenAt = 0;

  const tokenReady = loadToken();

  const server = createServer(async (req, res) => {
    try {
      if (!req.url?.startsWith("/v1/")) return json(res, 404, { error: "not found" });
      const url = new URL(req.url, HOST_BASE);
      const token = await tokenReady;
      const auth = req.headers.authorization || "";
      if (auth !== `Bearer ${token}`) return json(res, 401, { error: "unauthorized" });

      if (req.method === "GET" && url.pathname === "/v1/pending") {
        // 只有真的替手机转发的轮询才算「手机在线」。桌面端自己的轮询
        // （菜单栏角标、待审批面板、会话列表）不能冒充手机，否则每一轮
        // 桌面审批都会被扣住等手机，最后拖到 fallback 才出现。
        if (url.searchParams.get("source") === "phone") {
          lastPhoneActivity = Date.now();
          lastPhoneSeenAt = lastPhoneActivity;
        }
        return json(res, 200, {
          questions: [...pendingQuestions.entries()].map(([id, item]) => ({
            id,
            createdAt: new Date(item.createdAt).toISOString(),
            sessionId: item.request?.agent?.session?.id ?? item.request?.sessionId ?? null,
            questions: normalizeQuestions(item.request),
          })),
          pending: [...pending.entries()].map(([id, item]) => ({
            id,
            sessionId: item.sessionId ?? null,
            toolName: item.request.toolName ?? null,
            callId: item.request.callId ?? null,
            reason: text(item.request.reason),
            displayReason: text(item.request.displayReason),
            createdAt: new Date(item.createdAt).toISOString(),
          })),
        });
      }

      if (req.method === "POST" && req.url === "/v1/message") {
        const body = await readJSON(req, 24 * 1024 * 1024);
        if (typeof body.sessionId !== "string" || typeof body.text !== "string" || !body.text.trim()) {
          return json(res, 400, { error: "sessionId and text are required" });
        }
        const agents = ctx.agents.list();
        const agent = agents.find((candidate) => candidate.session?.id === body.sessionId)
          ?? ctx.agents.get(body.sessionId);
        if (!agent) return json(res, 409, { error: "DSH session is not live; open it in DSH first" });
        const images = Array.isArray(body.images) ? body.images : [];
        const content = [
          { type: "text", text: body.text.trim() },
          ...images.map((data) => ({ type: "image", data, mediaType: "image/jpeg" })),
        ];
        const admitted = images.length === 0 ? content : await ctx.attachments.admitPromptContent(content);
        await agent.followup({
          id: randomUUID(),
          role: "user",
          content: admitted,
          source: { kind: "user", rpcId: randomUUID() },
        });
        return json(res, 200, { ok: true });
      }

      if (req.method === "POST" && url.pathname === "/v1/answer") {
        const body = await readJSON(req, 256 * 1024);
        const item = pendingQuestions.get(body.id);
        if (!item) return json(res, 404, { error: "question is no longer pending" });
        if (!Array.isArray(body.answers)) return json(res, 400, { error: "answers is required" });
        pendingQuestions.delete(body.id);
        item.resolve({ answers: body.answers });
        return json(res, 200, { ok: true });
      }

      if (req.method === "POST" && url.pathname === "/v1/decide") {
        lastPhoneActivity = Date.now();
        lastPhoneSeenAt = lastPhoneActivity;
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
    // Prepend: the desktop UI (and the Auto review gate) registers its own
    // answerer earlier in the waterfall. Without prepend this handler never
    // runs for desktop-owned sessions, so the phone never sees the request.
    yield ctx.on("approval/request", async (request, next) => {
      if (closed) return next();
      const id = randomBytes(12).toString("hex");
      const sessionId = request.agent?.session?.id ?? null;
      const bridged = new Promise((resolve) => {
        pending.set(id, { request, resolve, sessionId, createdAt: Date.now() });
        request.signal?.addEventListener?.("abort", () => {
          if (!pending.has(id)) return;
          pending.delete(id);
          resolve("cancelled");
        }, { once: true });
      });
      // When the phone is actively polling, let it answer alone. Calling next()
      // here would also open the desktop prompt, which stays on screen even
      // after the phone decides because the desktop answerer is still waiting.
      // If the phone goes quiet for PHONE_GRACE_MS, fall back to the desktop prompt.
      const phonePresent = Date.now() - lastPhoneActivity < PHONE_WINDOW_MS
        || Date.now() - lastPhoneSeenAt < PHONE_PAIR_WINDOW_MS;
      if (phonePresent) {
        let timer;
        const timeout = new Promise((resolve) => {
          timer = setTimeout(() => resolve("unavailable"), PHONE_GRACE_MS);
        });
        const outcome = await Promise.race([bridged, timeout]);
        clearTimeout(timer);
        if (outcome !== "unavailable") return outcome;
        // 手机在宽限期内没响应：撤掉这一条，否则手机上会留一个永远点不动的审批。
        pending.delete(id);
        return await next();
      }

      // Keep the desktop approval path alive: if the normal DSH answerer
      // resolves first, stop waiting for the phone. If it reports unavailable,
      // wait for the bridge so a phone-only setup still works.
      const downstream = next().then((outcome) => {
        if (outcome !== "unavailable") pending.delete(id);
        return outcome;
      }, () => "unavailable");
      const first = await Promise.race([bridged, downstream]);
      return first === "unavailable" ? await bridged : first;
    }, { prepend: true });

    // 提问卡：和审批同构的 waterfall。手机答完直接返回结构化答案；
    // 手机没答就落回桌面，绝不吞掉问题。
    yield ctx.on("user-questions/request", async (request, next) => {
      if (closed) return next();
      const id = randomBytes(12).toString("hex");
      const answered = new Promise((resolve) => {
        pendingQuestions.set(id, { request, resolve, createdAt: Date.now() });
        request.signal?.addEventListener?.("abort", () => {
          if (!pendingQuestions.has(id)) return;
          pendingQuestions.delete(id);
          resolve("unavailable");
        }, { once: true });
      });
      let timer;
      const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve("unavailable"), QUESTION_TIMEOUT_MS);
      });
      const outcome = await Promise.race([answered, timeout]);
      clearTimeout(timer);
      pendingQuestions.delete(id);
      if (outcome === "unavailable") return await next();
      return outcome;
    }, { prepend: true });

    yield async () => {
      closed = true;
      for (const item of pending.values()) item.resolve("unavailable");
      pending.clear();
      for (const item of pendingQuestions.values()) item.resolve({ answers: [] });
      pendingQuestions.clear();
      await new Promise((resolve) => server.close(() => resolve()));
    };
  });
}
