# Founding Mac Pro worker

Backs the **1,999 founding seats** offer on the landing page:

- 1–999: $9.9 one-time
- 1,000–1,999: $19.9 one-time
- after 1,999: $29 (the Worker stops selling)

Paddle is the merchant of record. The site opens Paddle Checkout with a
client-side token; this Worker verifies the webhook, stores the order, signs an
offline Mac license, and emails it.

The buy section is hidden until every required secret is set, so deploying
this Worker without Paddle credentials is safe.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/founding/config` | client token, environment, price IDs, success URL |
| GET | `/api/founding/status` | sold count, remaining seats, next tier price |
| POST | `/api/paddle/webhook` | Paddle `transaction.completed` → order + license + email |

## Secrets

Set with `npx wrangler secret put <NAME>`:

| Name | Where |
|---|---|
| `PADDLE_CLIENT_TOKEN` | Paddle → Developer tools → Client-side tokens |
| `PADDLE_API_KEY` | Paddle → Developer tools → API keys (sandbox first) |
| `PADDLE_WEBHOOK_SECRET` | Paddle → Notifications → destination secret |
| `PADDLE_PRICE_USD_9` | Price ID for $9.90 |
| `PADDLE_PRICE_USD_19` | Price ID for $19.90 |
| `PADDLE_PRICE_CNY_69` | Price ID for ¥69 |
| `PADDLE_PRICE_CNY_139` | Price ID for ¥139 |
| `PADDLE_ENVIRONMENT` | `sandbox` (default) or `production` |
| `LICENSE_PRIVATE_KEY` | Ed25519 PKCS8 base64 (already set) |
| `RESEND_API_KEY` | Resend API key |
| `RESEND_FROM` | verified sender, e.g. `FlowCue <hello@altn.vision>` |
| `SITE_ORIGIN` | optional, defaults to `https://flowcue.altn.vision` |

`configured` is true only when the Paddle token, webhook secret, API key, all
four price IDs, `LICENSE_PRIVATE_KEY`, `RESEND_API_KEY` and `RESEND_FROM` are
present.

## Paddle setup (sandbox)

1. Create a one-time product **FlowCue Mac Pro**.
2. Add four prices: USD 9.90, USD 19.90, CNY 69, CNY 139.
3. Create a client-side token; copy it.
4. Create a notification destination for `transaction.completed`:
   `https://flowcue-founding.honaler.workers.dev/api/paddle/webhook`
   Copy its secret.
5. Enable Alipay (requires Paddle approval) and WeChat Pay under
   Checkout → Checkout configuration. Both are only shown to customers in
   China; WeChat Pay is desktop-only.
6. Set the secrets above and deploy.

## Storage

D1 `flowcue-founding` (APAC), database id `5e6ccac5-8222-4b7f-9815-48ada553d888`.

- `orders`: one row per paid Paddle transaction, unique seat, raw webhook JSON.
- `licenses`: signed license token per order, seat/tier/email.
- `founding_users`: legacy reservation table; no longer written. Keep for
  history or drop after a manual export.

## License format

`FC1-<base64url(JSON payload)>.<base64url(Ed25519 signature)>`

The Mac app verifies it with the raw public key in
`Sources/CodexIdeaDockCore/License.swift`. Never rotate the signing key without
a license migration; old licenses would stop verifying.

## Test locally

```bash
npm test          # signature + license unit tests
npx wrangler dev  # local Worker with a local D1
```

The webhook needs a `Paddle-Signature` header (`ts=...;h1=HMAC-SHA256(secret, ts + ":" + rawBody)`).
