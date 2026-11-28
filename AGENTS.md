# FlowCue 项目约定

- 原生 macOS 14+ 菜单栏应用；Swift 6、SwiftUI、AppKit、SwiftData，无第三方包依赖。
- 开工先读 `README.md`、`PROJECT_STATE.md` 和共享协作记录。全局工程规则继续适用。
- 本目录为后续开发入口；原始日期目录只作恢复参考，不双向同步、不覆盖或删除旧成果。
- `Sources/CodexIdeaDockCore`：本地存储、任务读取、显式 Queue 与进程管理。
- `Sources/CodexIdeaDockApp`：窗口、输入、菜单栏、快捷键与前台宿主策略。
- `Sources/CodexIdeaDockProcessLauncher`：独立进程组 helper；缺失时必须失败关闭。
- `Tests/CodexIdeaDockCoreTests`：存储、桥接、宿主策略、图标回归。
- 提交纪律：**只 `git add` 本次真正改动的具体路径**，禁止 `git add -A` / `git add .` / `git add Sources`。
  本工作区同时跑 macOS 与 iOS 两条线，宽泛暂存会把另一条线的半成品卷进提交。
- 验证：`swift test`。打包：`zsh Scripts/build-app.sh`。环境问题先参考 `PROJECT_STATE.md`。
  iOS CloudKit 聊天包必须同时传 `FLOWCUE_CLOUDKIT_CHAT_ENABLED=YES` 与 `FLOWCUE_CLOUDKIT_ENVIRONMENT=Production`，少一个手机只会等局域网、永远不「上线」。
- 不更改兼容标识：Bundle ID、SwiftData 配置名、窗口恢复键、App Server client name，详见 README。
- 原始想法、草稿、正式数据库及 UserDefaults 不用于写入测试数据。
- Queue 必须由用户明确触发；结果不确定时不自动重试，不记录正文或原始 CLI 错误。
- 真实集成默认只验证 `thread/list`，不自动发送 Queue，不直接读写 Codex 数据库。
- 正式图标方向固定为 B1-L；图标修改后验证 ICNS 十种表示与菜单栏模板。
- 不为验证申请麦克风、辅助功能或 Apple Events 权限。
- 只清理本次启动的测试进程；保留用户已有进程与成果。
- 当前阶段为本机版本验收；公开分发签名、公证和其他 Agent 投递适配尚不在此版本中。

## 仓库与分支（2026-11-28）

- `Jorgut/flowcue` 是**公开**仓库，推上去不可撤回，所以默认私有、公开需显式决定。
- 只有 `.githooks/public-branches.txt` 白名单里的分支能推 `origin`；其余分支（`android/*`、`wip/*`、未定稿功能线）只本地 + 私有镜像。要新开公开分支，先登记再推。
- 所有迭代在本目录（本地工作副本）进行；私有仓是**单向镜像**，不在其上开分支或提交。同步：`zsh Scripts/mirror-backup.sh`。
- 新克隆先 `git config core.hooksPath .githooks`，否则白名单与误推拦截不生效。
- 设备 UDID、issuer ID、密钥/描述文件路径、未发布的商业策略不进公开仓；写进 `PROJECT_STATE.md`（不入库）。详见 `docs/BRANCH_POLICY.md`。
- 本轮最新事实与未解决项：`docs/HANDOFF_GROKBOT_2026-11-28.md` 的「第二轮」一节。

## 工作区（2026-11-19 重排）

- 本仓库是代码主目录。官网在同一个仓库的 `main` 分支，通常检出到 `../FlowCue-Worktrees/site`。
- 设计、宣发、历史发布包在 `../FlowCue-Assets`，**不入库，不要提交**。
- 本机绝对路径见 `PROJECT_STATE.md`（本地文件，不入库）。
