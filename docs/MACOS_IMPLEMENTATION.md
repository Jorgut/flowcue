# macOS 实现现状（2026-11-15）

设计与实现不一致时，**以本文记录的实际实现为准**；设计稿仍是唯一视觉基准。

---

## 1. 界面清单

| 界面 | 实现 | 截图 | 设计稿 |
|---|---|---|---|
| 收件箱（三布局） | ✅ | `design/mac/impl/inbox.png` | `mac-main` · `mac-variants` |
| 捕获面板 | ✅ | `design/mac/impl/panel.png` | `mac-update`（面板部分） |
| 设置 · 通用 | ✅ | `settings-general.png` | `mac-settings-a` |
| 设置 · 面板 | ✅ | `settings-panel.png` | `mac-settings-a` |
| 设置 · Agent | ✅ | `settings-agents.png` | `mac-settings-a` |
| 设置 · 集成 | ✅ | `settings-integrations.png` | `mac-settings-a` · `errors` |
| 设置 · 远程 | ✅ | `settings-remote.png` | `mac-settings-a` |
| 设置 · 同步 | ✅ | `settings-sync.png` | `mac-settings-a` |
| 设置 · 用量 | ✅ | `settings-usage.png` | `mac-settings-b` |
| 设置 · Pro | ✅ | `settings-pro.png` | `mac-settings-b` |
| 设置 · 更新 | ✅ | `settings-updates.png` | `mac-settings-b` |
| 设置 · 实验室 | ✅ | `settings-lab.png` | `lab-feedback` |
| 设置 · 反馈 | ✅ | `settings-feedback.png` | `lab-feedback` |
| 首启 · 欢迎 / 配对 / 默认 agent | ✅ | `firstrun-0/1/2.png` | `mac-firstrun` |
| 本机 Agent 浏览器 | ✅ | `agents.png` | 无对应设计稿（新增） |

全部截图位于 `docs/design/mac/impl/`。

---

## 2. 与设计稿的已知差异

| 位置 | 设计稿 | 实现 | 原因 |
|---|---|---|---|
| 窗口尺寸 | 980×640 | **1040×680**；最小 460×520 | 参考 Cursor / Ollama / OpenCode 的尺寸区间 |
| 收件箱头部 | 标题 + 状态 + 捕获条 | 单行：品牌 + 状态 + 布局切换 + 新想法 | 高度让给列表 |
| 捕获条位置 | 头部下方通栏 | **左栏顶部** | 与列表同列，鼠标移动更短 |
| 用量 | 两张卡片留在头部 | 移出主窗口，收进状态行气泡里的**圆环** | 主窗口不再放长期信息 |
| 面板头部 | 品牌 + 状态 + × | 品牌 + 状态 + **来源→目标 选择器** | 选择器是高频操作 |
| 面板模板菜单 | 无 | 编辑区右上角图标（悬停提示） | 原为独立一行，占 28pt |
| 首启窗口 | 约 880×430 | **680×400**，内容居中 | 内容没那么多 |
| 配对码 | 8 位字母数字 | **6 位数字**（与 iPhone 端一致） | 不为了好看改成对不上 |
| 状态文案 | `Codex · 12ms` | `Codex · N sessions` | 无延迟数据，不编造 |

---

## 3. 状态从哪来（没有假数据）

| 显示 | 来源 |
|---|---|
| 收件箱条数 | SwiftData 本地库 |
| 状态点（草稿 / 排队 / 已保存 / 失败） | `CaptureStatus` |
| Codex `app-server available` | 启动 `codex app-server` 并完成握手 |
| DSH `Connected` | TCP 探测 `127.0.0.1:47823` |
| 端口被占用 | 尝试 bind 该端口失败 |
| Codex hooks 已安装 | `~/.codex/hooks.json` 或 `config.toml` 里的登记 |
| 用量百分比 | Codex `account/rateLimits/read` |
| 本机 agent 列表 | 候选路径 + `<binary> --version` |

**没有后端就没有后端**：反馈页的「发送」只把内容放进剪贴板并打开邮件应用，不做静默上报。

---

## 4. 验证方式

```bash
# 打包
zsh Scripts/build-app.sh

# 按窗口截图（不受 Space / 多显示器影响）
swift Scripts/shot-window.swift FlowCue /tmp/shot.png
swift Scripts/shot-window.swift FlowCue /tmp/panel.png --size 520x280

# 设计稿 vs 实现
swift Scripts/compare-design.swift docs/design/mac/mac-main.jpg /tmp/shot.png /tmp/cmp.png

# 测试
swift test
```

> Swift 宏插件在文件沙箱下会失败，构建与测试需要完全访问权限。

结果：`Executed 77 tests, with 1 test skipped and 0 failures`。

调试入口：

| 参数 | 作用 |
|---|---|
| `--args -inbox` | 直接打开收件箱 |
| `--args -settings [-settingsPage <page>]` | 直接打开设置某页 |
| `--args -firstrun [-firstrunStep 0/1/2]` | 重看首启 |
| `--args -agents` | 打开本机 Agent 浏览器 |
| `--args -panel` | 只显示捕获面板（便于截图） |

---

## 5. 未完成

| 项 | 状态 |
|---|---|
| 分支拆分（macOS / iOS 混在 `ios/screens`） | 等 iOS 线停手 |
| 菜单栏按钮的 Liquid Glass 外观 | 未处理 |
| 面板失去焦点自动收起 | 当前为手动关闭 |
| 错误页剩余态（端口占用时的「换端口」动作） | 只给说明，不自动改端口 |
