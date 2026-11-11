# FlowCue 0.1.0

> 历史发布说明：0.1.0 于 2026-09-18 首次公开发布时使用旧品牌 **Reroute**。该次发布上传的下载包、校验文件、应用包和签名产物保留 `Reroute-*` 名称且不再更改；本页其余内容按当前品牌 FlowCue 描述同一版本。

FlowCue is a local macOS menu bar app for capturing ideas and sending them to a Codex task only when you explicitly choose **Queue to Codex**.

## Requirements

- macOS 14 or later on Apple silicon
- Codex CLI installed and signed in
- A Codex CLI version that supports the `queue` command

## Install

1. Download the 0.1.0 macOS arm64 archive and its `.sha256` file from the release page. The published artifact uses the former brand name: `Reroute-0.1.0-macOS-arm64.zip`.
2. Verify the checksum with `shasum -a 256 -c Reroute-0.1.0-macOS-arm64.zip.sha256`.
3. Open the ZIP and move `Reroute.app` to Applications.
4. Start the app, then use `Control–Option–Space` to open the capture window.

## Privacy

Ideas, drafts, task cache, and delivery records are stored on the Mac. FlowCue reads the task list through the local Codex App Server and invokes the local Codex CLI only after an explicit queue action. The Codex CLI and its configured service may then process or transmit the queued text under their own settings and privacy terms. FlowCue does not include analytics, advertising, tracking, or third-party SDKs. See the full [Privacy Policy](https://github.com/Jorgut/flowcue/blob/main/PRIVACY.md).

## Distribution note

The downloadable archive must be signed with a Developer ID Application certificate, notarized by Apple, and accompanied by the published SHA-256 checksum. Do not publish the local ad-hoc build from `dist/FlowCue.app`.

FlowCue is an independent third-party project and is not affiliated with, endorsed by, or sponsored by OpenAI.
