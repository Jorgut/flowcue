# 发布审查：Reroute

更新日期：2026-09-19

当前产品是 macOS 菜单栏本地应用。GitHub 源码发布可以在品牌与许可证确认后进行；当前二进制不能直接提交 Mac App Store，也不存在 iOS target。

## 审查结论

| 优先级 | 数量 | 结论 |
| --- | ---: | --- |
| 阻断 | 6 | 发布前必须解决 |
| 高 | 5 | 商店构建前解决 |
| 中 | 4 | TestFlight 前解决 |

## 阻断项

### 1. 品牌名称已确定，但精确 App Store 名称已被占用

原工作名称 FlowCue 因 App Store 和多个软件服务存在同名冲突而停用。2026-09-19 已确认公开品牌名称为 **Reroute**，本机应用和仓库文档已完成品牌迁移。

实时核查确认 App Store 已存在另一开发者发布的 `Reroute: Fix Technoference`，其安装名和商店品牌均使用 Reroute。Apple 规定另一开发者已使用的 App Store 名称不能再次创建，除非持有可主张的商标权。

应用内品牌仍可保留 Reroute，但 App Store Connect 记录必须使用不超过 30 个字符的唯一名称，例如候选 `Reroute: Idea Queue`；最终可用性需在 App Store Connect 实际创建记录时确认。正式发布前仍需完成商标、域名和 GitHub 仓库名核查。

### 2. GitHub 远端发布尚未完成

本地 `main` 已建立原子化提交历史和 CI，但尚无远端或上游分支；本机 GitHub CLI 登录需要更新。外部发布前还需要：

1. 确认公开或私有；
2. 确认开源许可证或保留版权；
3. 重新登录 GitHub；
4. 创建远端并推送本地历史；
5. 验证 CI 和仓库私密漏洞报告功能。

本机 `PROJECT_STATE.md` 含绝对路径，已从 Git 范围排除。

### 3. 没有 iOS 应用目标

现有 Swift Package 只声明 macOS 14，界面使用 AppKit、Carbon 全局快捷键、菜单栏窗口与本机进程控制。iOS 版需要新的 Xcode 工程、iOS App target、移动端导航与输入体验、应用图标和启动资源。

可复用部分主要是数据模型、草稿/收件箱逻辑和失败状态语义；`CodexBridge`、窗口控制、全局快捷键和进程 helper 不能复用到 iOS。

### 4. 当前 Mac 架构与 App Sandbox 冲突

Mac App Store 要求 App Sandbox。当前应用会：

