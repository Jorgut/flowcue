## 0.1.6 — 未发布（Mac build 11）

- **Mac 全免费**：移除发消息、并行分发、收藏/搜索的 Pro 门禁；本地功能不再需要订阅或 License。
- **移除 Mac License 设置页**：原「Pro / Mac 授权」改为「支持」页，只说明当前免费与官网支持者入口；不再有授权码输入。
- **iPhone 同 Wi-Fi 全免费**：移除 Agents 页的 Pro 付费墙、Pro 设置行、主题解锁和 Pro 徽章；StoreKit 代码保留但不再参与门禁。
- **官网**：移除 Paddle / 1,999 Mac Pro 购买区；Mac 与 iPhone 文案改为免费；Support 页新增自愿支持者入口（Stripe 链接待配置）。
- 验证：Mac `swift test` 126 项、2 跳过、0 失败；iOS 1.1.9 (99) 模拟器构建通过；Mac 0.1.6 (11) 构建通过。

# Changelog

本项目遵循语义化版本号。公开发布前的构建记录在本文件中维护。

## 1.1.18 (109) — 远程状态一致性 / 重连 / 请求报错

- **会话一直加载（根因）**：Mac 用 `session(for:)` 返回的 struct 副本加密响应，每条响应的 seq 都是 1；手机只认第一条，其余全部按重放丢弃。改为在配对管理器里原地收发并写回 seq。
- **两端重启后序列号归零**：envelope 增加随机 `epoch`，只有 epoch 变化才重置接收序号；同一 epoch 内的重复帧仍拒绝。
- **统一连接状态**：iPhone 用 `RemoteLinkState` 作为唯一真相，`isPaired` 与 `isOnline` 分开；Agents 卡片、设备详情、Me 页、对话状态都读同一状态。Mac 中继只在收到帧/心跳回显后才显示在线。
- **Reconnect 真正可用**：设备页掉线时按钮可点、有连接中状态；远程模式不再调用无目标的 `retryLastAttempt()`。
- **请求失败要报错**：核心请求失败立即标离线并抛出，会话列表/对话页显示具体原因和 Retry，不再用空数组或长时间转圈糊过去。
- **中继**：Mac 断开/恢复通知手机；Mac 离线时请求立即回 `mac_offline`；`app/ping`/`app/pong` 应用层心跳；撤销配对先发可读原因。关闭「允许远程会话」会真正停止中继客户端。
- **Agent 读取/发送**：Codex 真实 app-server 读取通过（84 会话 / 80 条消息）；用户从手机实发消息验证 Codex 发送、`/skill-atlas` 加载与执行通过；原生斜杠菜单也用 UI 测试点验（输入 `/atlas` 能列出并点击 `/skill-atlas`）。Claude 30 会话 / 13 条消息读取通过；Claude 发送修了 `--resume` 误传文件路径、Pipe 死锁和可执行文件发现，但本机 Claude CLI 未登录，发送验收待登录后补。Codex/Claude 对话页的 Markdown 渲染也已修复（原 `**`/反引号原样显示）。
- **已配对的手机不再越积越多**：测试曾把配对写进真实 `~/.flowcue/remote-pairs.json`（一次 `swift test` 加一条）。测试改用临时目录；配对记录带手机名/时间，同一台手机重配自动替换，最多保留 8 台，设置页可「撤销全部」。
- **Claude Code 保持支持**：本机 CLI 未登录只是本机环境限制，不撤下 Agent。测试用户若已登录自己的 Claude Code CLI，仍应能列出/读取/发送；没有订阅也可选 Anthropic Console API billing。Claude Desktop（`claude-app`）是独立 Agent，需单独的 UI 自动化适配器，不能与 CLI 混用。
- **Skill 菜单全量**：空 query 不再只显示前 30 个；菜单可滚动，Skill Atlas 可找到（索引 82），不是软链问题。
- **Slash 菜单卡死修复**：菜单改为 ScrollView 底部 overlay，避免菜单+键盘+ScrollView 布局循环；`/atlas` UI 测试通过。
- **Codex/Claude 增量消息**：Agent 消息接口支持 `?after=count`，首次全量、后续只取新增；Codex full=65 → after=64 返回 1 条。
- **Claude 登录预检**：`/v1/agents` 读取 `claude auth status`，未登录时 canSend=false；iOS 禁用发送并提示 `claude auth login`。
- **Codex activity**：从 Codex 会话 JSONL 的 task_started/task_complete 推断，90 秒无更新视为中断；/activity 对 Codex 生效。
- **幂等发送验证**：同一 DSH requestID 连续发送两次，Mac 回放缓存，会话只新增一条用户消息；Codex 同一 requestID 连续两次发送也只产生一条 user 消息。
- **幂等发送、增量 DSH、协议 v2**：Codex/Claude + DSH 发送复用 request id，Mac 去重回放；DSH `?after=count` 只拉新增；协议升到 2，旧端明确提示升级。
- **幂等发送与增量 DSH**：AgentChatView Retry 复用 request id，Mac POST 响应缓存去重；DSH 轮询改 `?after=count`，首次全量、后续只取新增。
- **远程稳定性**：修复 DSH 大响应超过 Cloudflare 1MiB 导致的断线/重连循环；响应分块 + zlib 压缩；Mac/iOS 串行解密/发送；pending 先登记再发；重连退避只在真实响应后清零。
- **Codex/Claude 发送可见性与复制**：发送后立即显示乐观气泡，并 3 秒轮询会话文件；失败可重试；用户/助理消息可长按选择复制；助理 Markdown 统一渲染。真机自测确认发送后 4 秒内可见乐观气泡；修复了已有 “ok” 消息导致乐观气泡误清除、以及聊天页未滚到底的问题；模拟器 UI 测试确认发送消息和 `ok` 回复都在底部可见；发送失败→Retry→重新发送也通过故障注入测试；发送失败横幅与读取失败分开，Claude Code 未登录时提示 `claude auth login`。新增 `docs/AGENT_PARITY.md`，以 DSH 为参考逐项验收。
- **UI/UX**：大字号下 tab bar 限幅 + Large Content Viewer；Disconnect/Change code 纵向排列；设备页 info 值跟随字号；Me/Settings 值允许换行；筛选 chip 实心底；亮色主题状态色与按钮文字对比度修正；远程文案中英双语；Pairing 指纹按远程 pairID 生成。
- 验证：`swift test` 153 项、2 跳过、0 失败；中继 Node 协议测试 13/13；模拟器 Reconnect UI 测试通过；故障注入 3 轮 Offline 0.6s / Online 1.6–1.9s；真机 1.1.18 (109) Online → Offline → 手动 Reconnect → Online，DSH 对话正常加载。

