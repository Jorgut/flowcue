# Remote agent nodes (Windows / Linux)

Status: Codex node with approvals and its built-in web console implemented in `RemoteNode/`. Updated 2026-11-23.

## Goal

Let FlowCue on the iPhone (and later the Mac) use the agent sessions of other
machines the way it already uses the Mac's DSH sessions: list sessions, read
the conversation, send the next message, see approvals.

Non-goal: screen streaming, mouse/keyboard control, AnyDesk-style remote
desktop. If a task needs a GUI, the product links out to the user's existing
remote-desktop tool instead of implementing one.

## Why this fits the current architecture

The Mac already acts as an executor: `LANRemoteServer` exposes a token-
authenticated `/v1` API on `_flowcue._tcp`, and the iPhone connects to it. The
remote node keeps that contract and replaces "the Mac" with "any machine that
runs the node". The iPhone needs no protocol change for the first milestone.

The Mac also already has the right abstraction for multiple agents:

- `AgentSession` / `AgentMessage` in `Sources/CodexIdeaDockCore/AgentSession.swift`
- `AgentAdapter` with `listSessions` / `messages` / `send`
- `AgentDiscovery` with per-agent capabilities

The node mirrors that model. `/v1/dsh/*` is DSH-specific; the long-term
endpoint set is `/v1/agents/{agentID}/...`, with `/v1/dsh/*` kept as a
compatibility shim.

## Node design

```
iPhone / Mac FlowCue
        │  Bearer pairing code, LAN (later Tailscale or relay)
        ▼
flowcue-node (Go, single static binary)
        ├── Codex: `codex app-server` + rollout files + `codex queue`
        ├── Claude Code: session JSONL + `claude -p --resume`
        └── DSH: read-only session files first, bridge later
```

The node is a control surface, not an agent runtime. It never calls a model
itself; it starts and reads the agent that is already installed on the machine.

## Protocol (implemented)

Compatible with the current iPhone app:

- `GET /v1/ping` (no auth) → `{name, version, protocol, appVersion}`
- `GET /v1/threads` → `[RemoteThreadSnapshot]`
- `GET /v1/threads/{id}/messages` → `[RemoteConversationMessage]`
- `POST /v1/send` → `RemoteCommandResult`
- `GET /v1/node/info` (node extension) → platform, capabilities, workspace
- `GET /v1/approvals` (node extension) → pending command/file-change approvals
- `POST /v1/approvals/{id}` (node extension) → `{decision: accept|decline}`
- `POST /v1/session` → exchanges the 6-digit code for an HttpOnly cookie
- `POST /v1/session/logout` → drops that cookie
- `GET /` (and `/app.css`, `/app.js`) → the embedded web console

### Date encoding gotcha

The iPhone decodes with a plain `JSONDecoder`, whose default date strategy is
`.deferredToDate`. Dates must be **seconds since 2001-01-01T00:00:00Z**, not
Unix seconds. The Mac's `JSONEncoder()` does this implicitly; a Go
implementation must do it explicitly (`internal/timeutil`). Sending Unix
seconds silently decodes into 2057 and breaks sorting.

### Web console auth

The browser never keeps the pairing code in localStorage. It posts the code
once, receives an `HttpOnly`, `SameSite=Strict` cookie valid for 12 hours, and
uses that for `/v1/threads`, `/v1/send`, and the rest. The iPhone app keeps
using `Authorization: Bearer <code>`, so both clients share one API.

### Send semantics and approval ownership

`POST /v1/send` starts a turn on the node's persistent `codex app-server`
connection (`turn/start`, approval policy `on-request`). That ownership is what
makes approval requests visible to the node: a turn started by `codex queue`
belongs to a separate Codex TUI, and its approvals never reach this process.

If the thread is already running elsewhere, `turn/start` fails and the console
reports the send as failed; it does not silently fall back to `codex queue`.
The state maps to `delivered` / `failed` / `uncertain`, and replies are read
back from the rollout after the command's `createdAt`.

Approvals are surfaced through `GET /v1/approvals`; `Allow once` / `Deny` post
`accept` / `decline` to `POST /v1/approvals/{id}`. Command and file-change
requests are supported. Permission-profile requests are answered with an error
until there is a UI for their richer response.

## Codex backend

- **List**: `codex app-server` JSON-RPC `thread/list`, same params as the Mac
  (`sortKey: recency_at`, `useStateDbOnly: true`). Cached for 10 seconds so the
  phone's polling does not spawn a process every few seconds.