- 查找 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`；
- 启动 bundle 外的 Codex CLI；
- 通过子进程环境访问用户的 Codex 状态；
- 管理独立进程组并发送终止信号。

这些能力不能作为沙箱版的默认实现。商店版必须改为受支持的远程连接、用户明确分享/复制，或独立后端。GitHub 直接下载版可继续保留本地 CLI 适配器。

### 5. 缺少 App Store 工程与签名链

当前由 SwiftPM 和 shell 脚本手工组装 `.app`，使用 ad-hoc 签名。缺少：

- `.xcodeproj` / `.xcworkspace` 与 Archive scheme；
- App Sandbox、网络、App Group 等 entitlements；
- iOS 与 Mac App Store provisioning profile；
- Apple Distribution 证书；
- App Store Connect 应用记录；
- 可验证的 archive 与上传流程。

本机当前显示 0 个有效代码签名身份。Xcode 已记录一个个人团队，但不能据此确认它属于本项目的发布账号。

### 6. Xcode 法律与环境状态未完成

默认 `xcrun` 会因 Xcode 许可尚未接受而返回 69。接受许可属于开发者账号持有人需要亲自完成的法律操作；完成前不能进行正式 Archive、验证和上传。

## 高优先级项

### 隐私清单与商店隐私标签

项目没有 `PrivacyInfo.xcprivacy`。现有代码使用 `UserDefaults`；iOS target 至少需要为仅应用自身读取写入声明 `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`。无追踪、无广告、无第三方 SDK 时应保持：

- `NSPrivacyTracking = false`；
- tracking domains 为空；
- collected data 以实际传输架构为准。

如果商店版把想法正文发送到用户 Mac 或云服务，隐私清单、隐私政策和 App Store Connect 标签必须准确描述用户内容的处理方式，不能沿用当前“全部本地”的表述。

### 传输协议仍未稳定

OpenAI 的 Codex app-server daemon 文档说明它支持桌面和移动远程客户端，但同时标注远程管理生命周期仍是实验性。采用远程伴侣架构前，需要验证：

- 公开支持和兼容承诺；
- 配对、认证、TLS 和凭证撤销；
- 局域网与远程网络的发现方式；
- Queue/steer 的稳定 RPC；
- App Review 可复现的演示账号和审核说明。

### Bundle ID 与数据迁移

当前本机版继续使用 `com.altn.codex-idea-dock`，用于保留本地历史数据。App Store 版本仍需确认独立 Bundle ID，并决定：

- GitHub 版是否保留旧 ID 读取现有数据；
- App Store 版是否使用新容器；
- 是否提供一次性导出/导入，而不是跨签名直接迁移数据库。

### 商店元数据缺失

需要准备：隐私政策 URL、支持 URL、营销 URL（可选）、App 描述、关键词、分类、版权主体、年龄分级、审核说明、截图、预览视频（可选）、出口合规回答与无障碍声明。

### 公开仓库法律信息未确认

公开仓库需要明确许可证。README 已加入非官方项目声明，避免用户误以为 OpenAI 背书；发布页、商店描述和截图也必须使用相同口径。

## 中优先级项

- 为首次启动增加清晰的 Codex 连接状态、依赖检查和失败恢复入口。
- 为移动端设计分享扩展、离线队列和连接中断状态。
- 在最低支持系统与最新系统分别完成 VoiceOver、键盘、动态字体和减少动态效果验收。
- 在 TestFlight / TestFlight for Mac 阶段完成崩溃、升级和数据迁移测试。

## 推荐发布结构

### GitHub / 直接下载版

保留本机 CLI 和菜单栏体验，发布源码，并在有 Developer ID 后提供已签名、公证的 Mac 构建。该版本不受 Mac App Store 沙箱限制，但仍应使用 Hardened Runtime 和最小权限。

仓库已包含 `Scripts/release-macos.sh`。该脚本会拒绝 ad-hoc 身份，只在 Developer ID 签名、公证、票据装订和 Gatekeeper 检查全部通过后生成版本化 ZIP 与 SHA-256 文件。

### App Store 版

共享本地草稿、收件箱和状态模型，使用独立传输协议：

1. **远程伴侣**：iOS/macOS 沙箱客户端连接用户 Mac 的 Codex 远程服务；能力最接近现有产品，但必须先验证实验协议。
2. **仅捕捉与分享**：首版只保存、复制或通过系统分享给 Codex；审核和开发风险最低。
3. **自建云服务**：跨设备能力最完整，但新增账号、后端、安全、隐私和运营责任。

不建议通过临时沙箱例外继续启动外部 CLI；这会让核心功能依赖不可持续的审核路径。

## 发布门槛

### GitHub

- [x] 最终品牌确认：Reroute
- [ ] GitHub 仓库名确认（建议使用能区分同名项目的 `reroute-codex`）
- [ ] 可见性与许可证确认
- [ ] 本机 GitHub 重新登录
- [ ] CI 通过
- [ ] 无秘密、证书、profile、真实任务正文和机器路径进入 Git 历史
- [ ] 创建 `v0.1.0` 源码标签；二进制 Release 仅在 Developer ID、公证和安装验证后提供

### App Store

- [ ] 商店版传输架构确认
- [ ] 唯一 App Store 名称确认（精确名称 `Reroute` 已被其他开发者占用）
- [ ] Xcode 工程、iOS target、Mac App Store target 和共享模块完成
- [ ] 唯一 Bundle ID 与发布团队确认
- [ ] App Sandbox 和最小 entitlements 验证
- [ ] Privacy manifest、隐私政策和隐私标签一致
- [ ] Apple Distribution 签名、Archive Validate 和 TestFlight 通过
- [ ] 审核说明提供可复现连接方式
- [ ] 元数据、截图、年龄分级和出口合规完成

## 官方依据

- [Apple：Mac App Store 必须启用 App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Apple：App 名称不可用时的处理方式](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)
- [App Store：已存在的 Reroute 应用](https://apps.apple.com/us/app/reroute-fix-technoference/id6780990045)
- [Apple：准备应用分发](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple：隐私清单](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Apple：上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [OpenAI Codex app-server daemon](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md)
- [OpenAI 品牌规范](https://openai.com/brand/)
