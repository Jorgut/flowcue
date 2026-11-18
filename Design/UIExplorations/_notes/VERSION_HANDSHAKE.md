# 两端版本握手

## 为什么需要

iOS 走 App Store，更新比 Mac（下载 DMG）快。真实风险是：

> **iPhone 更新了，Mac 还是旧的** —— 而 Mac 是服务端。

所以规则是：**协议版本只升不降，Mac 至少兼容上一个版本**。

## 三个会受影响的接口

| 面 | 机制 | 版本差的表现 |
|---|---|---|
| 局域网配对 | `GET /v1/ping` 返回 `protocol` 与 `appVersion` | 现在可检测；旧客户端会忽略新字段 |
| iCloud 同步 | 日志 `version = 1`，不匹配抛 `unsupportedJournal` | 同步失败（错误还需在界面显示） |
| Pro 解锁 | iCloud KV 只存到期日期 | 不受影响 |

## Mac 侧（已完成）

`/v1/ping` 返回：

```json
{ "name": "FlowCue", "version": "1", "protocol": "1", "appVersion": "0.1.0" }
```

- `version`：旧字段，保留给老客户端
- `protocol`：协议号，客户端据此判断兼容性
- `appVersion`：Mac 的版本号，客户端可直接展示

设置 → 远程 会显示最近连接的 iPhone 版本（读请求头 `X-FlowCue-Version`）。

## iOS 侧要做的

### 1. 每次请求带上版本头

```swift
request.setValue(appVersion, forHTTPHeaderField: "X-FlowCue-Version")
```

`appVersion` 取 `CFBundleShortVersionString`。Mac 会记下来并显示在设置里。

### 2. 连接后先 ping

```swift
GET /v1/ping            // 不需要 Authorization
→ { protocol: "1", appVersion: "0.1.0" }
```

把返回的 `protocol` 转成 `Int` 与自己支持的版本比较：

| 情况 | 处理 |
|---|---|
| 相等 | 正常连接 |
| Mac 的 protocol 更低 | 提示「请更新 Mac 版 FlowCue」并给下载地址 |
| Mac 的 protocol 更高 | 提示「请更新 iPhone 版」 |

**注意**：Mac 的 `protocol` 更高属于异常（Mac 更新更慢），如果真的出现，说明 iOS 装的是旧版。

### 3. 显示两端版本

在配对成功页/设置里显示：

```
iPhone 1.1.0 (46)  ↔  Mac 0.1.0 · 协议 1
```

这样对方报问题时，一眼能看出是不是版本不一致。

## 升协议的约定

只有当**旧客户端会把新数据解读错**时才 +1，并在 `LANRemoteServer.protocolVersion` 改。

改了之后：

1. Mac 继续支持上一版协议（至少一个版本）
2. iOS 端把支持的最低协议号写死，低于就拒绝并提示更新
3. 在 `CHANGELOG` 与 release note 里写明

## 现状

| 项 | 状态 |
|---|---|
| Mac ping 返回 protocol / appVersion | ✅ |
| Mac 记录并显示 iPhone 版本 | ✅（等 iOS 带版本头） |
| iOS 带版本头 | ⬜ |
| iOS 连接前 ping 并比对 | ⬜ |
| 同步失败在界面提示 | ⬜ |
