# FlowCue Remote MVP — PRD & Technical Plan

Status: Draft for review  
Date: 2026-11-24  
Scope: Mac + iPhone only. Windows/Linux nodes are out of scope; see `docs/REMOTE_NODES.md`.

> Current release (0.1.6) is **all free**: Mac local, iPhone same-Wi-Fi, no subscription. Remote is not built or sold yet. This document is the plan for the next iteration; nothing in the pricing section is live.

## 0. One sentence

**Remote lets the iPhone reach the user's Mac when both are not on the same Wi-Fi, using an outbound relay and end-to-end encryption, so the existing LAN experience — read sessions, send messages, approve commands — keeps working away from the desk.**

The Mac must be awake and running FlowCue. Remote is not a cloud agent, not a remote desktop, and not a way to run agents when the Mac is off.

## 1. Why now

Today FlowCue only works on the same LAN:

- Mac advertises `_flowcue._tcp` and serves `/v1/*` on the local network.
- iPhone discovers the Mac, uses a 6-digit pairing code, and connects directly.
- No relay, no account, no third-party server.

That is enough at the desk, but not for the core promise: an idea or an approval should reach the user when they are away. The paid Remote tier is the first feature that has ongoing server cost and a clear reason to subscribe.

## 2. Goals

1. iPhone connects to the Mac from cellular or another Wi-Fi without port forwarding.
2. The existing `/v1` feature set works remotely: agents, sessions, messages, send, approvals, questions, ideas, push token.
3. Same-Wi-Fi remains free and keeps working with no subscription.
4. The relay cannot read prompts, replies, code, or approval content.
5. Remote is gated by an iOS subscription that is verified server-side.
6. A user can revoke a paired iPhone from the Mac.
7. The experience is understandable without a networking manual: "Remote on" on Mac, scan/pair on iPhone.

## 3. Non-goals

- Running agents in the cloud when the Mac is asleep or off.
- Screen sharing, mouse/keyboard control, or remote desktop.
- Team/shared inboxes, shared Macs, or multiple users.
- Multiple Macs in the first release (one Mac + one iPhone).
- Windows/Linux node support in this release.
- Voice control, file transfer, or Live Activities in the MVP.
- A FlowCue account or a web dashboard.
- A Mac license or Paddle checkout. Remote is sold through the iOS App Store only.

## 4. Users and jobs

### Primary user

A developer who runs Codex, Claude Code, or DSH on a Mac, pairs the iPhone on the same Wi-Fi, and wants to leave the desk without losing the session.

### Jobs to be done

- "When an agent stops for approval, I want the approval on my phone, even on cellular."
- "When I'm in another room or another network, I want to send the next instruction to the session I already have."
- "I don't want to configure a VPN, a port, or a router."
- "I don't want my prompts and code going through a server that can read them."

### Trigger

The user turns on **Remote** on the Mac and pairs an iPhone. From then on the iPhone prefers LAN when reachable and falls back to Relay otherwise.

## 5. Product scope (MVP)

| Capability | MVP | Notes |
|---|---|---|
| Remote on/off on Mac | ✅ | Explicit toggle, not always-on |
| QR pairing | ✅ | Primary path |
| 6-digit code pairing | ✅ | Fallback; short TTL |
| iPhone shows LAN/Remote state | ✅ | Auto selection |
| List agents/sessions | ✅ | Reuse `/v1/*` |
| Read messages | ✅ | Reuse `/v1/*` |
| Send message | ✅ | Idempotency required |
| Approvals / questions | ✅ | Reuse `/v1/dsh/*` |
| Push notification for approval | ✅ | Reuse existing APNs from Mac |
| Reconnect after network change | ✅ | Exponential backoff |
| Mac offline/asleep state | ✅ | Clear error, no fake queue |
| Revoke iPhone | ✅ | Mac + relay |
| E2E encryption | ✅ | Launch blocker |
| iOS subscription gate | ✅ | Server verified |
| Multiple Macs | ❌ | Later |
| Live Activities/widgets | ❌ | Later |
| Voice | ❌ | Later |
| Android | ❌ | Later |
| Team | ❌ | Never in this product direction |

### Success metrics

- Remote enable rate among paired users.
- Pairing success rate (QR/code) ≥ 90%.
- Remote connection success ≥ 99% (excluding Mac offline).
- Approval latency p95 < 2 s after tap.
- Remote approvals per weekly active user.
- Free → Remote conversion after 14-day trial.
- Monthly churn and refund rate.
- Relay error rate and cost per paid user.

