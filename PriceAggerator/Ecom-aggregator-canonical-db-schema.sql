-- Canonical DB schema for E‑commerce Aggregator
-- Relational schema (Postgres syntax with sensible indexes)

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Canonical product table
CREATE TABLE canonical_product (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  canonical_sku TEXT UNIQUE,
  title TEXT NOT NULL,
  brand TEXT,
  model TEXT,
  category_path TEXT[], -- hierarchical category tree
  normalized_title TEXT, -- tokenized / normalized version
  fingerprint TEXT, -- dedupe fingerprint
  images TEXT[], -- list of canonical image URLs
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX ON canonical_product ((lower(title))); -- simple index for some lookups
CREATE INDEX ON canonical_product (fingerprint);

-- 2. Platform listing (source-specific)
CREATE TABLE platform_listing (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  canonical_product_id UUID REFERENCES canonical_product(id) ON DELETE SET NULL,
  platform TEXT NOT NULL, -- 'amazon' | 'flipkart'
  platform_sku TEXT,
  url TEXT,
  title TEXT,
  price NUMERIC(12,2),
  currency CHAR(3) DEFAULT 'INR',
  availability BOOLEAN,
  seller_id TEXT,
  rating NUMERIC(3,2),
  raw_hash TEXT, -- hash of raw HTML or JSON for change detection
  last_seen_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX ON platform_listing (platform, platform_sku);
CREATE INDEX ON platform_listing (canonical_product_id);
CREATE INDEX ON platform_listing (price);

-- 3. Price history (time-series style)
CREATE TABLE price_history (
  id BIGSERIAL PRIMARY KEY,
  platform_listing_id UUID REFERENCES platform_listing(id) ON DELETE CASCADE,
  canonical_product_id UUID REFERENCES canonical_product(id) ON DELETE CASCADE,
  price NUMERIC(12,2) NOT NULL,
  currency CHAR(3) DEFAULT 'INR',
  shipping_cost NUMERIC(12,2),
  offer_text TEXT,
  source_payload JSONB, -- raw pricing payload
  recorded_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX ON price_history (platform_listing_id, recorded_at DESC);
CREATE INDEX ON price_history (canonical_product_id, recorded_at DESC);

-- 4. Sellers
CREATE TABLE seller (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  platform TEXT NOT NULL,
  platform_seller_id TEXT,
  name TEXT,
  rating NUMERIC(3,2),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE UNIQUE INDEX ON seller (platform, platform_seller_id);

-- 5. Ingestion metadata
CREATE TABLE ingestion_job (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  platform TEXT,
  started_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  finished_at TIMESTAMP WITH TIME ZONE,
  status TEXT,
  stats JSONB,
  error TEXT
);

-- 6. Users
CREATE TABLE app_user (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  email TEXT UNIQUE,
  phone TEXT,
  hashed_password TEXT,
  locale TEXT DEFAULT 'en-IN',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 7. Watchlist & Alerts
CREATE TABLE price_watch (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES app_user(id) ON DELETE CASCADE,
  canonical_product_id UUID REFERENCES canonical_product(id) ON DELETE CASCADE,
  target_price NUMERIC(12,2),
  comparison_operator TEXT DEFAULT '<=', -- or '<','=' etc
  last_notified_at TIMESTAMP WITH TIME ZONE,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX ON price_watch (user_id);
CREATE INDEX ON price_watch (canonical_product_id);

-- 8. Events (lightweight event log for analytics ingestion)
CREATE TABLE app_event (
  id BIGSERIAL PRIMARY KEY,
  event_type TEXT,
  user_id UUID,
  canonical_product_id UUID,
  properties JSONB,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);
CREATE INDEX ON app_event (event_type);
CREATE INDEX ON app_event (created_at DESC);

-- Example: materialized view for best price per canonical product
CREATE MATERIALIZED VIEW best_price AS
SELECT
  cp.id AS canonical_product_id,
  pl.platform,
  pl.id AS platform_listing_id,
  pl.price,
  pl.currency,
  pl.url,
  pl.last_seen_at
FROM canonical_product cp
JOIN platform_listing pl ON pl.canonical_product_id = cp.id
WHERE pl.price IS NOT NULL
ORDER BY cp.id, pl.price ASC;

-- Notes:
--  - Price history can be moved to a timeseries DB or partitioned table for large scale.
--  - Use partitioning on price_history(recorded_at) by month or by canonical_product_id to manage huge volumes.
--  - Introduce background jobs to refresh materialized view periodically.

-- Small helper: upsert for platform listing (psuedocode shown in real application code)
-- INSERT ... ON CONFLICT (platform, platform_sku) DO UPDATE ...

-- Add basic constraints and foreign keys tuned for deletion behavior above.
