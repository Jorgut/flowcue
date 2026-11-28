# FlowCue Remote Node

A small, dependency-free Go daemon that exposes the Codex sessions of one
machine to FlowCue. It speaks the same `/v1` contract the Mac app already
serves, so the iPhone app can connect with the existing "Connect manually"
flow, and it serves a built-in web console for any other device.

This is **not** a remote-desktop server. It exposes agent sessions: list,
read, and queue a follow-up message.

## Status

- Codex: list threads, read messages, start the next turn. Done.
- Web console: served at `/`, pairs with the 6-digit code, works on desktop
  and phone browsers. Done.
- Approvals: command and file-change requests from turns started by the node
  are listed in the console and answered with Allow once / Deny. Done.
- Permission-profile requests are answered with an error for now; they need a
  richer UI.
- Claude Code: planned.
- DSH: planned, pending a confirmed Windows build and bridge install.

## Build

```bash
cd RemoteNode
go test ./...
go build -o bin/flowcue-node ./cmd/flowcue-node

# Cross-compile (no cgo, static binaries)
GOOS=windows GOARCH=amd64 go build -o bin/flowcue-node-windows-amd64.exe ./cmd/flowcue-node
GOOS=linux   GOARCH=amd64 go build -o bin/flowcue-node-linux-amd64 ./cmd/flowcue-node
```

Or run `Scripts/build-all.sh`.

## Run

```bash
./bin/flowcue-node -port 47825
```

First start prints the pairing code and the machine's LAN addresses:

```
FlowCue Node 0.1.0
  pairing code: 123456
  codex:        /opt/homebrew/bin/codex
  codex home:   /Users/you/.codex
  workspace:    /Users/you/FlowCue
  addresses:
    http://192.168.1.23:47825
```

The code and the executor id are persisted in `~/.flowcue/node/` (Windows:
`%USERPROFILE%\.flowcue\node\`), so restarts keep the same pairing.

## Web console

Open `http://<node-ip>:47825/` in any browser, enter the 6-digit code, and the
node serves its own console:

- sessions and recent replies, Codex first;
- one conversation with user/assistant messages;
- a composer that calls `POST /v1/send` (starts a turn through `codex app-server`);
- an approval panel fed by `GET /v1/approvals`; Allow/Deny posts to
  `POST /v1/approvals/{id}`;
- a pairing cookie (`HttpOnly`, `SameSite=Strict`, 12 hours) so the code is
  not stored in the page;
- an 8-second session poll and a 3-second message poll while a session is
  open.

The iPhone app keeps using `Authorization: Bearer <code>`; the cookie is only
for the browser. The console is embedded in the binary, so there is nothing
else to deploy.

### Approvals and turn ownership

To see an approval, the node must own the turn. `POST /v1/send` therefore uses
`turn/start` on the persistent `codex app-server` connection and overrides the
turn's approval policy to `on-request`. A turn running in a separate Codex TUI
belongs to that process, and its approvals will not appear here. If the thread
is already running, `turn/start` returns an error; the console shows the send
as failed instead of silently queueing it elsewhere.

Options:

| Flag | Default | Meaning |
|---|---|---|
| `-port` | `47825` | listen port |
| `-code` | persisted | override the 6-digit pairing code |
| `-workspace` | current directory | shown to the phone |
| `-codex` | auto-detected | path to the `codex` executable |
| `-state` | `~/.flowcue/node` | pairing code and executor id |

## Pair from the iPhone

1. Start the node; keep the window open.
2. FlowCue → Agents → **Connect manually**.
3. Enter `<LAN IP>:47825` and the 6-digit code.

The phone then shows the Codex threads of that machine. Sending a message runs
`codex queue --thread <id> --message <text>` on the node.

## Windows notes

- Install Codex first (`codex --version` must work). Prefer a native
  `codex.exe`: the node passes the message text as a command-line argument, and
  a `.cmd` shim forces the call through `cmd.exe`, where quotes and `&`/`|` in
  the message can misbehave. Check with `where.exe codex`; if it only prints a
  `.cmd`, pass the real `.exe` with `-codex <path>`.
- Allow the port on the private network:

  ```powershell
  New-NetFirewallRule -DisplayName "FlowCue Node" -Direction Inbound `
    -Protocol TCP -LocalPort 47825 -Action Allow -Profile Private
  ```

- For a background start, use Task Scheduler ("At log on") pointing at
  `flowcue-node.exe`. A console app is not a Windows service by itself; NSSM is
  the alternative if a real service is needed.
- Keep the machine on a trusted Wi-Fi. The 6-digit code is the only
  authentication; do not forward this port on the router.

## Security boundaries

- The token is a 6-digit code over plain HTTP, matching the Mac app. This is
  acceptable on a trusted LAN and **not** acceptable across the internet.
- The node never exposes arbitrary shell execution. The only write action is
  queueing a message into an existing Codex session.
- The node reads `~/.codex` and does not modify sessions or credentials.
- Run it as a normal user, not Administrator/root.

## Layout

```
cmd/flowcue-node      entry point (flags, banner, shutdown)
internal/config       paths, pairing code, executor id, Codex discovery
internal/codex        app-server client, rollout reader, queue runner
internal/server       HTTP routes and the /v1 wire format
internal/timeutil     Apple reference-date conversion
```