Guardrails: no content in relay logs; crash-free sessions; no duplicate sends.

## 6. UX flows

### 6.1 Enable Remote on Mac

1. Mac Settings → Remote.
2. Toggle **Allow Remote**.
3. Mac shows:
   - status `Remote on`
   - a QR code
   - a 6-digit fallback code (5 min)
   - connected iPhones list
4. If the Mac is asleep or offline, the iPhone must say so; do not pretend the request was delivered.

### 6.2 Pair iPhone

1. iPhone Agents → **Pair a Mac** → **Remote**.
2. Scan the QR (preferred) or enter the 6-digit code.
3. Mac shows `iPhone <name> wants to pair` with **Allow** / **Deny**.
4. Both show a 6-digit safety code; user confirms they match.
5. Pair is stored in Keychain on both sides; relay stores public keys and pair metadata.
6. Success: iPhone shows `Remote ready`.

### 6.3 Use away from the desk

1. iPhone tries LAN first (Bonjour/known address).
2. If LAN fails within 1.5 s, connect to relay.
3. Show a small `Remote` badge and latency, not a modal.
4. Session list, chat, send, approvals behave exactly like LAN.
5. If the subscription expired: show paywall for Remote, keep LAN usable.

### 6.4 Push

- Existing flow: Mac sends APNs directly using the iPhone device token uploaded over `/v1/push/token`.
- Remote does not require a new push backend in MVP.
- Push payload must not contain prompt text, code, or approval details; only `Approval needed` / `Question waiting` and a deep link.
- Tapping opens the session and triggers a refresh over LAN or relay.

### 6.5 Revoke

- Mac → Remote → paired iPhone → **Revoke**.
- Relay removes the pair immediately.
- iPhone deletes local pair keys; next connection returns `pair_revoked`.
- Lost phone: revoke from Mac is the recovery path.

### 6.6 Error states

| State | UI |
|---|---|
| Mac offline | `Mac is offline. Remote needs the Mac awake.` |
| Mac asleep | `Mac is asleep. Wake it to continue.` |
| Relay unreachable | `Remote relay unavailable. Retrying.` |
| Subscription expired | Paywall; LAN still works |
| Pair revoked | `This iPhone was removed from the Mac.` |
| Protocol mismatch | `Update FlowCue on Mac/iPhone.` |

## 7. Pricing and entitlement

- **LAN / same Wi-Fi:** free, forever. No subscription check.
- **Remote:** iOS auto-renewable subscription.
  - `com.archintera.FlowCue.Remote.Monthly` — **$5.99/month**
  - `com.archintera.FlowCue.Remote.Yearly` — **$49.99/year**
  - 14-day introductory free trial.
  - One subscription covers one Apple ID; one Mac + one iPhone in MVP.
- **No Mac license, no Paddle, no 1,999 lifetime in this release.**
- Apple handles billing, tax, refunds, and cancellation.
- Server-side entitlement:
  - iOS sends the StoreKit 2 signed transaction to the relay.
  - Relay verifies the JWS with Apple's root certificates and stores `originalTransactionId`, `appAccountToken`, product, expiry, environment.
  - App Store Server Notifications V2 keep renewals/refunds in sync.
  - Grace period: 7 days after expiry, then Remote is disabled; LAN never gated.
- Restore Purchases must work; `AppStore.sync()` then re-submit the current entitlement.
- Free trial and price are configured in App Store Connect, not in code.

### Paywall copy

> **Remote**
> Use FlowCue when you're not on the same Wi-Fi.
> • Read and reply from anywhere
> • Approve commands and answer questions
> • End-to-end encrypted
> $5.99/month or $49.99/year · 14-day free trial
> The Mac must be awake and running FlowCue.
>
> Same-Wi-Fi use stays free.

## 8. Architecture

```
iPhone                         Relay (Cloudflare)                      Mac
┌──────────────┐   WSS   ┌─────────────────────────┐   WSS   ┌──────────────────┐
│ RemoteClient │ ──────► │ Worker + Durable Object │ ◄────── │ RemoteRelayClient │
│ (URLSession  │         │  route by pair ID       │         │ (outbound only)  │
│  WebSocket)  │         │  no plaintext           │         │                  │
└──────────────┘         └─────────────────────────┘         └────────┬─────────┘
                                                                      │
                                                              ┌───────▼────────┐
                                                              │ RemoteAPI      │
                                                              │ (same /v1      │
                                                              │  handlers)     │
                                                              └───────┬────────┘
                                                                      │
                                                              ┌───────▼────────┐
                                                              │ Agent adapters │
                                                              │ Codex/Claude/  │
                                                              │ DSH            │
                                                              └────────────────┘
```

