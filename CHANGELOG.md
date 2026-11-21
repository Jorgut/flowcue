# Changelog

本项目遵循语义化版本号。公开发布前的构建记录在本文件中维护。

## 未发布

- 提问卡（DSH 的 user-questions/request）现在能推到 iPhone：插件挂 waterfall、手机用选项按钮回答并回传 `{answers}`，Mac 新增 `/v1/dsh/questions` 与 `/v1/dsh/answer`。60 秒内没人答就落回桌面，绝不吞掉问题。
- iPhone 聊天页渲染 Markdown 表格：之前 `|---|` 这类原始文本直接显示，现在变成真正的表格（表头加分隔线、按列等宽）。
- iPhone 上能看到 DSH 正在做什么：从会话日志里读最近一次工具调用或未结束的 turn，聊天页输入框上方显示「执行命令 · … · 12s」/「读取文件 · …」/「思考中 · 8s」，耗时每秒刷新。之前只有「最后一条是用户消息」时才显示指示器，处理过程中界面看起来像卡住。
- 审批轮询 15 秒 → 3 秒：这是本机回环请求，几乎不花钱，但决定了审批推到手机的快慢。
- 修复从 iPhone 发图片到 DSH 会话失败：桥接把请求体硬限制在 16 KB，图片 base64 后必然超限。现在按路由给上限（消息 24 MB），iPhone 发送前把图压到 1600px / JPEG 0.7。
- 审批不再「两张卡」：只要 iPhone 十分钟内出现过，就只走手机、不弹桌面卡——桌面卡一旦出现，手机再批准时那张卡不会自动消失，这是之前「批准了卡还挂着」的根因。手机 45 秒无响应才回退桌面，并撤掉那条待办。
- 修复审批通知从不触发：首次轮询的基线判断用了 `knownApprovals.isEmpty`，启动后第一条审批会被当成基线吞掉，既不推手机也不弹 Mac 通知。
- Mac 局域网端口固定为 47824，并给会话列表加 20 秒缓存与启动预热：Mac 重启不再让手机缓存的地址失效（之前表现为「Mac 明明开着却一直 Connection lost」），会话列表从 3.3 秒降到 10 毫秒内。
- iOS 补上通知中心 delegate：之前没挂，App 在前台时收到的推送被系统直接丢弃。
- 推送：接入 APNs（Mac 直接用团队 .p8 发往 api.push.apple.com，无需自建服务端）。iPhone 启动时注册并把 device token 交给 Mac，新审批出现时推一条横幅，锁屏/后台也能看到。
- iOS：审批面板改成半屏卡片（可上拉看全部），最后一条决定后自动关闭，不再需要手点 Done；多条时标题显示剩余条数。

## 0.1.5 — 2026-11-19（Mac build 10）

- 待审批通知点击后直接打开收件箱的「DSH 待审批」面板，不再只把窗口提到前台。
- 菜单栏角标改为待审批 + 未读回复合计；tooltip 与无障碍读分段说明。未读只记 agent/session 键与时间，不存回复正文。
- 点击对应通知或打开 Agent 列表即视为已读；DSH/Claude 无 hook 时由轮询补记。
- DSH 审批桥改为随 app 分发（`Contents/Resources/DSHBridge`）：设置 → 集成 里可一键安装 / 更新 / 卸载，
  不再要求用户手工跑脚本。插件先复制到固定目录 `~/.flowcue/bridge/<version>` 再注册进 profile，
  app 升级、被拖到别处或工作区重排都不会再让 profile 里的链接失效。
- 未安装 DeepSeek Harness 时，集成页显示「未检测到 DSH」，不再给一个装不上的按钮；
  DSH 的检测路径也从 `~/.flowcue`（FlowCue 自己的目录）改为 DSH 真正的 CLI 与 `~/.dsh`。
- 修复审批回退：Mac 自己每 15 秒的轮询曾被桥接当成「iPhone 在线」，把桌面审批卡扣住最多 60 秒。
  现在只有替手机转发的轮询带 `?source=phone` 才算数；手机 15 秒内没响应就回退桌面，并撤掉那条残留审批。

## 0.1.4 — 2026-11-19（Mac build 9 / iOS 1.1.0 build 56）

