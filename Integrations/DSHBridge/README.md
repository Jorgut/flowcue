# FlowCue DSH bridge (experimental)

Small DSH host plugin that lets FlowCue answer DSH approval requests from the
paired iPhone.

## How it works

- Registers one `approval/request` answerer inside the DSH host.
- Holds the request until the FlowCue Mac app sends a decision.
- Exposes only `127.0.0.1:47823`:
  - `GET /v1/pending`
  - `POST /v1/decide` with `{ "id": "...", "decision": "allowed-once" | "rejected" }`
- Requires `Authorization: Bearer <token>`; the token is generated once at
  `~/.flowcue/dsh-bridge.json` with mode `0600`.
- Uninstalling/disabling the plugin leaves DSH's normal approval UI intact:
  requests fall through to `next()` when the bridge is closed.

## Install (after review)

Run from the repository:

```bash
Scripts/install-dsh-bridge.sh desktop
```

This installs the local package into the profile, adds the profile patch entry,
and asks you to quit and reopen DeepSeek Harness. Do not install this on a
profile you are not prepared to restart.

## Status

Experimental scaffold. The Mac app and iPhone approval UI are not wired yet.