### Why a relay

- No inbound ports, no router configuration, no public IP.
- Reliable across cellular, CGNAT, and changing Wi-Fi.
- A single place for entitlement checks, rate limits, and revocation.
- Reusable for Windows/Linux nodes later (`REMOTE_NODES.md` M4), with the same envelope.

### Why not Tailscale only

Tailscale works for technical users and can remain an advanced path, but a paid product cannot require every user to install and configure a tailnet. Tailscale may be offered later as a free/advanced option; it is not the MVP.

### Cloudflare components

- **Worker** `flowcue-remote`: HTTP control API + WebSocket upgrade.
- **Durable Object** per Mac: owns the Mac WebSocket, routes frames to paired iPhones, tracks presence.
- **D1**: Macs, pairs, entitlements, revocation, audit metadata.
- **KV** (or D1 with TTL): short-lived pairing codes.
- **APNs**: existing Mac-direct sender; no relay APNs key in MVP.
- **App Store Server API**: entitlement verification and notifications.

## 9. Protocol

### 9.1 Transport

- WSS only, TLS 1.2+.
- Binary or text frames; JSON envelope for MVP, base64 ciphertext.
- Maximum frame size: 1 MB; chat payloads are far smaller.
- Ping/pong every 20 s; idle timeout 60 s.
- One Mac socket per Mac; one iPhone socket per pair.

### 9.2 Envelope

```json
{
  "v": 1,
  "pair": "pair_uuid",
  "seq": 42,
  "nonce": "base64",
  "ciphertext": "base64"
}
```

The relay only reads `pair`, `seq`, `nonce`, and size. Everything else is opaque.

### 9.3 Decrypted request/response

```json
{
  "id": "request_uuid",
  "kind": "request",
  "method": "GET",
  "path": "/v1/agents",
  "headers": { "x-flowcue-version": "1" },
  "body": null
}
```

```json
{
  "id": "request_uuid",
  "kind": "response",
  "status": 200,
  "headers": { "content-type": "application/json" },
  "body": "base64..."
}
```

The Mac dispatches to the same `RemoteAPI` router used by `LANRemoteServer`; the iPhone decodes the same JSON as LAN. No endpoint fork.

### 9.4 Pairing

1. Mac generates an X25519 identity keypair and a random `mac_id`.
2. Mac registers `mac_id` + public key with the relay; receives `mac_token`.
3. Mac displays QR:
   `flowcue://remote?relay=wss://remote.flowcue.app&mac=<id>&key=<base64>&code=<one-time>`
   and the 6-digit code.
4. iPhone generates an X25519 keypair; sends `pair/request` with its public key and code proof through the relay.
5. Relay verifies the one-time code (hash, TTL 5 min, max 5 attempts) and forwards to Mac.
6. Mac shows `Allow/Deny`; on allow, both derive:
   - `shared = X25519(private, peerPublic)`
   - `key = HKDF-SHA256(shared, salt=pair_id, info="flowcue-remote-v1")`
   - per-direction keys and a 6-digit SAS for visual confirmation.
7. Relay stores `pair_id`, `mac_id`, iPhone public key, created/last-seen/revoked. It never sees the shared secret.
8. Both store pair keys in Keychain.

### 9.5 Crypto

- X25519 key agreement; HKDF-SHA256; ChaChaPoly or AES-GCM.
- Per-direction keys: iPhone→Mac and Mac→iPhone.
- Monotonic `seq` per direction; replay window of 64; reject old/duplicate seq.
- `pair_id` and random nonce in every frame.
- Keys rotate on re-pair; old pair keys are deleted.
- Mac identity key in Keychain; iPhone pair key in Keychain. X25519 is not a Secure Enclave key type; if hardware-backed keys are required later, switch the pairing curve to P-256 and use Secure Enclave.
- No plaintext fallback. If crypto setup fails, Remote is off, not "TLS only."

### 9.6 Relay control API

