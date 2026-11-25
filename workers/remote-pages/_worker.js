/**
 * FlowCue Pages relay entry.
 *
 * Cloudflare Workers' default `*.workers.dev` host is blocked by some mobile
 * networks while `*.pages.dev` remains reachable. This Pages Worker proxies
 * HTTP and WebSocket requests to the existing relay Worker, so both hostnames
 * share the same Durable Objects, pairing records and encryption state.
 */

const ORIGIN = "https://flowcue-remote.honaler.workers.dev";

export default {
  async fetch(request) {
    const incoming = new URL(request.url);
    const target = new URL(ORIGIN);
    target.pathname = incoming.pathname;
    target.search = incoming.search;

    // Passing the original Request preserves method, headers, body and the
    // WebSocket Upgrade handshake. Do not forward a Host header: the runtime
    // must derive it from the target URL.
    const headers = new Headers(request.headers);
    headers.delete("host");

    return fetch(new Request(target.toString(), {
      method: request.method,
      headers,
      body: request.method === "GET" || request.method === "HEAD" ? undefined : request.body,
      redirect: "manual",
    }));
  },
};
