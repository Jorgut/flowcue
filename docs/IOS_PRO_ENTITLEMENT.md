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

## iOS 侧要做的（3 行）

在 `SubscriptionManager` 里，订阅状态变化时同步一次：

```swift
// 订阅有效时
ProEntitlement.publish(expiry: subscriptionExpiryDate)
// 无订阅 / 退款 / 过期
ProEntitlement.publish(expiry: nil)
```

调用时机：

| 时机 | 说明 |
|---|---|
| App 启动、拿到 `Transaction.currentEntitlements` 之后 | 冷启动也能对齐 |
| 购买成功 / 恢复购买之后 | 立即生效 |
| 收到 Transaction 更新（续订、退款、过期） | 保持同步 |

到期时间取 StoreKit 的 `expirationDate`；若是自动续订，StoreKit 已给下一期日期。

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
