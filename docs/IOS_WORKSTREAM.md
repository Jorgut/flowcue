# iOS 工作流交接（独立对话用）

这份文档写给**专门做 iOS 的另一条对话**。macOS 在另一条线并行，两边共用一个仓库，
所以下面这些是硬规则，不是建议。

---

## 1. 你能改什么

| 路径 | 归属 | 说明 |
|---|---|---|
| `Sources/RerouteMobileApp/` | ✅ **只有你能改** | iOS 全部界面与业务 |
| `RerouteMobile.xcodeproj/` | ✅ **只有你能改** | 加文件要改 pbxproj |
| `Sources/CodexIdeaDockCore/` | ❌ **不要改** | 与 macOS 共用，见 §5 |
| `Sources/CodexIdeaDockApp/` | ❌ 不要改 | macOS 专属 |
| `docs/design/`、`docs/UI_DIRECTION.md` | 只读 | 设计依据 |

**提交时永远显式列路径**，不要用 `git add -A` / `git add .`——另一条线可能正有未完成的改动。

```bash
git add Sources/RerouteMobileApp/RerouteMobileApp.swift
```

---

## 2. 分支

- iOS 线开工前先建分支：`git switch -c ios/screens`
- macOS 线在 `feat/subscription-paywall`（或后续 `mac/*`）
- 一轮做完再合并，**不要两边同时改同一个文件然后互相 rebase**

---

## 3. 设计依据在哪

| 内容 | 位置 |
|---|---|
| iOS 全部界面稿 | `docs/design/ios/`（47 张，1600px 宽 JPEG） |
| 规范正文 | `docs/UI_DIRECTION.md` §9（iOS 方向稿、25 个界面） |
| 颜色 / 圆角 / 字号 | `docs/UI_DIRECTION.md` §2 |
| 图标与角色 | `docs/design/construct-*.jpg`、`docs/design/mic*.jpg` |

**做任何一屏之前，先打开对应设计稿看尺寸和层级，不要凭印象。**

---

## 4. 必须用现成的设计系统

代码里已经有了，**不要再手写颜色和圆角**：

| 东西 | 位置 |
|---|---|
| 语义颜色 / 圆角 / 间距 / 窗口尺寸 | `FlowCueDesignTokens`（Core） |
| iOS 桥接（`Color(hex:)`、`UIColor(hex:)`、`FlowCueMobileTheme`） | `Sources/RerouteMobileApp/FlowCueMobileTheme.swift` |
| 共用组件（状态点 / 胶囊 / 列表行 / 输入条 / 用量环） | `FlowCueComponents`（Core） |

规则：

- 视图里**不出现十六进制**
- 圆角只用 16 / 14 / 10 三档
- 状态**颜色 + 文字**双通道，不能只靠颜色

---

## 5. 需要新 API 怎么办

`Sources/CodexIdeaDockCore` 由 macOS 线维护。iOS 需要新的存储 / 桥接能力时：

1. 在对话里说明需求（要什么数据、什么时机）
2. 由 macOS 线加进 Core
3. 你只消费接口

**不要自己往 Core 里加文件**，否则两边会冲突。

---

## 6. 当前 iOS 代码状态

- 主文件：`Sources/RerouteMobileApp/RerouteMobileApp.swift`，**约 2500 行单文件**
- 结构：`RootTabView`（Ideas / Agents / Settings）＋ 多个独立页面
- 主题：`FlowCueTheme` 已改为读 token，明暗自动切换
- `Sources/RerouteMobileApp/FlowCueMobileTheme.swift`：桥接 + hex 初始化
- `Sources/RerouteMobileApp/LaunchFaceAnimation.swift`：**已移除**（动效未定稿，归档在
  `Design/UIExplorations/_archive/process-2026-11-14/`）

改动建议：**一屏一屏改，每屏做完再动下一屏**，不要把单文件拆成大手术。

---

## 7. 构建与验证

```bash
# 构建（模拟器）
xcodebuild -project RerouteMobile.xcodeproj -scheme RerouteMobile \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=5D75E968-F3A8-4961-A193-E6E78E55D895' \
  -derivedDataPath /tmp/ios-dd build

# 安装 + 启动
xcrun simctl install 5D75E968-F3A8-4961-A193-E6E78E55D895 \
  /tmp/ios-dd/Build/Products/Debug-iphonesimulator/Reroute.app
xcrun simctl launch 5D75E968-F3A8-4961-A193-E6E78E55D895 com.archintera.FlowCue

# 截图
xcrun simctl io 5D75E968-F3A8-4961-A193-E6E78E55D895 screenshot /tmp/ios.png
```

> Swift 宏插件（`Observation`）在文件沙箱下会失败。构建/测试需要用**完全访问权限**运行，
> 否则报 `external macro implementation type ... could not be found`。

---

## 8. 每屏完成的定义

一屏算完成，必须同时满足：

1. 编过、能在模拟器里跑起来
2. **和设计稿并排比对**，差异列成清单
3. 差异清单里没有「未说明」的项——要么改掉，要么说明为什么不做

对比工具（仓库里已有）：

```bash
swift Scripts/compare-design.swift docs/design/ios/<设计稿>.jpg /tmp/ios.png /tmp/compare.png "设计稿" "实现"
```

---

## 9. 不要做的事

- 不加第三方依赖（无 SPM 包、无 CocoaPods）
- 不改 `Bundle ID`、SwiftData 配置名、窗口恢复键
- 不动 `marketing/`、`Design/UIExplorations/`
- 不在测试里读写真实数据库 / UserDefaults
- 不为了验证申请麦克风、辅助功能、Apple Events 权限

---

## 10. 建议的第一屏

`docs/design/ios/` 里优先做**主页（Ideas）**：

- 它已经在 TestFlight 上，用户能立刻看到
- 设计稿：`ios-home` 相关图
- 现有实现：`RootTabView` 里的 `List` + `IdeaRow`

做完这一屏再往下走 Agents / Chat / Settings。
