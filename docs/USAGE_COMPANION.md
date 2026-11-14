# Read-only usage companion proposal

Prepared 2026-10-08. Pending explicit approval; not installed or running.

## Outcome

The sandboxed macOS Reroute app displays the current signed-in Codex account's usage windows, remaining percentage, reset date/countdown, and last successful refresh. No per-project attribution is implied.

## Boundary

A separately launched, non-sandboxed companion calls only `account/rateLimits/read` through the existing Codex process runner. It returns a filtered usage snapshot. It does not expose generic JSON-RPC, thread access, Queue, shell execution, raw credentials, or note content. Existing Codex sign-in remains managed by Codex.

The companion binds only IPv4 loopback `127.0.0.1`; no LAN or remote binding, no firewall changes, no iCloud upload of account usage. A randomly generated pairing secret is required in the Authorization header and is never put in a URL or logs. Pairing is explicit; the client accepts only the loopback endpoint and rejects redirects. Secret storage uses Keychain. Requests have strict size/time limits; returned snapshots carry an observation timestamp. Old data is marked stale on failure.

Reroute retains App Sandbox and existing outgoing network entitlement. Companion installation and startup are explicit. No login item, LaunchAgent, or automatic startup is added in this phase. Stop companion means updates stop; users retain the last timestamped snapshot.

## Validation

- Test RPC filtering, empty/malformed data, window duration classification, stale snapshot, and cancellation.
- Verify loopback binding, missing/wrong-token rejection, unsupported method rejection, redirect rejection, and process cleanup.
- Build GitHub and Store branches; compare a real read-only snapshot with the displayed sandboxed app values.
- Preserve existing notes, current Store review submission, CloudKit schema, and agent delivery behavior.

## Release limitation

A sandboxed client connecting to a companion is technically supported by outgoing networking, but this alone does not guarantee App Review acceptance. Optional companion behavior and review instructions must be described before a public release.
