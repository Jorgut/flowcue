/**
 * FlowCue Remote 中继（MVP）
 *
 * 只做三件事：
 *  1. 登记 Mac，签发 token
 *  2. 配对：手机提交公钥 → Mac 批准 → 签发 pair token
 *  3. WebSocket 转发：按信封里的 pair 字段把帧送到对端
 *
 * 中继不解析 ciphertext，也拿不到任何共享密钥。
 */

export interface Env {
  MAC_SESSION: DurableObjectNamespace;
}

// ---------- 工具 ----------

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });

const randomToken = () =>
  [...crypto.getRandomValues(new Uint8Array(24))]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

// ---------- Durable Object：一台 Mac 一个 ----------

export class MacSession {
  private state: DurableObjectState;
  private macID = "";
  private macSocket: WebSocket | null = null;
  private iosSockets = new Map<string, WebSocket>(); // pairID -> socket

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // 内部 HTTP：登记 / 配对
    if (url.pathname === "/register") {
      const body = await request.json<{ macID: string; publicKey?: string }>();
      this.macID = body.macID;
      const token = randomToken();
      await this.state.storage.put(`macToken:${body.macID}`, token);
      if (body.publicKey) {
        await this.state.storage.put(`macPublicKey:${body.macID}`, body.publicKey);
      }
      return json({ macToken: token });
    }

    if (url.pathname === "/pair/create") {
      const body = await request.json<{ codeProof: string; phonePublicKey: string }>();
      const macPublicKey = (await this.state.storage.get<string>(`macPublicKey:${this.macID}`)) ?? "";
      // codeProof 是手机输入的 6 位码，Mac 端用它做校验
      const pairID = randomToken();
      const pairToken = randomToken();
      await this.state.storage.put(`pair:${pairID}`, {
        phonePublicKey: body.phonePublicKey,
        pairToken,
        approved: false,
      });
      // 让 Mac 的 WS 知道有新的配对请求，由 Mac 端自己弹批准
      this.macSocket?.send(
        JSON.stringify({
          type: "pair/request",
          pairID,
          phonePublicKey: body.phonePublicKey,
          code: body.codeProof,
        }),
      );
      return json({ pairID, pairToken, macPublicKey });
    }

    if (url.pathname === "/pair/approve") {
      const body = await request.json<{ pairID: string }>();
      const record = await this.state.storage.get<Record<string, unknown>>(
        `pair:${body.pairID}`,
      );
      if (!record) return json({ error: "unknown_pair" }, 404);
      await this.state.storage.put(`pair:${body.pairID}`, {
        ...record,
        approved: true,
      });
      return json({ ok: true });
    }

    if (url.pathname === "/pair/revoke") {
      const body = await request.json<{ pairID: string }>();
      await this.state.storage.delete(`pair:${body.pairID}`);
      this.iosSockets.get(body.pairID)?.close(4001, "revoked");
      this.iosSockets.delete(body.pairID);
      return json({ ok: true });
    }

    if (url.pathname === "/pair/status") {
      const pairID = url.searchParams.get("pair") ?? "";
      const record = await this.state.storage.get<Record<string, unknown>>(
        `pair:${pairID}`,
      );
      if (!record) return json({ status: "unknown" });
      return json({ status: record.approved ? "approved" : "pending" });
    }

    if (url.pathname === "/health") {
      return json({
        macOnline: this.macSocket !== null,
        iphones: this.iosSockets.size,
      });
    }

    // WebSocket 升级
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const role = url.searchParams.get("role");
    const pairID = url.searchParams.get("pair") ?? "";
    const macID = url.searchParams.get("mac") ?? "";
    const token = url.searchParams.get("token") ?? "";

    if (role === "mac") {
      const expected = await this.state.storage.get<string>(`macToken:${macID}`);
      if (!expected || expected !== token) return new Response("unauthorized", { status: 401 });
      const { 0: client, 1: server } = new WebSocketPair();
      server.accept();
      this.macSocket = server;
      server.addEventListener("message", (event) => {
        this.routeFromMac(event.data as string | ArrayBuffer);
      });
      server.addEventListener("close", () => {
        if (this.macSocket === server) this.macSocket = null;
      });
      return new Response(null, { status: 101, webSocket: client });
    }

    if (role === "ios") {
      const record = await this.state.storage.get<Record<string, unknown>>(
        `pair:${pairID}`,
      );
      if (!record || record.pairToken !== token) {
        return new Response("unauthorized", { status: 401 });
      }
      const { 0: client, 1: server } = new WebSocketPair();
      server.accept();
      this.iosSockets.set(pairID, server);
      server.addEventListener("message", (event) => {
        if (this.macSocket) {
          this.macSocket.send(event.data as string);
        } else {
          server.send(JSON.stringify({ type: "error", error: "mac_offline" }));
        }
      });
      server.addEventListener("close", () => {
        if (this.iosSockets.get(pairID) === server) this.iosSockets.delete(pairID);
      });
      return new Response(null, { status: 101, webSocket: client });
    }

    return new Response("bad role", { status: 400 });
  }

  /** Mac 发来的帧带着信封里的 pair，按它找对应的手机。
   *  注意 Mac 客户端用二进制帧发送，这里必须先解码再解析。 */
  private routeFromMac(raw: string | ArrayBuffer): void {
    const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
    let pairID = "";
    try {
      pairID = JSON.parse(text)?.pair ?? "";
    } catch {
      return;
    }
    const target = pairID ? this.iosSockets.get(pairID) : undefined;
    if (target) {
      target.send(text);
      return;
    }
    // 没有指定 pair（如 pair/request 事件）就广播给所有已连手机
    for (const socket of this.iosSockets.values()) socket.send(text);
  }
}

// ---------- Worker 入口 ----------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({ ok: true, service: "flowcue-remote" });
    }

    const macID = url.searchParams.get("mac") ?? "";
    const id = env.MAC_SESSION.idFromName(macID || "anonymous");
    const stub = env.MAC_SESSION.get(id);

    // 转发到该 Mac 的 Durable Object。
    // 注意路径映射：/v1/remote/mac/register → /register，
    // /v1/remote/pair/create → /pair/create，/v1/remote/ws → /ws。
    const target = new URL(request.url);
    target.pathname = url.pathname
      .replace(/^\/v1\/remote\/mac/, "")
      .replace(/^\/v1\/remote/, "");
    return stub.fetch(new Request(target.toString(), request));
  },
} satisfies ExportedHandler<Env>;
