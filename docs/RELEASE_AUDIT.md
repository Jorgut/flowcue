# 发布审查：Reroute

更新日期：2026-09-22

当前产品是 macOS 菜单栏本地应用。GitHub 源码发布的本地准备已经完成，外部发布等待明确授权；当前二进制不能直接提交 Mac App Store，也不存在 iOS target。

## 审查结论

| 优先级 | 数量 | 结论 |
| --- | ---: | --- |
| 阻断 | 5 | 发布前必须解决 |
| 高 | 4 | 商店构建前解决 |
| 中 | 4 | TestFlight 前解决 |

## 阻断项

### 1. 品牌名称已确定，但精确 App Store 名称已被占用

原工作名称 FlowCue 因 App Store 和多个软件服务存在同名冲突而停用。2026-09-19 已确认公开品牌名称为 **Reroute**，本机应用和仓库文档已完成品牌迁移。

实时核查确认 App Store 已存在另一开发者发布的 `Reroute: Fix Technoference`，其安装名和商店品牌均使用 Reroute。Apple 规定另一开发者已使用的 App Store 名称不能再次创建，除非持有可主张的商标权。

应用内品牌仍可保留 Reroute，但 App Store Connect 记录必须使用不超过 30 个字符的唯一名称，例如候选 `Reroute: Idea Queue`；最终可用性需在 App Store Connect 实际创建记录时确认。正式发布前仍需完成商标、域名和 GitHub 仓库名核查。

### 2. GitHub 远端发布尚未完成

本地 `main` 已建立原子化提交历史和 CI，但尚无远端或上游分支。GitHub CLI 当前已登录 `Jorgut`，候选公开仓库 `Jorgut/reroute-codex` 尚不存在，MIT 许可证与非官方项目声明已经就绪。外部发布仍需要用户明确批准具体仓库、公开可见性以及要推送的历史范围。

2026-09-22 的本地公开前扫描覆盖全部 64 个历史 blob：未发现私钥、常见 GitHub/OpenAI/AWS/Slack 令牌、Apple 私钥文件名或真实机器路径；版本控制内最大文件约 41 KB。完整历史的提交作者邮箱为 `honaler@gmail.com`，若按原历史公开，该邮箱也会公开。创建远端后仍需验证 GitHub Actions 的全新检出构建，并开启仓库私密漏洞报告功能。

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

当前由 SwiftPM 和 shell 脚本手工组装 `.app`。本机已安装有效的 Developer ID Application 与 Apple Distribution 身份，Developer ID 私钥和 Hardened Runtime 签名已验证；但商店发布链仍缺少：

- `.xcodeproj` / `.xcworkspace` 与 Archive scheme；
- App Sandbox、网络、App Group 等 entitlements；
- iOS 与 Mac App Store provisioning profile；
- App Store Connect 应用记录；
- 可验证的 archive 与上传流程。

## 已完成的直接下载验证

2026-09-22 用户已亲自接受 Xcode 与 Apple SDK 许可。随后使用当前 `HEAD` 的全新 `git archive` 检出，按 CI 顺序重新生成图标、运行 51 项测试（50 通过、1 项真实连接按设计跳过）并完成 release 应用构建与严格签名验证。

正式下载包使用 `Developer ID Application: hong liang zhu (GB38532D8G)` 签名，并通过钥匙串配置 `Reroute-Notary` 提交 Apple 公证。提交 `8db35894-d3bd-4d4f-bc38-5226b5da316b` 状态为 `Accepted`；票据装订、`stapler validate`、Gatekeeper、ZIP 完整性、SHA-256、版本、架构与隐私清单复核全部通过。

本地产物为 `Reroute-0.1.0-macOS-arm64.zip`，大小 1,620,245 bytes，SHA-256 为 `8e9929cc7273e455f231e4b0567d3d26500db71773239979cc78d96cead3eaa3`。该文件尚未上传或公开。

## 高优先级项

### 隐私清单与商店隐私标签

项目现已包含与当前直接下载版实际数据流一致的 `PRIVACY.md`，发布后可作为公开隐私政策页面。`Support/PrivacyInfo.xcprivacy` 已声明无追踪、无收集数据，并为仅应用自身读写的 `UserDefaults` 声明 `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`；打包脚本会把它复制到应用 bundle。未来 Xcode 商店 target 仍需把同一文件加入 Copy Bundle Resources，并用 Xcode Privacy Report 复核。当前应保持：

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

MIT 许可证、隐私政策、支持说明和 README 非官方项目声明已经完成。发布页、商店描述和截图仍需保持相同口径。

## 中优先级项

- 为首次启动增加清晰的 Codex 连接状态、依赖检查和失败恢复入口。
- 为移动端设计分享扩展、离线队列和连接中断状态。
- 在最低支持系统与最新系统分别完成 VoiceOver、键盘、动态字体和减少动态效果验收。
- 在 TestFlight / TestFlight for Mac 阶段完成崩溃、升级和数据迁移测试。

## 推荐发布结构

### GitHub / 直接下载版

保留本机 CLI 和菜单栏体验，发布源码，并提供已经 Developer ID 签名、公证的 Mac 构建。该版本不受 Mac App Store 沙箱限制，但仍使用 Hardened Runtime 和最小权限。

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
- [x] 候选 GitHub 仓库名：`Jorgut/reroute-codex`
- [x] 开源许可证：MIT
- [x] 本机 GitHub 登录：`Jorgut`
- [ ] 明确批准公开可见性与完整提交历史（包含作者邮箱）
- [ ] CI 通过
- [x] 本地历史扫描未发现秘密、证书、profile、真实任务正文和机器路径
- [x] 全新检出生成图标、测试、release 构建与严格签名验证通过
- [x] Developer ID 签名、Apple 公证、票据装订、Gatekeeper 与最终 ZIP 独立验证通过
- [ ] 创建 `v0.1.0` 源码标签，并上传已验证的 ZIP 与 SHA-256

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
