# Changelog

本项目遵循语义化版本号。公开发布前的构建记录在本文件中维护。

## 1.1.8 — 会话列表加载加速

- **DSH 会话列表从 18 秒降到 0.14 秒**：`DSHAgentAdapter` 每次都 new 一个
  `DSHSessionReader`，内部缓存全部失效，58 个会话日志被反复解压。
  改为复用同一个读取器。
- Mac 端会话列表加 30 秒缓存，反复进出同一 Agent 直接命中（3ms）。
- 列表上限从 300 收到 200（当前最多 58，留余量）。
- iOS 端缓存上次的会话列表，进页面立刻有内容，后台再刷新。

## 1.1.7 — 推送 token 重新上报 + 待回答提示

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.7 (97)`，Delivery UUID `fdeae1dd-5423-4c80-800a-5760d4fa38e7`。


### 修复

- **推送失效（关键）**：device token 原来只在「配对连接」那一刻上传一次。
  装 TestFlight 新包后 token 会变（dev → production），但连接是复用的，
  Mac 一直拿着旧 token 和环境，推送被苹果拒收。
  现在启动时以及 token 变化时都会重新上报，连接后即生效。
- 顺带修正：沙盒/正式环境的判断跟包一致，不再出现「TestFlight 包用 development 环境」。

### 新增

- 会话列表里待回答的问题显示「待回答」徽标
- Agents 页顶部提示「N 个问题在等你回答」，不再只依赖推送

## 1.1.6 — 断连与重新配对入口

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.6 (96)`，Delivery UUID `8010e696-2975-4e5b-88a8-3232375777e4`。


- Agents 页设备卡片下方新增「断连」和「更换配对码」两个按钮
- 之前这两个能力藏在「设备详情 → 底部安全区」，且配对面板只有在未连接状态才能打开，
  连着的时候无法重新输入配对码

## 1.1.5 — Agent 品牌图标

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.5 (95)`，Delivery UUID `7feeaff6-104f-440b-9354-b2218c06d815`。


- Agents 页每个 Agent 用官方 mark：DeepSeek 鲸鱼、OpenAI 花、Anthropic 标记
- 图标为单色矢量（SVG 进 `MobileAssets.xcassets`），按品牌色 tint：
  DeepSeek `#4D6BFE`、OpenAI `#10A37F`、Anthropic `#D97757`
- 离线时图标降到 45% 透明度；未知 Agent 仍退回 FlowCue 小脸

## 1.1.4 — 真实统计与连接体验

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.4 (94)`，Delivery UUID `87f169f2-1c69-4345-a261-e3af029a9001`。


- **修复统计被截断**：会话数之前沿用 `limit: 50`，DSH 实际 58、Codex 实际 81 却都显示 50。统计改用 1000 上限，会话列表改用 300。
- **Agents 页不再空白**：进页面立即拉取、显示「正在读取…」占位、并用上次的统计缓存兜底。
- **Mac 端预热与并发去重**：服务启动即后台计算统计；并发请求共享同一次计算，不重复扫目录。
- `DSHAgentAdapter.messages` 从 `unsupported` 改为读本机会话日志（11 条消息可读）。
- 更新过期测试 `testDSHMessagesStayUnsupported` → `testDSHMessagesReadFromSessionLog`。

## 1.1.3 — 项目图标

- 会话列表里每个项目名前面带一个 emoji 图标，默认 📁
- 点图标打开选择器（24 个 emoji + 恢复默认）；未关联项目固定 💬、不可修改
- 图标只存在本机 UserDefaults，不改动 Mac 上的文件，暂不同步
- 点图标编辑、点名称折叠，两个点击区域分开

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.3 (93)`，Delivery UUID `a10f2e24-18c8-44a2-8d7e-63296e0d97e4`。

