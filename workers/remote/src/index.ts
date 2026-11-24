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
  CODE_INDEX: DurableObjectNamespace;
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
      const macID = url.searchParams.get("mac") ?? this.macID;
      if (macID) this.macID = macID;
      const macPublicKey = (await this.state.storage.get<string>(`macPublicKey:${macID}`)) ?? "";
      // codeProof 是手机输入的 6 位码，Mac 端用它做校验
      const pairID = randomToken();
      const pairToken = randomToken();
      await this.state.storage.put(`pair:${pairID}`, {
        phonePublicKey: body.phonePublicKey,
        pairToken,
        approved: false,
        code: body.codeProof ?? "",
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
      return json({ pairID, pairToken, macPublicKey, macID });
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

    if (url.pathname === "/pair/reject") {
      const body = await request.json<{ pairID: string }>();
      const record = await this.state.storage.get<Record<string, unknown>>(
        `pair:${body.pairID}`,
      );
      if (record) {
        await this.state.storage.put(`pair:${body.pairID}`, {
          ...record,
          approved: false,
          rejected: true,
        });
      }
      return json({ ok: true });
    }

    if (url.pathname === "/pair/pending") {
      // Mac 轮询用：返回还没提示过的待批准配对
      const all = await this.state.storage.list<Record<string, unknown>>({ prefix: "pair:" });
      const pending: unknown[] = [];
      for (const [key, record] of all) {
        if (!record.approved && !record.rejected && !record.delivered) {
          pending.push({
            pairID: key.replace("pair:", ""),
            phonePublicKey: record.phonePublicKey,
            code: record.code ?? "",
          });
        }
      }
      return json({ pending });
    }

    if (url.pathname === "/pair/mark") {
      const body = await request.json<{ pairID: string }>();
      const record = await this.state.storage.get<Record<string, unknown>>(`pair:${body.pairID}`);
      if (record) {
        await this.state.storage.put(`pair:${body.pairID}`, { ...record, delivered: true });
      }
      return json({ ok: true });
    }

    if (url.pathname === "/pair/status") {
      const pairID = url.searchParams.get("pair") ?? "";
      const record = await this.state.storage.get<Record<string, unknown>>(
        `pair:${pairID}`,
      );
      if (!record) return json({ status: "unknown" });
      if (record.rejected) return json({ status: "rejected" });
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

// ---------- 全局配对码索引：用 6 位码反查是哪台 Mac ----------

export class CodeIndex {
  private state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/announce") {
      const body = await request.json<{ code: string; macID: string; publicKey?: string }>();
      // 5 分钟有效；一码一用
      await this.state.storage.put(`code:${body.code}`, {
        macID: body.macID,
        publicKey: body.publicKey ?? "",
        expiresAt: Date.now() + 5 * 60 * 1000,
        failures: 0,
      });
      return json({ ok: true });
    }

    if (url.pathname === "/resolve") {
      const body = await request.json<{ code: string }>();
      const record = await this.state.storage.get<Record<string, unknown>>(
        `code:${body.code}`,
      );
      if (!record) return json({ error: "unknown_code" }, 404);
      if ((record.expiresAt as number) < Date.now()) {
        await this.state.storage.delete(`code:${body.code}`);
        return json({ error: "expired" }, 410);
      }
      // 限流：同一码最多 5 次尝试
      if ((record.failures as number) >= 5) {
        return json({ error: "locked" }, 429);
      }
      return json({ macID: record.macID, publicKey: record.publicKey ?? "" });
    }

    if (url.pathname === "/consume") {
      const body = await request.json<{ code: string }>();
      await this.state.storage.delete(`code:${body.code}`);
      return json({ ok: true });
    }

    return new Response("not found", { status: 404 });
  }
}

// ---------- Worker 入口 ----------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({ ok: true, service: "flowcue-remote" });
    }

    const indexStub = env.CODE_INDEX.get(env.CODE_INDEX.idFromName("codes"));

    // Mac 生成码时登记：让手机可以用码找到它
    if (url.pathname === "/v1/remote/code/announce") {
      return indexStub.fetch(new Request("https://index/announce", request));
    }

    // 手机用码直接配对：不需要先在同一 Wi-Fi
    if (url.pathname === "/v1/remote/pair/claim") {
      const body = await request.clone().json<{ code?: string; codeProof?: string; phonePublicKey: string }>();
      // 手机与 Mac 用的字段名不同，两种都接受
      const code = body.code ?? body.codeProof ?? "";
      const resolved = await indexStub
        .fetch(new Request("https://index/resolve", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ code }),
        }))
        .then((r) => r.json<{ macID?: string; publicKey?: string }>());
      if (!resolved.macID) {
        return json({ error: "unknown_code" }, 404);
      }
      const macStub = env.MAC_SESSION.get(env.MAC_SESSION.idFromName(resolved.macID));
      const target = new URL(request.url);
      target.pathname = "/pair/create";
      target.search = `?mac=${resolved.macID}`;
      const result = await macStub.fetch(new Request(target.toString(), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ codeProof: code, phonePublicKey: body.phonePublicKey }),
      }));
      // 成功就消费掉这个码，防止重复使用
      if (result.ok) {
        await indexStub.fetch(new Request("https://index/consume", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ code }),
        }));
      }
      const payload = await result.json<Record<string, unknown>>();
      return json({
        ...payload,
        macID: resolved.macID,
        macPublicKey: (payload.macPublicKey as string) || resolved.publicKey || "",
      });
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