- `POST /v1/remote/mac/register` — Mac identity + public key; returns `mac_token`.
- `POST /v1/remote/pair/start` — iPhone starts with code.
- `POST /v1/remote/pair/approve` — Mac approves; returns pair id.
- `POST /v1/remote/pair/revoke` — Mac revokes.
- `POST /v1/remote/entitlement` — iPhone submits signed transaction.
- `GET /v1/remote/entitlement` — current status.
- `GET /v1/remote/ws?role=mac|ios&pair=...` — WebSocket upgrade, `Authorization: Bearer <token>`.
- `POST /v1/remote/push/token` — iPhone uploads APNs token through relay when not on LAN.
- All control endpoints rate-limited per IP/device.

### 9.7 Offline behavior

- Relay does not store message content.
- If Mac is offline, relay returns `mac_offline` immediately; no fake success.
- iPhone retries connection with backoff; sends are disabled while offline.
- A send request carries an idempotency key; Mac's existing executor ledger prevents duplicate execution.
- If a request times out, show `uncertain` rather than retrying automatically.

## 10. Security and privacy

### Threat model

| Threat | Mitigation |
|---|---|
| Relay reads content | E2E; relay only sees envelope |
| Malicious relay | E2E + pinned relay TLS; safety code |
| Pairing MITM | One-time code + Mac approval + SAS; rate limit |
| Stolen iPhone | Revoke from Mac; pair keys deleted on revoke |
| Replay | Per-direction seq + nonce |
| Abuse / scanning | Rate limits, short TTL, max attempts |
| Subscription bypass | Server-side StoreKit JWS verification |
| Prompt/code leak in logs | Redact; never log decrypted bodies |

### Privacy

- Relay sees: pair ID, mac/iPhone IDs, timestamps, frame sizes, IP, connection metadata.
- Relay does not see: prompts, replies, code, file paths, approvals, titles, device names (hash device names if used).
- Metadata retention: 30 days; content: never.
- APNs payload: generic text; no content.
- App Store privacy manifest: network encryption, local network, no tracking.
- Security review before public launch; external audit optional but recommended.

### Mac sleep

- Do not silently prevent sleep. Show `Mac will sleep; Remote will disconnect`.
- Optional Settings toggle: `Keep Mac awake while Remote is on` using `ProcessInfo.beginActivity` / `IOPMAssertion`; default off; clear energy warning.
- If asleep, iPhone shows `Mac is asleep`; no wake-on-LAN in MVP.

## 11. Data model (D1)

```sql
CREATE TABLE remote_macs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  public_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE remote_pairs (
  id TEXT PRIMARY KEY,
  mac_id TEXT NOT NULL,
  ios_name TEXT NOT NULL,
  ios_public_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE remote_entitlements (
  app_account_token TEXT PRIMARY KEY,
  original_transaction_id TEXT NOT NULL,
  product_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  environment TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE remote_pair_codes (
  code_hash TEXT PRIMARY KEY,
  mac_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  used_at TEXT
);
```

No table stores prompts, replies, file paths, or approval payloads.

## 12. Client changes

### Mac

- New `RemoteRelayClient` (outbound WSS, reconnect, heartbeat).
- Refactor `LANRemoteServer` request handling into `RemoteAPI` so LAN and relay share one router.
- New Settings → Remote: toggle, QR, code, paired devices, revoke, keep-awake option.
- Pairing keys in Keychain; relay token in Keychain.
- Status in menu bar: `Remote on / reconnecting / off`.
- Existing APNs sender unchanged; push token can also be uploaded over relay.

### iPhone

- New `RemoteRelayTransport` behind a `RemoteTransport` protocol:
  - `LANDirectTransport` (existing Network.framework HTTP).
  - `RelayTransport` (URLSessionWebSocketTask).
- Auto selector: LAN first, relay fallback.
- Pairing UI: QR scanner + code fallback + Mac approval; SAS confirmation.
- Agents/Chat/Approvals reuse existing views; only transport and badges change.
- Subscription paywall for Remote only; LAN remains usable without it.
- Restore Purchases; entitlement status in Me/Settings.
- Push deep link: `flowcue://session/<id>` / approval.

### Shared

- `RemoteProtocol` envelope encode/decode.
- `RemoteCrypto` X25519/HKDF/ChaChaPoly.
- `RemotePairing` QR payload parsing.
- Tests for crypto vectors, replay, pairing, revocation, protocol version.

