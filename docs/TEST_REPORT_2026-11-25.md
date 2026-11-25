# Test report — 2026-11-25

Build: protocol v2, response chunking/zlib, idempotent send, DSH + Codex/Claude
incremental fetch, Codex activity, Claude auth preflight.

## Passed

### Unit / integration

- `swift test`: **153 tests, 2 skipped, 0 failures**.
- `CODEX_IDEA_DOCK_REAL_TEST=1 swift test --filter
  CodexBridgeTests/testRealAppServerReadIsOptIn`: **passed**.
- `ClaudeCodeAdapterSendTests`: **1/1 passed** (`--resume` uses session id).
- Skips: real Codex read opt-in (run separately above), license-key test
  (needs `FLOWCUE_TEST_LICENSE`).

### Builds

- Mac release: `zsh Scripts/build-app.sh` succeeded; app code signature valid.
- iOS Release device build: **BUILD SUCCEEDED**; installed on the iPhone.
- iPhone app launched; Mac release process running; relay protocol `/v1/ping`
  reports `protocol: 2`.

### Remote / transport

- DSH large response: `1,592,087`-byte frame before; now `751,109` bytes in
  `4` chunks. No reconnect loop in the tested run.
- DSH incremental: `?after=100` returned 48 rows (not 148).
- Codex incremental: full 65, `after=64` returned 1 assistant message.
- DSH idempotency: two identical `/v1/dsh/send` POSTs with one `requestID`
  produced **one** user message; Mac logged `idempotent DSH replay`.
- Codex idempotency: two `sendAgent` calls with one `requestID` produced
  **one** Codex user message; Mac logged one POST + `idempotent POST replay`.
- Auth preflight: local `claude auth status` false → `/v1/agents` returned
  Claude `canSend:false`; Codex/DSH `true`.

### Simulator UI

- Composer accepts text (`hello`): **passed (42.2s)** after a fresh Simulator
  boot.
- Codex long-press → `Copy` menu: **passed (19.8s)**.
- DSH large-conversation page: online + scroll view + >5 texts:
  **passed (9.1s)**; no “Couldn't load conversation”.
- Slash menu `/atlas` → `/skill-atlas`: **passed (21.4s)** after moving the
  menu from an inline `VStack` child to a bottom overlay.
- Skill list with bare `/`: shows `/accessibility`; `atlas` filters to
  `/skill-atlas`: **passed (22.2s)**. The menu now shows all 121 skills in a
  scroll view instead of `prefix(30)` (Skill Atlas is index 82). The previous hang
  was a layout loop between menu + keyboard + ScrollView; overlay removes
  the height negotiation.

## Blocked / not run

### Real device

- Release build installed and launched.
- Local Claude CLI is logged out; the logged-in Claude `canSend:true` branch
  cannot be tested here.
- The phone auto-locked during the attempted Codex/real-device rerun; no new
  keyboard/slash or DSH-approval tests were completed on hardware.
- Earlier real-device evidence remains: Codex optimistic send, stored message,
  reply `ok`, idempotency.
- **Real-device slash/keyboard passed:** a temporary DEBUG host opened a Codex
  session on the physical iPhone, focused the composer, set `/atlas`, and the
  keyboard plus `/skill-atlas` menu row were visible in a device screenshot.
  The temporary host was removed and the Release build reinstalled. The
  screenshot was taken while the Mac app was stopped, so the page displayed
  “Mac 不在线”; this does not invalidate the menu/keyboard evidence but the
  online state was verified separately after restarting the Mac.
- **Real-device Mac process drop/recovery passed after a fix:** stopping the
  Mac app changed the phone header from `Codex · 5.xs` to `12 LOCAL`; restarting
  the Mac restored `Codex · 7.5s` **without relaunching the phone app**. The
  first run exposed a stale-offline state; a 3-second foreground
  `checkLiveness()` fallback was added and the retest passed. This is a
  process/relay drop, not a Wi-Fi radio-off test.
