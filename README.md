# Reroute

> 发布状态：当前是已验证的本机 macOS 原型，尚未发布到 GitHub Releases 或 App Store。公开品牌名称已确定为 Reroute；App Store 已有其他开发者使用精确名称 `Reroute`，商店记录必须采用可用的唯一名称，商标核查仍需在正式发布前完成。

Reroute 是一个本地运行的 macOS 菜单栏应用，用来随时捕捉想法，并在你明确选择后通过 Codex Queue 投递到指定任务。默认操作只保存到本地，不会改变正在执行的 Codex 任务。

## 主要能力

- `⌃⌥Space` 全局唤起悬浮输入窗
- 原生文本输入、粘贴、中文输入法与 macOS 系统听写；Voicebox 生成的文字可粘贴进来，未接入 Voicebox API
- 来源任务与目标任务分开记录
- 草稿实时持久化，关闭或崩溃后恢复
- 本地收件箱、搜索、筛选、归档与撤销
- 显式调用 `codex queue`，失败时保留内容并支持复制
- 投递结果不确定时停止重试，避免向任务发送重复消息
- 不使用辅助功能权限、麦克风权限或云同步
- Codex、Claude Desktop 或支持的终端在前台时保持悬浮；普通应用在前台时恢复普通窗口层级

当前版本为 **0.1.0 (5)**，采用已确认的 B1-L（`｜ + 左向 ↵`）图标。发布审查与平台改造范围见 [发布审查](docs/RELEASE_AUDIT.md)。

## 发布边界

当前实现依赖本机 Codex CLI 与 App Server，只能作为 macOS 本地版本运行。Mac App Store 要求启用 App Sandbox；iOS 也不能启动本机命令行进程，因此两个商店版本都需要新的传输适配器，不能直接提交当前应用包。

Reroute 是独立的第三方项目，与 OpenAI 无隶属、合作、认证或官方背书关系。Codex、OpenAI 和相关标识归各自权利人所有。

## 许可证

源码使用 [MIT License](LICENSE) 发布。

## 开发

要求 macOS 14 或更新版本、Xcode 16 或更新版本，以及支持 `queue` 子命令的 Codex CLI。

请先完成 Xcode 首次启动设置并由使用者审阅、接受许可；如果命令返回 69，这属于本机开发环境尚未就绪。图标编译需要完整 Xcode 中的 `actool`，只有 Command Line Tools 不足以完成打包。

```bash
swift Scripts/render-reroute-icon.swift
swift test
swift build --product CodexIdeaDockProcessLauncher
swift run CodexIdeaDock
```

开发运行也必须先构建进程组 helper；如果 helper 缺失，应用会拒绝启动 Codex CLI，而不会退回到无法完整清理子进程的直接启动方式。正式使用请优先运行下方打包脚本。

## 构建应用

```bash
zsh Scripts/build-app.sh
open "dist/Reroute.app"
```

打包脚本默认生成本地 ad-hoc 签名的 `dist/Reroute.app`。设置 `REROUTE_CODE_SIGN_IDENTITY` 时，会改用指定的 Developer ID Application 身份并启用 Hardened Runtime 与安全时间戳。正式想法、任务缓存与投递记录存放于 `~/Library/Application Support/CodexIdeaDock.store`；正在输入且尚未完成 SwiftData 写入的短期崩溃恢复缓冲存放于该 bundle 的本地 UserDefaults。两者都只在本机使用，不启用 CloudKit。

这是本机使用版本，尚未使用 Developer ID 签名或进行 Apple 公证，不作为对外分发包。重新构建前先正常退出正在运行的 Reroute，完成后从上述明确路径打开，避免旧实例截获快捷键和打开请求。

公开下载版必须先把公证凭据安全存入钥匙串，再运行发布脚本。脚本只接受 Developer ID Application 身份，完成签名、公证、票据装订与 Gatekeeper 检查后，才会生成 ZIP 和 SHA-256 文件：

```bash
xcrun notarytool store-credentials "Reroute-Notary"
REROUTE_CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
REROUTE_NOTARY_PROFILE="Reroute-Notary" \
zsh Scripts/release-macos.sh
```

GitHub Release 文案和安装说明见 [0.1.0 发布说明](docs/RELEASE_NOTES_0.1.0.md)。不要公开上传默认 ad-hoc 签名的 `dist/Reroute.app`。

构建时会先从 `Scripts/render-reroute-icon.swift` 重新生成应用图标和菜单栏模板图，再在临时目录中组装、校验和签名应用；全部成功后才替换现有 `Reroute.app`。如果 `dist` 中存在另一个使用相同 Bundle ID 的旧 `.app`，构建会停止，避免 macOS 启动错误版本。

图标生成和应用编译统一使用 `PATH` 中的 `swift`。需要显式选择工具链时，可设置 `DEVELOPER_DIR`、`PATH` 和 `SDKROOT`；本机验证过的完整命令见 [PROJECT_STATE.md](PROJECT_STATE.md)。

## 验证

首次克隆后先运行图标渲染脚本，再执行 `swift test`。测试使用隔离存储，不写入正式收件箱。真实 App Server 读取默认跳过，可单独启用：

```bash
CODEX_IDEA_DOCK_REAL_TEST=1 swift test --filter CodexBridgeTests/testRealAppServerReadIsOptIn
```

该测试只读取任务列表。Queue 的参数、成功、失败、不确定结果和防重复投递通过替身进程验证；自动验收不向真实任务发送测试消息。

## 品牌迁移兼容标识

Reroute 沿用以下内部标识，以继续读取改名前已经保存的草稿、想法和窗口状态。没有显式迁移逻辑时，不应直接把它们改成新品牌名：

- Bundle ID：`com.altn.codex-idea-dock`
- SwiftData 配置名与本地数据库：`CodexIdeaDock` / `~/Library/Application Support/CodexIdeaDock.store`
- 收件箱窗口恢复键：`CodexIdeaDock.Inbox`
- App Server 稳定客户端标识：`codex_idea_dock`

首次运行前，也可以先在 Codex 的 `Settings > General > Follow-up behavior` 中选择 `Queue`，作为日常输入的临时保护。Reroute 本身只会在你点击“排到 Codex”或按下 `⌥⌘Return` 时投递。

## 快捷键

- `⌃⌥Space`：显示或隐藏悬浮窗
- `⌘Return`：保存到本地并关闭
- `⌥⌘Return`：排入目标 Codex 任务
- `⌘N`：保存当前想法并开始新想法
- `Esc`：隐藏窗口并保留草稿

## 隐私边界

应用不直接读取或修改 Codex 的数据库或会话文件。任务列表通过 Codex App Server 的只读接口获取；投递通过官方 `codex queue` 命令完成。应用不会自动发送想法，也不会记录想法正文到日志。

应用将 Codex CLI 放在独立的本地进程组中运行，以便在超时、取消或应用退出时同时结束包装器和子进程。CLI 原始错误输出不会写入 SwiftData；本地只保留固定错误分类、退出码和时间。Codex CLI 目前只接受 `--message <TEXT>`，因此用户显式排队时，正文会在本地 launcher／CLI 进程存活期间短暂出现在本机进程参数中；应用不会把这些参数写入日志或持久化为投递诊断。
