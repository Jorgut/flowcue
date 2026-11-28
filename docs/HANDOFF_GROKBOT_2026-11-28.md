# FlowCue 远程连接与 Codex 图片发送交接

日期：2026-11-28（Asia/Almaty）。接手前阅读仓库的 `AGENTS.md`、`README.md`、`PROJECT_STATE.md` 和[原 Pages 交接](HANDOFF_PAGES_RELAY_2026-11-26.md)。最新实测以本页及项目状态中的新条目为准。

## 目标与当前状态

目标是让 iPhone 在关闭 Wi-Fi 和 VPN、仅用 5G 时，可从系统相册选 20 张测试图并只发送一次。恢复联网后应继续原批次，拿到确认，Codex 历史只出现一条含 20 个附件的消息，模型按附件顺序识别全部编号。先用已有资源验证，无需购买域名。正式默认入口变更前先向用户说明。

最近一次满足网络条件的手动验收未通过。用户确认选图并点发送一次，CloudKit 一度上线，发送阶段反复握手超时，备用 WebSocket 也反复心跳超时。结束时 Mac 暂存 **0/20**，专用 Codex 会话无该消息。尚未确认手机当时是否创建上传草稿，或点按时发送按钮已因离线禁用。专用预热会话的历史接口另有 404，应独立核查会话是否出现在 Mac 会话列表。两端已恢复测试前安装版本，临时相册导图代码已撤除，干净 iOS 签名包构建通过。

## 已验证的路径

| 路径 | 证据与局限 |
| --- | --- |
| Codex 图片投递 | 当前 CLI 的 `queue --image` 一张也明确拒绝。FlowCue 已在 Mac 接入 App Server `turn/start` + `localImage`，保留文本 Queue。签名真机从 10/20 强制退出后续传到 20/20，手机收到确认，Codex 历史恰好一条含 20 图的消息，模型读对全部编号。重开阶段走备用 WebSocket，未独立复核 Wi-Fi/VPN。较大批次使用 192 KiB 发送预算，成功批次约 164 KiB；这不是 Codex 限额。Mac 回归 166 项，4 跳过、0 失败，独立真实附件测试与 iOS 签名构建通过。 |
| CloudKit 私有信箱 | 已确认 5G 无 VPN 条件下，三轮隔离合成历史、命令和回执完整往返，重开可按原 ID 读回执。真实 DSH 历史、发送、确认、回复也曾跑通，但那一轮网络开关未独立复核。长期稳定性及 5G 相册投递未过。 |
| Pages HTTPS 信箱 | 已确认 5G 无 VPN 的同场隔离探测中，HTTPS 约 14.8 KB 回显 8/8，WebSocket 在 5 秒窗口内握手 0/8。HTTPS 原型后来跑通真实 DSH，也曾连续超时。Pages 自带 echo 和部分 DO 双向帧测试曾成功，生产链路可靠性仍未通过。 |
| Workers WebSocket | VPN 下曾稳定，也曾作为备用完成 20 图真机验收。不能据此推断 5G 无 VPN 可用。 |

## 对照研究

- **Agent HUD** 同网加密直连，外网用个人 iCloud 同步加密记录，手机缓存最近数据供离线查看，推送另走通道。公开资料未证明它支持 20 图验收。借鉴先显示缓存，再补同步。 [Remote 指南](https://agenthud.app/guides/remote-sessions) · [隐私说明](https://agenthud.app/privacy)
- **Paseo** 由常驻 daemon 主动连加密 WebSocket 中继，客户端缓存时间线、重连后恢复订阅并按游标补拉。其公开 issue 也记录了 iOS 大时间线导致重连循环。借鉴连接恢复与会话补同步各自推进。 [架构](https://github.com/getpaseo/paseo/blob/main/docs/architecture.md) · [中继](https://github.com/getpaseo/paseo-relay) · [iOS 问题](https://github.com/getpaseo/paseo/issues/4239)
- **Happy Coder** 持久保存加密同步数据，HTTP 用于读写，Socket.IO 用于实时更新，消息有 ID 和同步序号。借鉴用持久状态恢复消息和进度。 [协议](https://github.com/slopus/happy/blob/main/docs/protocol.md)

以上为公开资料对照，三个产品均未在用户这张 SIM 上实测。

## 接手顺序

1. 核对当前工作树、Mac 和 iPhone 安装版，保留现有成果。检查 [iOS 聊天发送与续传](../Sources/RerouteMobileApp/RerouteMobileApp.swift)、[Mac CloudKit 轮询](../Sources/CodexIdeaDockCore/RemoteRelayClient.swift)、[附件批次与回执](../Sources/CodexIdeaDockCore/CodexAgentAdapter.swift) 和 [Codex App Server 桥接](../Sources/CodexIdeaDockCore/CodexBridge.swift)。优先用独立会话确认通过手机正常入口能列出并读取历史，再排查传输。
2. 注入发送瞬间断网、App 重开、回执迟到、Mac 领取后重启。先复现并测量 iPhone 是否收到点击、草稿是否落盘、Mac 是否暂存及认领。当前聊天页在离线时禁用发送，草稿在进入发送后才保存；Mac CloudKit 轮询会等待上一条请求及回执，回执缓存在内存。两处是待验证的切入点。
3. 先验证离线点击即可持久保存原批次、恢复后只补缺片、已尝试最终提交时只用原 ID 或批次 GET 查回执。首屏先用缓存，在线后增量补齐；分开观察探活、历史、附件与 Agent 执行耗时。复用现有配对加密、Codex App Server、分片和磁盘去重。
4. 同一台 iPhone、同一张 SIM、同一时段对照 CloudKit 和已有 Pages HTTPS 信箱，先测只读往返和重连，再用更可靠的路径在干净测试会话只发一次新批次。记录 Wi-Fi/VPN 实际状态、所用通道、上传计数、确认和 Codex 历史。保留旧入口，直至真机完整验收通过。

旧 DSH 消息以及结果不确定的 Codex 批次均不可点 Retry 或重发。真实测试只用专用会话及合成数据。遵守 `AGENTS.md`，如需提交，只暂存明确的具体路径，不纳入 `.agent-state`、设计稿或无关未跟踪文件。
