# Founding users worker

Backs the **1,999 founding seats** counter and reservation form on the landing page.
Static site stays on Cloudflare Pages; this Worker owns the write path.

This is a **reservation list**, not a payment flow yet. Checkout (Paddle) and
license issuance are added separately; until then no money changes hands.

## Endpoints

| Method | Path | Body | Result |
|---|---|---|---|
| GET | `/api/founding/status` | — | `{ok, claimed, remaining, limit, open}` |
| POST | `/api/founding/claim` | `{"email":"..."}` | `{ok, seat, price, tier, claimed, remaining, open}`; `duplicate: true` if the email already reserved |

Errors: `invalid_email` (400), `full` (409), `rate_limited` (429), `bad_json` (400).

## Storage

Cloudflare D1 `flowcue-founding` (APAC), database id `5e6ccac5-8222-4b7f-9815-48ada553d888`.

```sql
founding_users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,  -- seat number
  email TEXT UNIQUE COLLATE NOCASE,
  created_at TEXT,
  ip_hash TEXT                          -- truncated SHA-256, for rate limiting only
)
```

Seats are the row id, capped at 1999. Seats 1–999 are priced at $9.9, 1,000–1999 at $19.9 in the UI; this Worker stores reservations only. Test rows must be deleted with the
`sqlite_sequence` reset, otherwise the next real claimant gets a gap:

```bash
npx wrangler d1 execute flowcue-founding --remote --command \
  "DELETE FROM founding_users; DELETE FROM sqlite_sequence WHERE name='founding_users';"
```

## Deploy

```bash
cd workers/founding
npx wrangler d1 execute flowcue-founding --remote --file=schema.sql   # first time
npx wrangler deploy
```

The Pages build ignores this directory; the Worker is deployed separately.

## Export the list

```bash
npx wrangler d1 execute flowcue-founding --remote --command \
  "SELECT id, email, created_at FROM founding_users ORDER BY id" --json
```

## Boundaries

- No email is sent by the Worker. The list is exported before launch and
  checkout links / licenses are sent manually until Paddle + an email provider
  are wired in.
- No account, no password, no payment. One seat per normalized email.
- Rate limit: 3 claims per hashed IP per 10 minutes. This is a spam guard,
  not identity verification.
- `CF-Connecting-IP` is hashed with `FOUNDING_SALT` (set a secret before
  relying on it) and truncated to 12 bytes; the raw IP is never stored.