## 13. Entitlement and App Store

- Create subscription group **FlowCue Remote** with monthly/yearly products.
- 14-day free trial; price $5.99/$49.99.
- StoreKit 2 purchase; send `Transaction.jwsRepresentation` to relay.
- Relay verifies with Apple root certs / App Store Server API; stores entitlement.
- App Store Server Notifications V2 endpoint: `https://remote.flowcue.app/v1/appstore/notifications`.
- Revoke/refund → mark expired; active sockets get `subscription_expired` on next request.
- Grace: 7 days after expiry; then require renewal for Remote.
- No account; `appAccountToken` is a random UUID generated at purchase.
- Family Sharing: off for Remote MVP; revisit.
- App Store review notes: Remote requires a Mac running FlowCue; LAN is free; subscription unlocks relay only.

## 14. Observability

Metrics (aggregate, no content):

- `remote_pair_started`, `remote_pair_approved`, `remote_pair_failed`
- `remote_ws_connected`, `remote_ws_disconnected`, `remote_ws_reconnect`
- `remote_request_total{method,status}`
- `remote_request_duration_ms`
- `remote_mac_offline`
- `remote_entitlement_check{result}`
- `remote_push_sent`, `remote_push_opened`
- relay CPU/duration, DO storage, D1 rows.

Alerts: connection success < 95%, p95 latency > 3 s, entitlement verification failures, relay 5xx.

Logs: pair ID prefix, status, duration; never body or path? Path is inside ciphertext; relay doesn't see it. Mac logs can include endpoint but not content.

## 15. Milestones

| Phase | Scope | Estimate |
|---|---|---|
| M0 | Relay spike: Worker + DO echo, Mac/iOS WSS clients, presence | 3–5 days |
| M1 | Pairing: QR, code, Mac approval, X25519, E2E, revocation | 5–7 days |
| M2 | Protocol: `RemoteAPI` refactor, iPhone transport, LAN/Remote switch | 3–5 days |
| M3 | Push, reconnect, Mac sleep state, offline/uncertain | 3–5 days |
| M4 | StoreKit products, JWS verification, server notifications, paywall | 3–5 days |
| M5 | TestFlight, security review, App Store review, docs | 5–10 days |

Total: **6–8 weeks** for one developer, including buffer. M1 and M4 are the highest-risk.

### Exit criteria per phase

- M0: Mac and iPhone exchange an encrypted ping through relay; Mac offline returns error.
- M1: Pair via QR; revoke; wrong code fails; replay rejected.
- M2: All `/v1` endpoints work over relay; LAN still free and faster.
- M3: Kill Wi-Fi mid-request; reconnect; no duplicate send; push opens correct session.
- M4: Sandbox purchase unlocks; expiry/refund locks; LAN unaffected.
- M5: TestFlight 20 users; crash-free > 99.5%; App Store approved.

## 16. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Relay abuse / cost | High | auth, rate limits, per-pair quotas, Cloudflare budget alerts; target < $0.50/paid user/month at 1k users, review monthly |
| E2E bugs | High | test vectors, audit, fail closed |
| App Store rejection | High | review notes, no external purchase links, clear subscription value |
| Mac sleep | Medium | explicit state, optional keep-awake |
| Network changes | Medium | reconnect/backoff, LAN fallback |
| Pairing UX | Medium | QR primary, code fallback, Mac approval |
| Subscription bypass | Medium | server-side JWS, notifications |
| Privacy claim | High | no content logs, retention policy, security page |
| Single-dev scope | Medium | one Mac/one iPhone; no voice/team/Live Activities |

## 17. Acceptance criteria

1. From a different Wi-Fi/cellular, a paired iPhone can list agents and sessions.
2. It can read messages, send a message, and approve/deny a command.
3. A wrong pairing code fails after 5 attempts; a revoked pair cannot reconnect.
4. Relay logs and D1 contain no prompt/reply/code content.
5. Killing Wi-Fi mid-request reconnects; a timed-out send is `uncertain`, not duplicated.
6. Subscription purchase unlocks Remote; expiry/refund locks Remote; LAN stays free.
7. Mac asleep/offline shows a clear state; no fake success.
8. App Store review passes with the subscription description and privacy answers.

## 18. Verification plan

### Unit

- Envelope encode/decode, sequence/replay, key derivation vectors.
- Pairing code TTL/attempts, revocation, QR payload parser.
- Entitlement JWS verification fixtures (active, expired, revoked, sandbox/production).
- Idempotency key behavior; timeout → uncertain.

