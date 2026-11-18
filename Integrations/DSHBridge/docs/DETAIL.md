# FlowCue DSH bridge

Sends DeepSeek Harness approval requests to the paired FlowCue iPhone over the
FlowCue Mac proxy and returns `allowed-once` or `rejected`.

- Loopback only: `127.0.0.1:47823`
- Token: `~/.flowcue/dsh-bridge.json`
- Leaving the bridge disabled or uninstalled keeps DSH's normal approval UI.
