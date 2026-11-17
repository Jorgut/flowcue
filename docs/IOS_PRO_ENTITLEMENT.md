# iOS → macOS Pro 解锁

## 背景

Mac 版**不开内购**，也不接 Paddle。Pro 只在 iPhone 上订阅。
Mac 需要知道「这个用户的订阅到什么时候」，才能解锁 Pro 功能。

最初的设计是走 iCloud 键值存储，但发布包是 Developer ID 签名、没有 iCloud
entitlement 和 provisioning profile，`NSUbiquitousKeyValueStore` 在 Mac 上不会同步；
而且 KV 默认按 bundle id 隔离，两个不同 App 共享还要额外的 profile 配合。
所以**实际通道改走局域网**：iPhone 连上 Mac 时把到期时间推过去。

## 数据流

```
StoreKit（iPhone）→ SubscriptionManager.refresh()
  → ProEntitlement.publish(expiry:)        # iPhone 本地缓存（KV + UserDefaults）
  → LANRemoteController.syncProToMac()     # POST /v1/pro/expiry（带配对码）
    → Mac LANRemoteServer
      → ProEntitlement.publish(expiry:)    # Mac 本地 UserDefaults
        → ProEntitlement.isPro()           # 设置 → Pro、AgentBrowser 发消息
```

Mac 端只认一个日期，不存在支付逻辑；退款或过期时 iPhone 会推 `nil` 把 Mac 重新锁上。

## Mac 侧

`Sources/CodexIdeaDockCore/LANRemoteServer.swift`

```swift
POST /v1/pro/expiry
Authorization: Bearer <6 位配对码>
{"expiry":"2026-12-18T00:00:00Z"}   // 或 {} / {"expiry":null} 表示未订阅
```

- 只接受 ISO8601；格式错误返回 400，未带配对码返回 401。
- 写入 `ProEntitlement.publish(expiry:)`，`isPro()` 读到期时间 + 7 天宽限。

## iOS 侧

`Sources/RerouteMobileApp/RerouteMobileApp.swift`

1. `SubscriptionManager.refresh()`：取 `Transaction.currentEntitlements` 里最晚的
   `expirationDate`，只上报**真实订阅**。TestFlight 的临时 Pro 不写出去，否则 Mac 会被
   永久解锁。
2. `LANRemoteController.syncProToMac(force:)`：仅在首次连接或值变化时发送，失败静默，
   下次轮询自动重试，不打扰用户。
3. 触发点：连接成功后 `force: true`；用户手动刷新后；Chat 页每 3 秒的审批轮询里
   （值没变就不发请求）。

## 验证

已验证：

- `POST /v1/pro/expiry` 带配对码返回 200，值写入 Mac 的 `FlowCue.proUntil`；
- 不带配对码返回 401；非法日期返回 400；`{}` 清空后 Mac 回到未订阅；
- `ProEntitlementTests` 覆盖到期时间、7 天宽限与清空。

尚未端到端验证：

- iPhone 真实沙盒购买 → Mac 解锁。需要一次沙盒购买才能触发非空到期时间；
  代码路径已接入，但没在真机上跑过整条链路。

## 约束

| 项 | 要求 |
|---|---|
| 不做支付 UI 到 Mac | Mac 端不出现任何购买按钮或价格 |
| 不新增依赖 | 只用系统框架 |
| 配对码即权限 | 同一 Wi-Fi 下知道 6 位码即可推送；与会话/审批同一信任模型 |

## 取舍

| 取舍 | 影响 |
|---|---|
| 需要 iPhone 至少连过一次 Mac | 纯 Mac 用户无法付费；未来若要覆盖需接 Paddle |
| Mac 状态是本地缓存 | 换机或重装后要等 iPhone 再连一次 |
| 可被本地篡改 | 改 UserDefaults 就能伪造；小规模产品可接受 |
| 依赖 iOS 先联网 | Mac 未解锁时只能用免费功能 |

## 为什么不用 CloudKit 记录

现有同步层是「想法」专用的记录类型，加一种记录要改 schema，而且 Mac 端同样需要
iCloud entitlement 才能读。订阅状态只是一个日期，局域网推送足够且零签名成本。