- **Messages**: read the rollout JSONL under `~/.codex/sessions`, newest file
  per thread id. Only `response_item` → `message` → user/assistant text is
  exposed; tool output and raw CLI diagnostics are never returned.
- **Send**: `codex queue`. The CLI path may be a `.cmd` on Windows, so it is
  routed through `cmd.exe`.

The MVP was smoke-tested on macOS against the real Codex install: `/v1/ping`,
auth 401, thread list with Apple-reference timestamps, and message reads all
matched the Mac's shape.

## Claude Code backend (next)

- Sessions: `~/.claude/projects/<encoded-project>/<session-id>.jsonl` on
  macOS/Linux, `%USERPROFILE%\.claude\projects\...` on native Windows.
- Read: same event lines the Mac's `ClaudeCodeAdapter` parses.
- Send: `claude -p --resume <session> <text>`.
- If Claude runs inside WSL, the files live in the WSL filesystem
  (`\\wsl$\<distro>\home\<user>\.claude\...`) and the executable is
  `wsl.exe -d <distro> -- claude ...`; that is a separate adapter mode, not a
  path tweak.

## DSH backend (pending)

- DSH on the Mac is discovered inside the app bundle and its approvals come
  from the `DSHBridge` plugin. A Windows node needs both a confirmed Windows
  DSH build and a bridge install in that profile.
- First step is read-only: list sessions from `%USERPROFILE%\.dsh`, no send.
- Do not claim DSH support on a node until the bridge is installed there.

## Windows specifics

- `.cmd` shims (npm-installed `codex`, `claude`) need `cmd.exe /c`; prefer
  native `.exe` when available.
- Console output is not UTF-8 by default; decode child output accordingly.
- The node binds `0.0.0.0:47825`; allow it only on the Private firewall
  profile.
- Run as a normal user. Task Scheduler "At log on" is enough for the MVP; a
  real service needs NSSM or a service wrapper.

## Networking

1. Same Wi-Fi: direct LAN, Bonjour on the Mac side; the node can be reached by
   IP:port today. mDNS advertising is a small follow-up.
2. Different networks: Tailscale on the phone and the node, then use the
   tailnet IP. This works on Windows 10/11; it does not work on Windows 7.
3. Product route: nodes dial out to a relay (WSS), the phone connects to the
   relay, payloads stay end-to-end encrypted. No inbound port forwarding.

## iOS changes for multi-node

The current client keeps a single `selected` endpoint. Multi-node needs:

- a set of paired nodes plus the active one;
- a device list showing platform, online state, and available agents;
- approvals aggregated across nodes, not only the active one;
- per-node protocol version checks (reuse `X-FlowCue-Version`).

The Mac app currently only hosts; it needs a client role to control nodes.
iPhone first is the cheaper order.

## Security

- 6-digit code is the only secret and it travels over plain HTTP on the LAN,
  matching the Mac. Acceptable on a trusted network; never expose the port to
  the internet.
- The node exposes no arbitrary command execution. The only write action is
  queueing text into an existing session.
- Run unprivileged; read-only access to the agent's session directory.
- For WAN, require TLS plus per-node keys and pin the node fingerprint at
  pairing.

## Milestones

| Phase | Scope | State |
|---|---|---|
| M0 | Codex over LAN: ping, threads, messages, send, approvals, web console | implemented |
| M1 | Claude Code adapter (native Windows) | next |
| M2 | DSH read-only, then bridge | blocked on Windows build |
| M3 | iPhone multi-node UI and aggregated approvals | not started |
| M4 | Relay + TLS + end-to-end encryption | not started |

## Verification

- `cd RemoteNode && go test ./...` (rollout parsing, Apple dates, auth,
  routing, send states).
- `go vet ./...`, then cross-compile Windows and Linux.
- Read-only real check: `/v1/ping`, 401 without a token, `/v1/threads`,
  `/v1/threads/{id}/messages`. Do not send a real Queue message during
  automated verification.
- Phone check: manual connect with `IP:47825` and the 6-digit code; confirm
  thread list, messages, and a single user-approved send.

## Open questions

1. Does DSH have a Windows build, and where does its CLI live there?
2. Is Claude Code installed natively on Windows or inside WSL?
3. Which workspace directories should a node expose, and should it be
   read-only by default?