- **Pairing-code UX fix:** Mac Settings exposed a local “same Wi-Fi” code and
  a separate announced “remote (5G)” code with nearly identical labels; the
  phone form also put the local field first. Labels now distinguish them and
  the remote section auto-expands when no nearby Mac is found.
- **Remote re-pair fix:** the phone used a stored `macID` and skipped the
  six-digit code claim, so a new code could fail immediately with “wrong code
  or Mac offline”. It now always uses `/v1/remote/pair/claim` for a manually
  entered code, and the foreground watchdog restores remote credentials every
  15s after wake.
- **DSH history pagination:** initial load now requests the newest 60 messages
  instead of the full 126-message / 2.29MB history; “Load earlier messages”
  fetches 40-message windows with absolute `total`/`start`. API verified:
  `tail=60` → start 66, `before=52&limit=40` → start 12 / 40 messages,
  `after=112` → 14 new messages.
- **Latency display fixed:** Devices showed `604ms`/`4.5s` because it used
  `/v1/threads` (Codex session scan) as the latency sample. It now measures
  `/v1/ping` separately and refreshes threads without overwriting the RTT.
- **Codex 0 sessions fixed:** `/v1/agents` concurrently started multiple
  short-lived Codex `app-server` processes against the same state DB; they
  deadlocked, so `/v1/agents` reported Codex 0 while Claude/DSH loaded and
  `/v1/agents/codex/sessions` timed out. Serialized app-server calls with a
  static lock; after restart `/v1/agents` reports Codex 87 and the session list
  loads in 0.28s.
- **5G DSH load/flap fix:** the chat view fired two concurrent full-history
  fetches (2,289,377 bytes / 10 chunks each); a 20s GET timeout then marked the
  whole link offline even though heartbeats were healthy. Removed the duplicate
  initial reload, gave DSH messages a 60s deadline, and stopped treating a
  request timeout as transport loss. Verified the Release build on a 5G iPhone.
- **DSH message presentation fixes:** ordered-list numbering now continues
  across explanation paragraphs (previously every item rendered as `1.`);
  a failed pending message is text-selectable and has a 44pt Retry capsule.
  Codex/Claude optimistic messages use the same 44pt retry affordance.
- **Cellular LAN→relay fallback passed:** with the iPhone on cellular and the
  Mac reachable only through the relay, the page initially showed `12 LOCAL`;
  after the 3-failure fallback it switched to `Codex · 4.4s` and Worker health
  changed to `iphones:1`. The failed-message row now exposes a 44pt Retry
  button instead of a 9.5pt text link.
- **Real-device approval card passed:** injected one external approval through
  `POST /v1/approvals`; the physical iPhone automatically presented the
  Approvals sheet with Approve/Deny. Approving through
  `/v1/approvals/<id>/decide` was reflected and the sheet dismissed. This
  validates the approval UI/polling path, but it was a synthetic external
  approval, not a live DSH bridge `approval/request`.

### Accessibility

Automated `performAccessibilityAudit` ran on Agents and Codex chat:

- Agents: 2 hit-area findings, 2 contrast findings, 9 Dynamic Type
  “partially supported”.
- Codex chat: 9 hit-area findings, 2 contrast findings, 2 Dynamic Type,
  2 text-clipped findings.
- Hit-target fixes were applied to code-copy, send, and slash rows, but the
  re-audit still reports 2/9 hit-area issues; the audit does not expose the
  element label, so these need a manual Accessibility Inspector pass.
- Dynamic Type: body text has an intentional 11pt floor; the audit still
  reports it as partially supported.
- Contrast findings include known false positives under bottom bars/dark
  surfaces; manual contrast calculator pass still needed.
- VoiceOver manual walkthrough not run.

## Verdict

Unit, release builds, remote chunking/idempotency/incremental, agent copy,
composer typing, DSH large-chat rendering, and slash-menu UI are green.
Claude logged-in send, DSH approvals, real-device keyboard/VoiceOver, and an
end-to-end network-drop retry remain unverified.