## Mac 1.1.11 补丁 — 局域网接口鉴权修复（安全）

- **严重**：`/v1/agents`、`/v1/agents/*`、`/v1/skills` 原先在鉴权 guard 之前处理，
  同一 Wi-Fi 内任何人都能读会话、读消息、甚至发消息，无需配对码。
  现已把所有入口移到鉴权之后，仅 `/v1/ping` 保持公开（配对前版本握手需要）。
- 新增 `dispatchRemote(method:path:headers:body:)`：中继隧道复用同一套路由，
  端点不再分叉（Remote M2 的基础）。

## 1.1.18 — 修复远程模式下对话永远空白

- `dshMessages` / `messages` 开头有 `guard let selected else { return [] }`，
  而远程模式下 selected 来自局域网发现、通常为 nil：
  **打开对话时直接返回空数组，一个请求都不发**。
  Mac 日志里从未出现过 messages 请求，就是这个原因。
- 改为隧道在线时用占位 endpoint 发请求，由隧道接管。

## 1.1.17 — 远程请求不再互相阻塞

- 手机轮询拆分：审批/提问 3 秒一次，Agent 汇总改为 30 秒一次
  （`/v1/agents` 实测 8.8 秒、`/v1/threads` 5–9 秒，每 3 秒发一次会把
  对话请求堵在队列里，表现为「连上了但对话加载不出来」）
- Mac 端 Agent 汇总缓存 60s → 120s，Codex 线程缓存 TTL 提到 20s

## 1.1.16 — 远程请求带上鉴权头（关键修复）