## 1.1.2 — 通用 Agent 层

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.2 (92)`，Delivery UUID `2f546992-5d8f-4746-a7c7-6e3bb15c9371`。
> 导出产物内 `aps-environment = production`（已核验）。


### 新增

- **通用 Agent 接口**：`/v1/agents`、`/sessions`、`/messages`、`/send`，三个 Agent（Codex / Claude Code / DSH）走同一套路由。新增 Agent 只需 Mac 侧加适配器，iOS 零改动。
- **Claude Code 接入 iOS**：28 个会话、6 个项目，可读可发。
- **Agents 页动态化**：每行显示「N sessions · M projects」。
- **会话按项目分组**：项目名取 Agent 真实的工程目录名；未关联项目固定排最后；点标题折叠，折叠状态本地记忆。
- **快速切换 Agent**：点顶部 Agent 名字弹出菜单直接切换，当前项打勾。
- **继续上次**：会话页顶部横幅直达上次停留的对话。

### 修复

- `DSHAgentAdapter.messages` 之前直接 `throw .unsupported`，改为读本机会话日志（桥只暴露待审/发消息/决策）。
- DSH 会话仍进功能完整的 `ChatScreen`，保留审批卡、提问卡、活动状态与图片。

## 1.1.1 — iOS 发布版

> **发布状态（2026-11-23）**：已上传 TestFlight，`1.1.1 (90)`，Delivery UUID `27f7d132-449e-4318-bae1-21848096bb2e`。
> 导出产物内 `aps-environment = production`（archive 阶段签的是 development，必须看导出后的 IPA）。

### 实测通过

| 项 | 结论 |
|---|---|
| 图片发送 | 完整送达，无白底 |
| 左滑 / 长按 / 批量选择 / 垃圾箱 | 通过 |
| 提问卡 | 应用内正常，60 秒无应答落回桌面 |
| 锁屏推送 | 收到，标题为「iOS 开发 有问题需要答复」 |
| 想法双向同步 | Mac 历史想法出现在手机；删除/归档双向生效 |
| Mac 重启后自动重连 | 约 10 秒自动恢复 |

### 1.1.2 待办

- **Mac IP 变化后自动重新发现**：轮询只重试旧地址，同网络 DHCP 换 IP 后需手动重连；连续失败后跑一次 Bonjour `_flowcue._tcp` 发现并切换。跨网段无解，不处理。
- **APNs 返回码落文件**：`NSLog` 在系统日志里查不到（推送可用），改写 `~/.flowcue/apns.log`，便于排查 `BadDeviceToken` / 环境错配。
- **Codex 会话列表分页**：发送列表目前只显示最近 12 条。
- 已知限制：手机切后台/锁屏会挂起进程，自动重连要求 App 在前台。


### 新增

- **提问卡**：DSH 的 `user-questions/request` 接到手机，卡片出现在对应会话的输入框上方，点选项即回传；60 秒无人应答落回桌面。
- **想法双向同步**：连接时先拉 `GET /v1/ideas` 再推本地；Mac 上原有的历史想法会出现在手机上。
- **删除 / 归档双向同步**：删除改为墓碑软删（`deletedAt`），归档状态随 `updatedAt` 同步，冲突规则「时间新的赢、墓碑优先」。
- **删除入口**：列表左滑露出 Archive / Delete，长按菜单，详情页底部按钮。
- **锁屏推送**：审批与提问各自独立的通知线程，可直接在通知上批准。

### 修复

- 右滑返回：系统交互式返回被 TabView 翻页手势抢走，改为推入页左边缘跟手拖拽（含回弹与触感）。
- 聊天页图片出现白色垫底。
- 提问卡因同一视图挂三个 `.sheet` 而永不显示。
- 手机发送超时导致的误报「未送达」（30 秒超时 + 结果对账）。

### 发布配置

- `aps-environment` 改为按配置注入：Debug = development，Release = production（此前硬编码 development，会被 App Store 拒绝）。

- 删除/归档双向同步：删除改为墓碑（`deletedAt` 软删），`GET /v1/ideas` 连墓碑一起下发；合并规则是「`updatedAt` 新的赢，墓碑优先于正文」，两端按 id 对齐。之前在 Mac 上删的想法会被下一次拉取重新插回来的问题不再存在。
- 想法同步改为双向：连接时先 `GET /v1/ideas` 把 Mac 上的历史想法拉下来合并，再把本地推上去。按 id 对齐，`updatedAt` 较新的赢；本地更新时保留本地版本并在随后推回 Mac。
- iPhone 支持删除想法：列表行**左滑**露出 Archive / Delete（和系统列表手势一致），长按也能删，详情页底部另有 Delete 按钮。删除带确认，并同步到 Mac（`POST /v1/ideas/delete`），避免只推不删留下副本。
- iPhone 推入页加「左边缘右拖返回」高优先级手势：系统的交互式返回会被 TabView 的翻页手势抢走，导致右滑切了标签页而不是返回。
- 提问卡改为出现在对应 chat 内（输入框上方），不再全局弹窗挡住别的页面；待回答时会推一条「有任务在等你回答」的通知，锁屏也能看到是哪个任务在等你。
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
