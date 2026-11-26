/**
 * FlowCue Pages relay endpoint.
 *
 * This is not an HTTP proxy hop. It resolves the existing Durable Object
 * bindings (MAC_SESSION / CODE_INDEX, owned by the flowcue-remote Worker)
 * directly, so a WebSocket upgrade is completed by the same object that owns
 * the relay state. Proxying a WebSocket through a second public Worker was
 * found to lose heartbeat/response frames under load.
 */

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return json({ ok: true, service: "flowcue-remote" });
    }

    const index = env.CODE_INDEX.get(env.CODE_INDEX.idFromName("codes"));

    if (url.pathname === "/v1/remote/code/announce") {
      return index.fetch(new Request("https://index/announce", request));
    }

    if (url.pathname === "/v1/remote/pair/claim") {
      const body = await request.clone().json();
      const code = body.code ?? body.codeProof ?? "";
      const resolved = await index
        .fetch(new Request("https://index/resolve", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ code }),
        }))
        .then((r) => r.json());
      if (!resolved.macID) {
        return json({ error: "unknown_code" }, 404);
      }
      const mac = env.MAC_SESSION.get(env.MAC_SESSION.idFromName(resolved.macID));
      const target = new URL(request.url);
      target.pathname = "/pair/create";
      target.search = `?mac=${resolved.macID}`;
      const result = await mac.fetch(new Request(target.toString(), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          codeProof: code,
          phonePublicKey: body.phonePublicKey,
          phoneID: body.phoneID,
          phoneName: body.phoneName,
        }),
      }));
      if (result.ok) {
        await index.fetch(new Request("https://index/consume", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ code }),
        }));
      }
      const payload = await result.json();
      return json({
        ...payload,
        macID: resolved.macID,
        macPublicKey: payload.macPublicKey || resolved.publicKey || "",
      });
    }

    const macID = url.searchParams.get("mac") ?? "";
    const mac = env.MAC_SESSION.get(env.MAC_SESSION.idFromName(macID || "anonymous"));
    const target = new URL(request.url);
    target.pathname = url.pathname
      .replace(/^\/v1\/remote\/mac/, "")
      .replace(/^\/v1\/remote/, "");
    return mac.fetch(new Request(target.toString(), request));
  },
};
