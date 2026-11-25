# Known issues

Updated 2026-11-25 12:10. “Fixed” means verified on the build in this
workspace; “open” means not yet fixed or not yet verified.

## Fixed in the current build

- Codex send visibility: optimistic bubble + 3 s polling + scroll anchor.
- Codex failure → Retry → re-send (fault-injection UI test).
- Codex Markdown, copy/select, slash menu, convergence.
- Remote large-DSH disconnect loop: response chunking (240 KB chunks),
  zlib compression, 128-chunk cap, small 413 fallback.
- Mac frame order and iPhone send order now serialized; pending registered
  before send; reconnect backoff no longer resets on the greeting.
- Claude Code restored in Mac/iOS agent lists; Claude Desktop is separate.

## Open functional issues

1. **Codex/Claude AgentChatView and DSH send retries are idempotent**
   (stable request id; Mac replays the cached POST/DSH success response).
   A send still shows “Not delivered” after a drop and needs a manual Retry,
   but retry no longer duplicates the turn.
   **DSH e2e verified:** two identical `/v1/dsh/send` POSTs with the same
   `requestID` produced one user message; Mac logged `idempotent DSH replay`.
   **Codex e2e verified:** two `sendAgent` calls with one `requestID` produced
   one Codex user message; Mac logged one real POST + `idempotent POST replay`.
   Claude shares the same AgentChatView/cache path; its duplicate test is
   pending CLI login.
2. **Incremental fetch is implemented for DSH and Codex/Claude**
   (`?after=<count>`; Mac slices the history, LAN query parsing fixed).
   The first open still fetches the full history (chunked); subsequent polls
   only fetch new messages. Codex/Claude append new messages client-side.
   A 1000-message cap per response remains.
3. **Protocol v2 is enforced in the LAN/pair handshake.** `/v1/ping` returns
   protocol 2; old Mac/iPhone pairs show an update prompt instead of timing
   out. Remote-pair upgrades are not separately version-gated.
4. **Claude Code send is now auth-aware.** `/v1/agents` runs
   `claude auth status` (30s cache) and sets `canSend:false` when the local
   CLI is logged out; iOS disables the composer and shows
   “Claude Code is not signed in — run `claude auth login`”. Verified locally:
   Claude `canSend:false`, Codex/DSH `true`. A logged-in tester has not been
   re-tested yet.
5. **Codex activity is implemented** by tailing its session JSONL
   (`task_started`/`task_complete`, 90s stale guard) and returning
   “Codex is working…”. A real running turn was not observed during the test
   (the queued test turn stayed interrupted), so the active-state render still
   needs a live Codex run. Claude has no activity signal.
6. **DSH approvals/questions and a new DSH/Codex send** were not fully
   re-tested after the transport changes. Read path and incremental cursor
   are verified; write/approval path needs a fresh real-device pass.

## Open infrastructure / monitoring issues

7. **`/v1/remote/health` `iphones` count is unreliable.** It showed 0 while
   the phone was actively sending requests. Do not use it as the only online
   truth; UI uses WebSocket state and requests.
8. **Transient network/Worker closures are reduced, not eliminated.**
   Wi-Fi/cellular handoff can still drop the socket; reconnect now backs off
   and recovers, but one send may still need manual Retry.
9. **Mac force-quit offline detection latency** can be up to the heartbeat
   window (~15 s) depending on how the relay notices the closed socket; not
   fault-injected this round.

## UI / accessibility

10. VoiceOver manual walkthrough is not done.
11. Base body text is 11 pt (with a readability floor); the automated audit
    labels Dynamic Type as partially supported.
12. Contrast audit has false positives for content under the bottom bars;
    a manual Accessibility Inspector pass is pending.
13. Real-device long-press copy was not automated (Simulator UI test passed;
    the same `textSelection` code is shared).

## Features not implemented

14. Claude Desktop (`claude.app`) has no local API. Only a terminal
    Accessibility/clipboard prototype exists; it is **not** integrated into
    FlowCue. Claude Code CLI remains the supported Claude path.
15. No incremental/paginated message API; no image thumbnail/on-demand fetch.
16. Changes are uncommitted; macOS notarization and iOS upload are pending.
