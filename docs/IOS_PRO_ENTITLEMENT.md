# iOS → macOS Pro 解锁（给 iOS 工作流）

## 背景

Mac 版**不开内购**，也不接 Paddle。Pro 只在 iPhone 上订阅；
Mac 通过 iCloud 键值存储读到到期时间就自动解锁。这是 Agent HUD 的做法。

## Mac 侧（已完成）

`Sources/CodexIdeaDockCore/ProEntitlement.swift`

```swift
ProEntitlement.isPro()        // 到期时间 + 7 天宽限
ProEntitlement.expiry         // Date?
ProEntitlement.publish(expiry:)  // 写入 iCloud KV + 本地兜底
```

设置 → Pro 页会显示「已解锁 / 未订阅」和续订日期，并可手动刷新。

> **前提（发布版尚未满足）**：`NSUbiquitousKeyValueStore` 需要 iCloud entitlement 和带该
> entitlement 的 provisioning profile。当前 Developer ID 发布包两者都没有，所以 iOS 写入的
> 值到不了 Mac。要真正解锁，二选一：
> 1. 给 Mac 加 `com.apple.developer.ubiquity-kvstore-identifier` + iCloud profile 并重新签名公证；
> 2. 改走局域网：Mac 的 LAN server 已有配对码，加一个 `POST /v1/pro/expiry`，iOS 连上时推送到期时间。

## iOS 侧要做的（唯一改动点）

`Sources/RerouteMobileApp/RerouteMobileApp.swift` 里的 `SubscriptionManager.refresh()`。

现在的写法（约 174 行）：

```swift
var entitled = false
for await result in Transaction.currentEntitlements {
    guard case .verified(let transaction) = result,
          FlowCueProduct.all.contains(transaction.productID) else { continue }
    if transaction.revocationDate == nil,
       (transaction.expirationDate ?? .distantFuture) > .now {
        entitled = true
    }
}
isPro = entitled || isTestFlightBuild
```

改成（只加三处，其余不动）：

```swift
var entitled = false
var latestExpiry: Date?                       // ① 新增
for await result in Transaction.currentEntitlements {
    guard case .verified(let transaction) = result,
          FlowCueProduct.all.contains(transaction.productID) else { continue }
    if transaction.revocationDate == nil,
       (transaction.expirationDate ?? .distantFuture) > .now {
        entitled = true
        if let expiry = transaction.expirationDate {   // ② 记录到期时间
            latestExpiry = max(latestExpiry ?? expiry, expiry)
        }
    }
}
isPro = entitled || isTestFlightBuild
ProEntitlement.publish(expiry: entitled ? latestExpiry : nil)   // ③ 同步给 Mac
```

### 为什么放在 `refresh()`

`refresh()` 已经覆盖了所有状态变化：

| 调用来源 | 场景 |
|---|---|
| App 启动 | 冷启动对齐 |
| `purchase()` 成功 | 购买后立即生效 |
| `Transaction.updates` | 续订、退款、过期 |

不需要在别处再调。

### 一个刻意的决定

**TestFlight 构建会给 `isPro = true`，但不要 publish。**
测试者没有真实订阅，若把 `entitled` 一起写出去，Mac 会被永久解锁。

所以第 ③ 行用的是 `entitled ? latestExpiry : nil`，不是 `isPro ? ... : nil`。

## 验证

1. iOS 上用一个**没有订阅**的账号：设置 → Pro 显示未订阅
2. Mac 打开 设置 → Pro：应显示 `Not subscribed`
3. iOS 完成一次沙盒购买后，Mac 点「Refresh status」：应变成 `Unlocked` 并显示续订日期
4. 退款/过期后重跑：Mac 应回到 `Not subscribed`（宽限期 7 天内仍解锁）

Mac 侧的读取链路已用单测与手写 KV 验证过（`ProEntitlementTests`）。

## 约束

| 项 | 要求 |
|---|---|
| 只改 `Sources/RerouteMobileApp/` | `ProEntitlement` 在 Core，已完成，不要改 |
| 不新增依赖 | 用 `NSUbiquitousKeyValueStore`，系统自带 |
| 不做支付 UI 到 Mac | Mac 端不出现任何购买按钮或价格 |

## 为什么不用 CloudKit 记录

现有同步层是「想法」专用的记录类型，加一种记录要改 schema。
订阅状态只是一个日期，用 KV 存储足够，且天然跨设备、可离线读。

## 取舍（需要产品接受）

| 取舍 | 影响 |
|---|---|
| 只覆盖有 iPhone 的用户 | 纯 Mac 用户无法付费，未来若要覆盖需接 Paddle |
| 可被本地篡改 | KV 存的是日期，改 UserDefaults 就能伪造；小规模产品可接受 |
| 需要在 iOS 发布后才有值 | Mac 未解锁时只能用免费功能 |