### Integration

- Fake relay (local WebSocket server) + two clients; all `/v1` endpoints.
- LAN → relay fallback; relay → LAN recovery.
- Mac offline, relay offline, slow network, packet loss, 30-minute soak.
- Two iPhones cannot use the same pair; revoked device rejected.
- Relay logs assert no prompt/reply content.

### Device

- iPhone on cellular, Mac on home Wi-Fi.
- iPhone on a different Wi-Fi; Mac on Ethernet.
- Mac sleep/wake; Wi-Fi change; VPN on/off.
- Push cold start → deep link → session refresh.
- StoreKit sandbox: purchase, restore, expiry, refund, grace.

### Security

- Attempt pairing with wrong code 10×; verify lockout.
- Replay old frames; verify rejection.
- Tamper ciphertext; verify auth failure.
- Revoke during active socket; verify next request fails.
- Inspect relay D1/logs; verify no content.

### Release gate

- TestFlight 20 users for 1 week.
- Crash-free > 99.5%, connection success > 99%, p95 approval < 2 s.
- App Store review approved; privacy answers consistent.

## 19. Open questions

1. One Mac + one iPhone is confirmed for MVP; when do we add multiple Macs?
2. QR-only or QR + 6-digit fallback at launch? (Recommend both; QR primary.)
3. Is 14-day trial right for a $5.99/month product?
4. Keep-awake default off? (Recommend off.)
5. Relay region/data residency: Cloudflare automatic; any EU requirement?
6. Should Tailscale be a free advanced path? (Later.)
7. Do we need a web lifetime option? (No for this release; iOS only.)
8. Android timing after iOS Remote proves retention.
9. Do we need an external security audit before launch? (Recommend at least a focused review.)
10. What is the maximum supported message/frame size? (1 MB MVP.)

## 20. Current code map

Existing:

- `Sources/CodexIdeaDockCore/LANRemoteServer.swift` — `/v1/*`, Bearer pairing code, Bonjour.
- `Sources/RerouteMobileApp/RerouteMobileApp.swift` — `LANRemoteController`, discovery, HTTP client, Agents UI, APNs registration.
- `Sources/CodexIdeaDockCore/ProEntitlement.swift` — legacy entitlement sync; Remote will use its own StoreKit verification, not this.
- `Sources/CodexIdeaDockCore/DSHBridgeClient.swift` — approvals/questions.
- `Support/MobileInfo.plist` — local network usage; add remote relay domain if needed.
- `docs/REMOTE_CONTINUATION.md` — same-LAN behavior.
- `docs/REMOTE_NODES.md` — Windows/Linux nodes and the future relay route.

New:

- `Sources/CodexIdeaDockCore/RemoteProtocol.swift`
- `Sources/CodexIdeaDockCore/RemoteCrypto.swift`
- `Sources/CodexIdeaDockCore/RemoteRelayClient.swift`
- `Sources/CodexIdeaDockCore/RemoteAPI.swift` (shared router)
- `Sources/RerouteMobileApp/RemoteRelayTransport.swift`
- `Sources/RerouteMobileApp/RemotePairingView.swift`
- `site/workers/remote/` or `workers/remote/` — Worker + DO + D1 migrations
- `docs/REMOTE_MVP.md` — this file

## 21. Decision log

- 2026-11-24: Same-Wi-Fi free; Remote paid via iOS subscription; no Mac license.
- 2026-11-24: Relay route over Tailscale-only; E2E required for launch.
- 2026-11-24: One Mac + one iPhone in MVP; no team/multi-node.
- 2026-11-24: Push stays Mac-direct for MVP; no relay APNs key.
- 2026-11-24: Remote price $5.99/month, $49.99/year, 14-day trial; no lifetime at launch.
- 2026-11-24: `RemoteCryptoSession` 落地（X25519 + HKDF-SHA256 + ChaChaPoly，
  分方向密钥、单调 seq、64 帧重放窗口），6 项单元测试通过。中继尚未开始。
- 2026-11-24: `RemoteRelayStub` 落地（Network.framework，4 字节长度前缀 + 握手帧，
  按 pair 转发，对端不在返回 `mac_offline`）。3 项测试通过：加密帧穿越、
  离线报错、pair 隔离。完整套件 135 项通过。


