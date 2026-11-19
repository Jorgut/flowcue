# FlowCue DSH bridge (experimental)

Small DSH host plugin that lets FlowCue answer DSH approval requests from the
paired iPhone.

## How it works

- Registers one `approval/request` answerer with `prepend: true`, so it runs
  before the desktop UI / Auto review answerer; otherwise desktop-owned
  sessions never reach the bridge.
- When the phone has polled within the last 15s, the bridge lets the phone
  answer alone instead of also opening the desktop prompt (the desktop card
  otherwise stays visible after a phone decision). If the phone stays quiet
  for 60s, the request falls back to the normal desktop prompt.
- Holds the request until the FlowCue Mac app sends a decision.
- Exposes only `127.0.0.1:47823`:
  - `GET /v1/pending`
  - `POST /v1/decide` with `{ "id": "...", "decision": "allowed-once" | "rejected" }`
- Requires `Authorization: Bearer <token>`; the token is generated once at
  `~/.flowcue/dsh-bridge.json` with mode `0600`.
- Uninstalling/disabling the plugin leaves DSH's normal approval UI intact:
  requests fall through to `next()` when the bridge is closed.

## Install

**用户**：在 FlowCue 的设置 → 集成 → DSH 里点「安装 DSH 桥」。插件随 app 分发
（`Contents/Resources/DSHBridge`），安装时会复制到 `~/.flowcue/bridge/<version>`
再注册进 DSH profile，所以 app 升级或被移动都不会让 profile 里的链接失效。
装完需要退出并重开 DeepSeek Harness。

**开发机**（直接从仓库装，不需要重新打包 app）：

```bash
Scripts/install-dsh-bridge.sh desktop
```

注意它注册的是仓库里的路径：仓库搬家后 profile 里的链接会断，需要重跑一次。
本机已经踩过一次，见 `PROJECT_STATE.md` 2026-11-19 14:05 条目。

## Status

iPhone 端已在 Chat 之外全局轮询并弹出审批 sheet。改动插件后必须退出并重开
DeepSeek Harness 才会加载新代码；重开后 `GET /v1/pending` 应能在桌面审批等待期间
看到同一条请求。
