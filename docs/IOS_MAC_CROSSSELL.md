# iOS → macOS 交叉引导（给 iOS 工作流）

## 背景

macOS 版已经可以下载：Developer ID 签名 + 公证通过的 DMG（Universal）。
它在官网直接分发，**免费**，不上 App Store。

所以 iOS 里引导用户去下载 Mac 版**不涉及外部购买**，不触发 App Store 3.1.1。

## 要做两处入口

### ① 配对页空状态（主要入口）

当用户想连 Mac、但还没有配对设备时显示：

```
还没有配对的 Mac？

[ 二维码 ]
扫码在 Mac 上打开

在浏览器打开 Mac 下载页
```

- 二维码用 **CoreImage 的 `CIQRCodeGenerator`** 生成，不要引第三方库
- 二维码内容：`https://github.com/Jorgut/flowcue/releases/latest?from=ios-pairing`
- 注意：`flowcue.app` 目前是另一个 FlowCue（AI 提词器）产品，不是本 App 的站点；不要再用 `flowcue.app/mac`（`/mac` 只是 SPA fallback）
- 文案中英都要，走 `L10n`（iOS 侧现有约定）

### ② 设置页新增一行

位置：设置列表里，Remote 附近。

```
Mac 版                    GitHub Releases  ›
在 Mac 上安装，配对后可以继续编辑
```

点击打开 `https://github.com/Jorgut/flowcue/releases/latest?from=ios-settings`（用 `UIApplication.open`）。

## 约束

| 项 | 要求 |
|---|---|
| 只改 `Sources/RerouteMobileApp/` | 不要动 `Sources/CodexIdeaDockCore/`（macOS 线在维护） |
| 不加依赖 | 二维码用系统 CoreImage |
| 不出现价格 | Mac 版免费，页面只写“下载”，不写“购买” |
| URL 参数 | 保留 `?from=` 便于统计来源 |

## 验收

- 两种语言都检查
- 截图与设计稿并排比对（`docs/design/ios/` 里没有这一页，按现有配对页风格即可）
- 二维码能扫出正确 URL

## 现状

| 项 | 状态 |
|---|---|
| Mac DMG | ✅ 已公证，可下载（路径见 `docs/RELEASE_MACOS.md`） |
| 官网 `/mac` 页面 | ❌ 未做；`flowcue.app` 是另一个 FlowCue 产品。iOS 先指向 GitHub Release |
| iOS 入口 | ✅ 配对页 QR + Settings 行（GitHub Release） |
