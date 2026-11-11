# Changelog

本项目遵循语义化版本号。公开发布前的构建记录在本文件中维护。

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
