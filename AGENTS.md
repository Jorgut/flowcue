# Reroute 项目约定

- 原生 macOS 14+ 菜单栏应用；Swift 6、SwiftUI、AppKit、SwiftData，无第三方包依赖。
- 开工先读 `README.md`、`PROJECT_STATE.md` 和共享协作记录。全局工程规则继续适用。
- 本目录为后续开发入口；原始日期目录只作恢复参考，不双向同步、不覆盖或删除旧成果。
- `Sources/CodexIdeaDockCore`：本地存储、任务读取、显式 Queue 与进程管理。
- `Sources/CodexIdeaDockApp`：窗口、输入、菜单栏、快捷键与前台宿主策略。
- `Sources/CodexIdeaDockProcessLauncher`：独立进程组 helper；缺失时必须失败关闭。
- `Tests/CodexIdeaDockCoreTests`：存储、桥接、宿主策略、图标回归。
- 验证：`swift test`。打包：`zsh Scripts/build-app.sh`。环境问题先参考 `PROJECT_STATE.md`。
- 不更改兼容标识：Bundle ID、SwiftData 配置名、窗口恢复键、App Server client name，详见 README。
- 原始想法、草稿、正式数据库及 UserDefaults 不用于写入测试数据。
- Queue 必须由用户明确触发；结果不确定时不自动重试，不记录正文或原始 CLI 错误。
- 真实集成默认只验证 `thread/list`，不自动发送 Queue，不直接读写 Codex 数据库。
- 正式图标方向固定为 B1-L；图标修改后验证 ICNS 十种表示与菜单栏模板。
- 不为验证申请麦克风、辅助功能或 Apple Events 权限。
- 只清理本次启动的测试进程；保留用户已有进程与成果。
- 当前阶段为本机版本验收；公开分发签名、公证和其他 Agent 投递适配尚不在此版本中。
