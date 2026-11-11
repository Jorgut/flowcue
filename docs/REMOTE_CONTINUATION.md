# Remote continuation setup

Status: implemented in the local iOS/CloudKit branch; shipping requires a
Developer ID provisioning profile with iCloud for the desktop build.

## What it does

- The Mac publishes recent Codex thread snapshots (title, last assistant reply,
  timestamp) to the user's private CloudKit database.
- The iPhone lists those sessions, shows the last reply, and can send the next
  message. Only an explicit Send action creates a command.
- The Mac executor validates the command, writes a durable local ledger, then
  queues the message to Codex. A repeated command is never executed twice; an
  interrupted attempt is recorded as `uncertain`, not retried.
- The iCloud account is the pairing boundary. No public records or third-party
  relay are used.

## Enable

1. Mac: menu bar → **Allow iPhone to continue Codex sessions** (default off).
2. iPhone: FlowCue Pro → **Agents**.
3. Both devices must be signed in to the same iCloud account.

## Build signatures

The App Store build has iCloud but no CLI. The GitHub/Developer ID build has the
CLI but needs iCloud:

```sh
FLOWCUE_CODE_SIGN_IDENTITY='Developer ID Application: …' \
FLOWCUE_MAC_PROVISIONING_PROFILE='/path/to/profile.provisionprofile' \
FLOWCUE_MAC_ENTITLEMENTS="$PWD/Support/Release.entitlements" \
zsh Scripts/build-app.sh release
```

For local development testing, a Mac Team profile for
`com.altn.reroute.ideainbox` can be used with:

```sh
FLOWCUE_MAC_BUNDLE_ID='com.altn.reroute.ideainbox'
```

The helper is signed without restricted entitlements; only the main executable
and app bundle receive the iCloud entitlements.

## Remaining shipping requirement

A **Developer ID** provisioning profile that includes the iCloud container for
the shipping bundle ID is required. The profiles currently on this machine are
Mac Team development/store profiles and cannot be used for a notarized
Developer ID release. Until that profile exists, remote continuation works only
in a locally signed development build.
