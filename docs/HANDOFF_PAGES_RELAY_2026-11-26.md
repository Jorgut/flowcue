# FlowCue Pages Relay Handoff — 2026-11-26

## Goal

FlowCue iPhone must reach the Mac over 5G **without a VPN**. The mobile
network blocks `*.workers.dev`, so we tried to use the already-owned
`*.pages.dev` hostname as the relay entry.

## Current decision

**Pages is not the default.** The app was reverted to the stable Worker:

```text
flowcue-remote.honaler.workers.dev
```

With that endpoint, remote works reliably **only while a VPN is active** on
networks that block `workers.dev`.

The Pages endpoint remains deployed, but is not currently used by the app:

```text
https://flowcue-relay.pages.dev
```

## Repo / build facts

- Checkout: `/Users/aj/Jorgut-Independent Developer/FlowCue/FlowCue-Development`
- Branch: `ui/merge-inbox`
- Latest handoff commit: `54b62fc fix(relay): Pages WebSocket 返回帧不可靠，默认回退 Workers`
- Mac: FlowCue 0.1.6 (11), bundle `com.archintera.FlowCue.Mac`
- iPhone: FlowCue 1.1.18 (109), bundle `com.archintera.FlowCue`
- Protocol v2 (zlib + `RemoteChunk` 240KB, max 128 chunks)
- Tests: `swift test` = 153 tests, 2 skipped, 0 failures

Build/install used during this work:

```bash
zsh Scripts/build-app.sh
xcodebuild -project RerouteMobile.xcodeproj -scheme RerouteMobile \
  -destination "id=00008150-001934981E99401C" -configuration Release \
  -derivedDataPath .build/release-derived -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008150-001934981E99401C \
  .build/release-derived/Build/Products/Release-iphoneos/Reroute.app
```

## Pages implementation

Files:

```text
workers/remote-pages/_worker.js
workers/remote-pages/wrangler.toml
```

Project: `flowcue-relay`, production URL `https://flowcue-relay.pages.dev`.

The current Pages Worker tries to route HTTP and WebSocket to the existing
Durable Objects:

```toml
[[durable_objects.bindings]]
name = "MAC_SESSION"
class_name = "MacSession"
script_name = "flowcue-remote"

[[durable_objects.bindings]]
name = "CODE_INDEX"
class_name = "CodeIndex"
script_name = "flowcue-remote"
```

Deploy:

```bash
cd workers/remote-pages
../remote/node_modules/.bin/wrangler pages deploy . \
  --project-name flowcue-relay --branch main --no-bundle
```

## Evidence

### Pages WebSocket itself works

A temporary `/ws-echo` route in the Pages Worker was tested with a Node
WebSocket client:

```text
sent 20 / received 20 / connection stayed open
```

So Pages can host a WebSocket endpoint. A blanket “Pages cannot do WebSocket”
claim is incorrect.

### FlowCue relay through Pages fails

Real FlowCue traffic:

1. iPhone DSH send reached the Mac:
   ```text
   Mac log: POST /v1/dsh/send → 200
   ```
2. The message actually appeared in DSH.
3. iPhone stayed `SENDING`, then `Not delivered`; no response frame returned.
4. DSH history request:
   ```text
   GET /messages?paginated=1&limit=60&tail=20&textOnly=1 → 200
   14,732 bytes
   ```
   The Mac returned it, but the phone stayed on the spinner and then
   `请求超时`.
5. Health simultaneously showed `iphones:1`, while the app showed
   `心跳超时` / offline.

This isolates the failure to the **Pages → Durable Object WebSocket
pass-through**, not payload size, DSH parsing, or pairing.

### Variants already tried

- Public Pages proxy → Worker: connects, but frames drop.
- Pages **Service binding** → Worker: real WebSocket does not establish.
- Pages direct **Durable Object bindings**: HTTP and handshake work, but
  server→client frames still drop.
- DSH payload reduction: 1.28MB → 620KB → 14.7KB (text-only); same failure.
- Heartbeat tolerance 10s → 20s; does not fix missing response frames.

## Suspected cause / questions for Codex

- Does Cloudflare Pages support returning a WebSocket response obtained from
  a **Durable Object stub** (`env.MAC_SESSION.get(...).fetch(request)`) to a
  client, or only a Pages-owned `WebSocketPair`?
- If DO-stub WebSocket pass-through is unsupported, Pages cannot act as this
  relay without a different transport.
- Verify with a **minimal Pages Function → DO WebSocket echo**; the existing
  echo test used a Pages-owned WebSocketPair, not a DO.
- Check official docs:
  https://developers.cloudflare.com/durable-objects/best-practices/websockets/

## Next options

1. **Custom domain on Worker (recommended)**  
   Bind `flowcue-remote` to a domain the user controls, e.g.
   `relay.example.com`. This removes both the `workers.dev` block and the
   Pages proxy. No Pages Function in the path.

2. **Tailscale**  
   Mac/iPhone join a tailnet; FlowCue uses the Mac's tailnet IP. Stable, but
   requires a persistent VPN-like client.

3. **HTTP polling fallback**  
   Large rewrite: phone→Mac requests and Mac→phone responses over Pages HTTP
   rather than a long-lived WebSocket.

## Important behavior / do not regress

- Never retry a message that actually reached DSH; the app already has
  idempotent `requestID` handling and a 44pt Retry button.
- DSH history pagination: first 20 text-only messages; “Load earlier” 20.
- DSH text-only history intentionally omits old inline images; new incremental
  messages can still carry images.
- Remote foreground adoption: if a tunnel exists but the controller is LOCAL,
  attach/adopt it (`d50feee`).
- Repo rule: only `git add` specific paths; never `git add -A` / `.`.

## Current expected behavior

- App default: Workers endpoint.
- iPhone on 5G without VPN: offline (expected, endpoint blocked).
- iPhone with VPN: stable remote.
- Pages endpoint: deployed but unreliable for FlowCue WebSockets; do not use as
  default until the DO pass-through question is resolved.
