# Remote stability: root causes and fixes

Updated 2026-11-25. Scope: iPhone (FlowCue) ↔ Cloudflare Worker/Durable
Object ↔ Mac (FlowCue). The symptoms were: chat shows **offline / Couldn't
load conversation**, a message stays **Not delivered**, and after reconnect
the same screen fails again.

## Evidence

- Mac `~/.flowcue/relay.log`:
  - `response too large: 1592087 bytes` for
    `/v1/dsh/sessions/<id>/messages`
  - `decrypt failed: replay(seq: 133)` / `replay(seq: 3)`
- iOS console: `transport failure`, reconnect every 1–5 seconds; no
  application-level close reason because the Worker closes the socket.
- DSH session had **67 messages / 851 KB JSON**, including a **771 KB
  base64 JPEG** in one message. `RemoteResponse.body` is `Data`, so
  `JSONEncoder` base64-encodes the whole thing again. The resulting
  encrypted WebSocket frame was **1,592,087 bytes**.
- Cloudflare WebSocket messages have a **1 MiB** limit. Exceeding it closes
  the socket. Reconnect reloads the same 1.59 MB response → close again:
  a reconnect loop.
- `iphones:0` in the health endpoint was observed while requests were still
  flowing; treat that counter as unreliable for now.

## Root causes

1. **Payload > 1 MiB (primary)**
   DSH history with inline screenshots exceeded the relay's WebSocket frame
   limit. Base64 was applied twice (image inside JSON, body as Data).
2. **Mac decoded frames in parallel, not in arrival order**
   Each encrypted frame started an independent `Task`; the actor serialized
   `openEnvelope`, but task scheduling could run seq 4 before seq 3. Seq 3
   was then rejected as `replay` and its response was never sent.
3. **iPhone sent frames in parallel, not in request order**
   Each request started its own send `Task`; WebSocket sends could be
   scheduled out of order, producing the same lower-seq-after-higher-seq
   rejection on the Mac.
4. **Pending registered after send**
   The response could arrive before the continuation was stored, so the
   response was dropped and the request waited for its timeout.
5. **Reconnect backoff reset on greeting**
   Any frame (including the `mac/online` greeting) reset `reconnectAttempt`
   to 0, so a server-side close loop reconnected every second instead of
   backing off.

## Fixes

- **Response chunking**: Mac splits responses >320 KB into 240 KB encrypted
  `RemoteChunk`s (max 128). iPhone reassembles by request id before decoding.
  A 751 KB DSH response now travels as 4 frames, each well below 1 MiB.
- **zlib compression** for response bodies >32 KB before chunking; text-heavy
  payloads shrink; already-compressed JPEGs are handled by chunking.
- **Serial frame processing** on Mac (`frameChain`) and **serial send queue**
  on iPhone (`sendChain`) preserve seq order.
- **Register pending before sending**, with timeout/failure paths.
- **Reset reconnect backoff only after a real encrypted response**, not after
  the greeting; failures now back off (1s, 2s, 4s…).
- **413 fallback** if a response would need more than 128 chunks.
- Request/response logs include frame byte counts and chunk counts.

## Verification

- DSH chat (67 messages with image):
  - before: 1,592,087-byte frame → close/reconnect loop.
  - after: `chunked response ... bytes=751109 chunks=4`; iOS stays online;
    conversation renders in the Simulator (messages + “DSH is working…”).
- Fresh logs after the fix: **0** `decrypt failed`, **0** iOS transport
  failures while idle/polling for ~1 minute.
- `swift test`: 153 tests, 2 skipped, 0 failures.

## Remaining risks / next work

- DSH still refetches the **full history every ~3 seconds**. Chunking makes it
  safe but still costs bandwidth/battery. Add incremental fetch
  (`since`/version/ETag) and cache messages by revision.
- Repeat the same chunking check for the Mac→iPhone direction on a large
  Codex/Claude conversation; Codex currently ~24 KB per response.
- The relay health counter `iphones` can be stale; do not use it as the only
  connectivity truth. Use WebSocket frames + app-level requests.
- Transient `Socket is not connected` can still happen on Wi-Fi/cellular
  handoff; the client now recovers with backoff, but a send may still need
  the visible Retry.
- Inline base64 images are the main payload risk. Consider thumbnails or
  on-demand image fetch for remote chat.
