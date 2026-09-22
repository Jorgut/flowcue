# Privacy Policy

Effective date: September 22, 2026

Reroute is a local macOS utility. It does not require a Reroute account and does not include advertising, analytics, tracking, crash-reporting services, or third-party SDKs.

## Data stored on the Mac

Reroute stores the following information locally:

- idea and draft text;
- Codex task identifiers and titles selected as sources or destinations;
- capture, archive, delivery, and error status;
- timestamps and locally pinned task preferences.

The main database is stored under `~/Library/Application Support/CodexIdeaDock.store`. A short-lived draft recovery buffer is stored in the app's local preferences. This information is not synced by Reroute.

## Codex interaction

Reroute reads the task list from the Codex App Server running on the same Mac. It does not read or modify the Codex database or conversation files directly.

Reroute sends idea text to the local Codex CLI only after the user explicitly chooses **Queue to Codex**. The Codex CLI and the service configured for it may then process or transmit that text under their own settings and privacy terms. Reroute does not independently upload ideas to a Reroute server.

Because the current Codex CLI accepts queued text through a command-line argument, the text can be briefly visible in the local process argument list while the queue command is running. Reroute does not write that argument to its logs or delivery diagnostics.

## Diagnostics

Reroute stores only fixed error categories, exit codes, and timestamps needed to show delivery status. It does not persist raw Codex CLI error output or idea text as diagnostic logs.

## Permissions

Reroute does not request microphone, camera, location, contacts, accessibility, automation, or tracking permission. macOS system dictation is provided by the operating system and is not integrated through a Reroute API.

## Third parties

Reroute has no advertising or analytics partners. Use of Codex is governed separately by the terms and privacy practices applicable to the user's Codex installation and account.

## Questions

For privacy questions, open an issue in the [Reroute GitHub repository](https://github.com/Jorgut/reroute-codex/issues). Do not include idea text, task identifiers, credentials, or other sensitive information in a public issue. Security-sensitive reports should follow [SECURITY.md](SECURITY.md).