- 隧道请求原来没有带 `Authorization`，Mac 端统一鉴权后所有远程请求
  都被 401 拒掉：对话打不开、消息加载不出来，Agents 页显示的是本地缓存。
- 断线提示不再写「same Wi-Fi」——远程模式下没有这个前提。

## 1.1.15 — 远程发送不再被 20 秒超时误判

- 隧道里 POST（发送消息）超时从 20 秒放宽到 90 秒：
  发送要等 Mac 的 agent 桥接返回，20 秒会超时并被标成「未送达」
- Mac 端记录每条隧道请求的方法、路径、状态码与耗时

## 1.1.14 — 配对被拒时给出明确原因

- Mac 判定配对码过期/已用后，通过中继把 rejected 状态回传给手机
- 手机端显示「配对码已过期或已被使用，请在 Mac 上重新生成」，
  不再无限等待批准

## 1.1.13 — 远程配对不再需要先连同一 Wi-Fi

- 手机只凭 6 位码即可配对：中继用码反查是哪台 Mac，直接转发配对请求
- Mac 生成码时把码、机器 ID、公钥一起登记到中继（5 分钟、一码一用）
- 手机侧：知道 macID 就直接建配对，不知道就用码走 claim

## 1.1.12 — 远程配对（中继）

> **发布状态（2026-11-24）**：已上传 TestFlight，`1.1.12 (102)`，Delivery UUID `a6077935-95c4-4065-887e-b42dbc7108a5`，已加入 Internal 测试组。


- 配对面板新增「不在同一 Wi-Fi？」：输入 Mac 上的 6 位码，
  通过中继建立端到端加密隧道
- 私钥存钥匙串；启动时若有凭据自动恢复远程连接
- LAN 连接时记住这台 Mac 的中继身份，供远程配对使用

## 1.1.11 — 网络自愈 + 过滤示例会话

> **发布状态（2026-11-24）**：已上传 TestFlight，`1.1.11 (101)`，Delivery UUID `26b0832a-2807-4d54-90fb-c9680cf13b9f`，已加入 Internal 测试组。


- **IP 变化自动重新发现**：轮询连续失败 3 次后重扫 Bonjour，
  找到同名 Mac 自动切过去。之前 IP 一变就永远 Connection lost。
- **过滤 DSH 示例会话**：`isSeeded` 的会话不再出现在列表里（58 → 57）。
  判断要读会话头，所以做成后台一次性索引并持久化，不进列表路径。

## 1.1.10 — 斜杠菜单：空列表也给反馈

- 输入 `/` 但 skill 列表还没加载时，显示「正在读取 skill 列表…」而不是一片空白
- 打开菜单时主动再拉一次 `/v1/skills`（不依赖进页面时那一次）
- Mac 端 `/v1/ping` 增加 `skillsRequests`，可判断手机是否真的发了请求

## 1.1.9 — 回到底部按钮 + 斜杠唤出 skill

> **发布状态（2026-11-24）**：已上传 TestFlight，`1.1.9 (99)`，Delivery UUID `39afe677-288d-4886-8d94-8c802cf022c8`，已加入 Internal 测试组。


### 修复

- **「回到底部」按钮不是所有对话页都有**：只有 DSH 用的旧 `ChatScreen` 有，
  新写的通用 `AgentChatView`（Codex / Claude）漏了。已补上，
  滚动离开底部时出现，点击平滑回到底部。

### 新增

- **斜杠唤出 skill**：输入框里敲 `/` 会弹出本机 skill 列表（121 个），
  按名字或描述过滤，点一条即填入 `/name `。DSH 与通用对话页都支持。
- Mac 新增 `GET /v1/skills`：扫描 `~/.agents/skills`、`~/.codex/skills`、
  `~/.claude/skills`、`~/.dsh/skills`，读出 SKILL.md 的 name / description。
- skill 列表本地缓存，进页面立即可用。

## 1.1.8 — 会话列表加载加速

> **发布状态（2026-11-24）**：已上传 TestFlight，`1.1.8 (98)`，Delivery UUID `13434ac6-796f-4116-b495-3315e27d3e17`，已加入 Internal 测试组。


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
