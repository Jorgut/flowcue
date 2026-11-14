# Remote continuation (same network)

Status: implemented in the local iOS/Mac branch. It does not use CloudKit or
iCloud entitlements.

## What it does

- The Mac app advertises a Bonjour service (`_flowcue._tcp`) and exposes a
  small token-authenticated HTTP API on the local network.
- The iPhone discovers the Mac, asks for a 6-digit pairing code shown in the
  Mac menu, lists recent Codex threads, shows the last assistant reply, and can
  send the next message.
- The Mac executor keeps a durable local ledger: a repeated command is never
  executed twice, and an interrupted attempt is marked `uncertain` rather than
  retried.
- No public relay and no third-party server are involved.

## Enable

1. Mac: menu bar → **Allow iPhone on this network**. The menu shows the
   pairing code while the service is running.
2. iPhone: FlowCue Pro → Agents, enter the code, connect.
3. Both devices must be on the same Wi-Fi network.

## Why not CloudKit on the desktop?

A Developer ID provisioning profile does not grant iCloud container
entitlements (the generated profile has an empty
`com.apple.developer.icloud-container-identifiers` array). iCloud + CloudKit
remain available to the App Store iOS/Mac builds for note sync; the
Developer ID Mac app uses the local-network path instead.

## Files

- `Sources/CodexIdeaDockCore/LANRemoteServer.swift`
- `Sources/RerouteMobileApp/RerouteMobileApp.swift` — discovery/client and
  Agents UI
- `Support/MobileInfo.plist` — local-network usage description and Bonjour type
