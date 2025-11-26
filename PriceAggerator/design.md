# E‑commerce Aggregator — High Level Design

**Goal:** compare prices for the same product across marketplaces (initially Amazon and Flipkart) for up to **10M users**, with **~1M concurrent active users** at peak.

---

## 1) Textual architecture diagram (logical components)

```
Clients (Web / Mobile / API)
        |
        v
CDN (edge cache) -> API Gateway / WAF -> Authentication & Rate Limiter
        |
        v
Load Balancer -> Frontend Services (Stateless) -> Backend Services (Stateless)
                                    |                      |
                                    |                      v
                                    |                 Aggregation Service
                                    v                      |
                   Search Service (Elasticsearch) <---- Normalizer & Dedupe
                                    ^                      |
                                    |                      v
                              Cache (Redis)         Ingestion & ETL Layer
                                    ^                      |
                                    |                      v
                                 Message Bus (Kafka) <- Scrapers & Partner Connectors
                                    |
                                    v
                           Worker Fleet (Price updater, notifier)
                                    |
                                    v
                          Persistent storage:
                          - Relational DB (canonical product, users)
                          - NoSQL (user sessions, feature flags)
                          - Object store (S3 for raw dumps)
                          - Time-series DB / Price history (could be PostgreSQL timescaledb or Influx)

Operational:
- Observability (Prometheus + Grafana), Tracing (OpenTelemetry, Jaeger)
- CI/CD, Canary deployments, Autoscaling groups
- Secrets manager, IAM, KMS
```

---

## 2) Major components & responsibilities

### a) Ingestion & Connectors

* **Purpose:** gather product listings & prices from Amazon and Flipkart.
* **Types:** partner APIs (if available) + resilient scrapers for public pages.
* **Features:** adaptive crawling, dynamic throttling, proxy pool, CAPTCHA handling, request schedulers, per-platform rate limiting, change detection.
* **Output:** normalized listing messages pushed to Kafka with metadata (source, timestamp, ETag/hash).

### b) ETL / Normalizer & Dedupe

* **Purpose:** convert source-specific listing into canonical product representation.
* **Steps:** parse, extract attributes (title, brand, model, specs), canonicalization rules, fingerprinting (hashing), similarity match to existing canonical product, dedupe.
* **Techniques:** name normalization (tokenization + stopwords), attribute mapping, supervised ML model for fuzzy matching (product matching), manual rules, voting across attributes.
* **Output:** canonical product record + platform-specific listing reference.

### c) Aggregation & Price Comparator

* **Purpose:** compute live best-price, availability, shipping, offers, and price differences across platforms.
* **Behavior:** consume normalized events, update caches and ES, compute derived metrics (best price, time since last seen), emit alerts for price changes.

### d) Search & Discovery (Elasticsearch)

* **Purpose:** user-facing search, faceted navigation, autosuggest.
* **Indexing:** canonical product documents enriched with platform listings (nested), attributes, categories, popularity metrics.
* **Features:** multi-language analyzers, synonyms, n‑gram for typos, product boosting (popularity, recency), aggregations for faceted filters.

### e) API Layer & Frontend

* **Purpose:** serve search, product detail, comparison pages, user actions (watchlist, alerts).
* **Design:** stateless services behind API Gateway. Use GraphQL (optional) or REST.
* **Caching:** use CDN + edge caching, and Redis for frequently requested product pages and comparison results.

### f) Worker Fleet & Notifications

* **Purpose:** async jobs — price history recording, re-score matching, sending push/email/SMS alerts.
* **Queue:** Kafka or SQS; workers in autoscaled groups.

### g) Data Stores

* **Relational (Postgres):** canonical product table, platform_listing pointers, user accounts, watchlists, transactions for alerts.
* **Elasticsearch:** search index for product discovery.
* **Redis:** hot caches, rate-limiting counters, session cache.
* **Object Storage (S3):** raw HTML dumps, images, backups, bulk exports.
* **Time-series DB / specialized storage:** price history retention and analytics (or Postgres + partitioning / TimescaleDB).

### h) Observability & SRE

* metrics, logs, traces. Alert thresholds for ingestion missing data, spike in 5xx, queue backlog.

---

## 3) What to store (detailed schema-level concepts)

### Core entities (high level)

* **CanonicalProduct:** canonical id, title, canonical attributes (brand, model, category tree), normalized tokens, product images.
* **PlatformListing:** listing id, platform (amazon|flipkart), platform_sku, url, price, currency, availability, shipping_info, seller_id, timestamp, raw_hash.
* **Seller:** seller id, name, rating, platform.
* **PriceHistory:** platform_listing_id (or canonical+platform), price, offer_type, timestamp.
* **IngestionJob / SourceMetadata:** crawl run id, success/failure, latency, rate-limits.
* **User:** user profile, preferences, locale, notification channels.
* **Watchlist / PriceAlert:** user_id, canonical_product_id, target_price, last_notified_at, status.
* **Analytics events:** clicks, impressions, conversion (for ranking & popularity), stored in event pipeline (Kafka -> data warehouse).

### Additional/derived data

* **Normalized fingerprints:** stable keys for matching duplicates.
* **Popularity metrics:** views, clicks, sales-proxy signals.
* **Aggregated best-price cache:** best_price, best_platform, last_updated.

---

## 4) Scaling & capacity planning (brief)

* **Traffic:** 1M active users at peak. Suppose each active user issues 2 requests/minute -> 2M req/min ≈ 33k req/s.
* **API scaling:** autoscale frontends to handle 33k rps with horizontal scaling, use connection pools and connection reuse to datastore.
* **Search load:** shard ES index across many nodes; tune index for read-heavy workloads with replica count to match QPS.
* **Ingestion throughput:** tens of thousands of listings per minute depending on crawler parallelism. Use partitioned Kafka topics and multiple consumer groups.
* **Storage sizing:** price history can grow quickly (e.g., 1M SKUs * 1440 samples/day = 1.44B rows/day if sampling per minute — so choose reasonable sampling window or delta-based logging). Consider summarization & TTL.

---

## 5) Data freshness, consistency & tradeoffs

* **Freshness targets:** soft real-time for price updates (e.g., update within 1–5 minutes for popular SKUs). For long-tail SKUs, hourly/daily.
* **Consistency:** eventual consistency between canonical record and platform listings is acceptable. Use last-writer-wins with metadata to resolve races.
* **Deduplication errors:** false positives/negatives in matching are expected. Provide manual mapping UI for corrections and a human-in-the-loop reconciliation pipeline.

---

## 6) Security, legality & operational concerns

* **TOS & scraping legality:** scrapers must respect robots.txt and platform TOS. Prefer partner APIs where possible.
* **PII handling:** store only required PII, encrypt sensitive fields at rest (KMS) and in transit.
* **Abuse protections:** per-IP rate-limits for scraper, rotating proxies, CAPTCHAs.
* **Compliance:** store logs and data according to jurisdictional law (India in this case).

---

## 7) Roadmap & incremental build

1. MVP: ingest small catalog from both platforms, canonicalize with simple rules, build a minimal search index, implement product comparison page.
2. Add robust dedupe (ML model), price history, watchlist & alerting
3. Full-scale crawler with proxies & scheduling, monitoring, and SRE runbooks
4. Ranking improvements (personalization), A/B testing, partner integrations

---

If this looks good I will produce two separate technical documents next: the canonical DB schema (SQL) and the Elasticsearch index mapping + sample query as you asked.
