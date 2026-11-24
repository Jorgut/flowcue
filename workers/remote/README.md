# FlowCue Remote 中继

已部署：**https://flowcue-remote.honaler.workers.dev**

## 它做什么

1. 登记 Mac，签发 `macToken`
2. 配对：手机提交公钥 → Mac 批准 → 签发 `pairToken`
3. WebSocket 转发：按信封里的 `pair` 字段送到对端

中继只读 `pair` / `seq` / `nonce` / 长度，**不解析 ciphertext**，也拿不到共享密钥。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/remote/mac/register?mac=<id>` | 登记 Mac → `{macToken}` |
| POST | `/v1/remote/pair/create?mac=<id>` | 手机提交公钥 → `{pairID, pairToken}` |
| POST | `/v1/remote/pair/approve?mac=<id>` | Mac 批准 |
| POST | `/v1/remote/pair/revoke?mac=<id>` | 撤销 |
| GET | `/v1/remote/pair/status?mac=<id>&pair=<id>` | `pending` / `approved` |
| GET | `/v1/remote/ws?role=mac&mac=<id>&token=<macToken>` | Mac WebSocket |
| GET | `/v1/remote/ws?role=ios&mac=<id>&pair=<id>&token=<pairToken>` | iPhone WebSocket |

## 部署

```bash
cd workers/remote
npx wrangler deploy
```

## 已验证（2026-11-24）

真实 WebSocket 往返：

```
① 登记 Mac           拿到 token
② Mac WS 已连
③ 创建配对           ok
④ Mac 收到配对请求    是
⑤ iPhone WS 已连
⑥ 手机→Mac 转发      成功
⑦ Mac→手机 转发      成功
⑧ 撤销后拒绝连接      是
```

## 免费额度

Workers 10 万请求/天、Durable Objects（SQLite）10 万请求/天、D1 免费层。
MVP 量级远低于上限；只有多个用户高频轮询才需要升级到 Paid。
