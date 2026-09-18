# Contributing

感谢参与改进本项目。提交改动前，请先阅读 [README](README.md) 和 [发布审查](docs/RELEASE_AUDIT.md)。

## 开发环境

- macOS 14 或更新版本
- 完整 Xcode 16 或更新版本
- Swift 6
- 支持 `queue` 子命令的 Codex CLI（仅真实本地集成需要）

## 验证

```bash
swift Scripts/render-flowcue-icon.swift
swift test
zsh Scripts/build-app.sh
codesign --verify --deep --strict dist/FlowCue.app
```

真实 App Server 测试默认跳过，避免 CI 或贡献者机器读取真实任务：

```bash
CODEX_IDEA_DOCK_REAL_TEST=1 swift test \
  --filter CodexBridgeTests/testRealAppServerReadIsOptIn
```

该测试只允许读取任务列表。测试和评审不得向真实任务发送消息，也不得写入正式收件箱。

## 改动要求

- 保持 Queue 由用户明确触发。
- 不记录想法正文、CLI 原始错误或认证信息。
- 不确定投递结果不得自动重试。
- 改动存储模型、兼容标识或投递协议时，需要迁移方案和回归测试。
- App Store 适配代码必须与本地 CLI 适配器分离，不能削弱现有失败关闭语义。
