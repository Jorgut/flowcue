# Reroute 0.1.0

Reroute is a local macOS menu bar app for capturing ideas and sending them to a Codex task only when you explicitly choose **Queue to Codex**.

## Requirements

- macOS 14 or later on Apple silicon
- Codex CLI installed and signed in
- A Codex CLI version that supports the `queue` command

## Install

1. Download `Reroute-0.1.0-macOS-arm64.zip` and its `.sha256` file.
2. Verify the checksum with `shasum -a 256 -c Reroute-0.1.0-macOS-arm64.zip.sha256`.
3. Open the ZIP and move `Reroute.app` to Applications.
4. Start Reroute, then use `Control–Option–Space` to open the capture window.

## Privacy

Ideas, drafts, task cache, and delivery records are stored on the Mac. Reroute reads the task list through the local Codex App Server and invokes the local Codex CLI only after an explicit queue action. The Codex CLI and its configured service may then process or transmit the queued text under their own settings and privacy terms. Reroute does not include analytics, advertising, tracking, or third-party SDKs. See the full [Privacy Policy](https://github.com/Jorgut/reroute-codex/blob/main/PRIVACY.md).

## Distribution note

The downloadable archive must be signed with a Developer ID Application certificate, notarized by Apple, and accompanied by the published SHA-256 checksum. Do not publish the local ad-hoc build from `dist/Reroute.app`.

Reroute is an independent third-party project and is not affiliated with, endorsed by, or sponsored by OpenAI.