- iPhone 上的新建、编辑和分享导入，会在同一 Wi-Fi 下直接推进 Mac 收件箱（`POST /v1/ideas`，按 id 幂等，重复推送不产生副本）。
- 重新连上 Mac 时补推全部未归档想法；空内容拒绝写入。
- 设置里提示 Codex hook 尚未被信任，避免把“收不到通知”误判成功能失效。

## 0.1.3 — 2026-11-19（build 8）

- DSH 新回复与待审批改为系统通知，并做降噪（同一批只提醒一次）。
- 兼容 DSH 的多语言 `displayReason`（字符串或 `{en, zh, …}` 对象），修掉整条审批响应被丢弃、手机不弹的问题。
- 手机审批：配对后在前台任意页面轮询，待审批 3 秒内弹出。

## 0.1.2 — 2026-11-18（build 7）

- 两端版本握手：Mac `/v1/ping` 返回 `protocol` 与 `appVersion`，iPhone 连接前比对；低于最低协议提示更新 Mac，高于支持协议提示更新 iPhone。
- 内置更新：检查 GitHub 最新 release，下载 DMG，SHA-256 校验后打开。
- 配对页与设备页显示 `iPhone … ↔ Mac … · 协议 1`。

## 0.1.1 — 2026-11-18（build 6）

- 接入 DSH 会话列表与审批桥接，配对后手机能看到桌面待审批。
- iPhone 的 Pro 到期时间经局域网推送（`POST /v1/pro/expiry`），Mac 据此解锁。
- Developer ID 签名与 Apple 公证，universal（arm64 + x86_64）。

## 2026-11-11 — 品牌统一为 FlowCue

- 仓库与应用品牌由 **Reroute** 统一改回 **FlowCue**：README、AGENTS、支持/隐私/贡献文档、发布文档、Xcode 工程与 scheme、应用包、图标资源、菜单栏与窗口文案、构建脚本、CI 与测试路径同步更新。
- 应用包、Xcode 工程、scheme、图标和脚本更名为 `FlowCue.app`、`FlowCue.xcodeproj`、`FlowCue`、`FlowCue.icns`、`render-flowcue-icon.swift`；构建产物同时更名为 `dist/FlowCue.app`、`dist/FlowCue-App-Store-Preview.app` 与 `FlowCue-<version>-macOS-<arch>.zip`。
- 构建脚本环境变量更名为 `FLOWCUE_CODE_SIGN_IDENTITY`、`FLOWCUE_NOTARY_PROFILE`、`FLOWCUE_APP_STORE_BUNDLE_IDENTIFIER`；App Store 编译条件由 `REROUTE_APP_STORE` 更名为 `FLOWCUE_APP_STORE`。旧的 `REROUTE_*` 变量不再读取。
- 保留兼容标识不改动：Bundle ID `com.altn.codex-idea-dock` 与 `com.altn.reroute.app-store-preview`、SwiftData 配置名 `CodexIdeaDock`、窗口恢复键 `CodexIdeaDock.Inbox`、App Server 稳定客户端标识 `codex_idea_dock`。
- 本次仅统一品牌，不改变应用行为；历史发布记录与已发布产物中的旧名称保留原样。

## 0.1.0 — 2026-09-18

- 公开品牌由工作名称 FlowCue 更新为 **Reroute**；build 5 同步应用包、菜单栏、窗口、图标资源和文档名称，同时保留已有数据所依赖的兼容标识。
- 提供 `⌃⌥Space` 原生 macOS 悬浮捕捉窗口。
- 支持草稿恢复、本地收件箱、搜索、筛选、归档与撤销。
- 通过 Codex App Server 读取任务，并在用户明确操作后调用 `codex queue`。
- 对失败和不确定投递结果采用失败关闭策略，避免自动重复发送。
- 增加仅在 Codex、Claude Desktop 和支持的终端位于前台时保持悬浮的宿主策略。
- 完成 B1-L 应用图标与菜单栏模板资源。
- 移除没有实际选项的空白设置窗口；设置功能留待后续版本设计。
- 通过 51 项本地测试，其中真实 App Server 测试默认跳过并另行只读验证。

此版本是本机开发构建，不是 App Store 或已公证发行版。
