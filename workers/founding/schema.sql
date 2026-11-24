CREATE TABLE IF NOT EXISTS founding_users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT NOT NULL UNIQUE COLLATE NOCASE,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  ip_hash TEXT
);
CREATE INDEX IF NOT EXISTS idx_founding_created ON founding_users(created_at);

CREATE TABLE IF NOT EXISTS orders (
  id TEXT PRIMARY KEY,
  email TEXT,
  customer_id TEXT,
  price_id TEXT,
  currency TEXT,
  amount INTEGER,
  seat INTEGER NOT NULL,
  tier INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  raw TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_seat ON orders(seat);
CREATE INDEX IF NOT EXISTS idx_orders_email ON orders(email);

CREATE TABLE IF NOT EXISTS licenses (
  id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  email TEXT,
  seat INTEGER NOT NULL,
  tier INTEGER NOT NULL,
  token TEXT NOT NULL,
  issued_at TEXT NOT NULL,
  revoked_at TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_licenses_order ON licenses(order_id);
