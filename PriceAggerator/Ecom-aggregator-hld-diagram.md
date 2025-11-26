# High-Level Design (HLD) – User Flow & Backend Aggregator Flow

Below are the two separate architecture flows:

---

# User Flow (End‑User Journey)

```
User
 │
 ▼
1. Enters product keyword (e.g., "iPhone 15")
 │
 ▼
2. API Gateway → Search API
 │
 ▼
3. Redis Cache lookup
    ├─ Cache HIT → return result instantly
    └─ Cache MISS → Query Elasticsearch
 │
 ▼
4. Elasticsearch returns canonical product list + aggregated best prices
 │
 ▼
5. Backend merges ES results + real‑time adjustments (availability, pricing)
 │
 ▼
6. API sends final comparison list to user
 │
 ▼
7. User clicks a product → Product Detail API
 │
 ▼
8. Backend fetches:
    • Canonical Product (Postgres)
    • Platform listings (Postgres)
    • Best price cache (Redis)
 │
 ▼
9. Aggregated detail response returned to user
 │
 ▼
10. User optionally sets Price Alert
    → Stored in Postgres
    → Alert Worker monitors price changes (async)
```


## **User Flow Architecture (Frontend → API → Search/DB)**

```
+------------------+        +--------------------+        +-----------------------+        +------------------------+
|   Web / Mobile   | -----> |  API Gateway / LB  | -----> | Product Search API    | -----> |  Search Index (ES)     |
|     Clients      |        | (Rate Limit, Auth) |        | (Query Aggregation)   |        | (Price + Offer Cache)  |
+------------------+        +--------------------+        +-----------------------+        +------------------------+
                                                                     |                                     |
                                                                     |                                     v
                                                                     |                           +-------------------+
                                                                     |                           | Redis Cache      |
                                                                     |                           | (Fast lookups)   |
                                                                     |                           +-------------------+
                                                                     |
                                                                     v
                                                           +-----------------------+
                                                           | Product DB (Postgres) |
                                                           | Curation + Metadata   |
                                                           +-----------------------+
```

### **Flow Explanation**

* User searches for a product → request hits **API Gateway**.
* API forwards to **Product Search API**.
* API queries **Elasticsearch** for fast text search & price comparison.
* API pulls metadata from **Postgres**.
* API checks **Redis** for cached price snapshots.
* Response returns aggregated comparison: Amazon price, Flipkart price, ratings, delivery info.

---

# Backend Data Aggregator Flow (Amazon / Flipkart → Your System)

```
Downstream Sources (Amazon, Flipkart)
 │
 ▼
1. Scheduler / Cron / Kafka Trigger
   → initiates scraping or API polling
 │
 ▼
2. Scraper / Partner Connector
   • Calls Amazon/Flipkart API or scrapes HTML
   • Collects raw JSON/HTML
 │
 ▼
3. Push raw payload → Kafka Topic: `listings.raw`
 │
 ▼
4. Ingestion / ETL Worker
   • Parses raw payload
   • Extracts product metadata, price, availability
   • Computes raw_hash for change‑detection
   → Output → Kafka Topic: `listings.clean`
 │
 ▼
5. Normalization + ML Matching
   • Normalize titles (lowercase, remove noise)
   • Tokenize & vectorize
   • Run dedupe / similarity model
   • Identify canonical product
 │
 ▼
6. Postgres Writes
   • Upsert canonical product
   • Upsert platform listing
   • Append to price history table
 │
 ▼
7. Update Elasticsearch Index
   • Canonical product document updated
   • Nested: price listings for each platform
 │
 ▼
8. Update Redis Cache
   • Update hot keys: best-price:{productId}
 │
 ▼
9. Notify Alert Engine (Worker)
   • Check price triggers
   • Push notifications (Email/SMS/Push)
 │
 ▼
10. Analytics Events
   • Stream to Kafka → BigQuery/S3 for BI dashboards
```


## **2. Backend Data Aggregator Flow (Amazon/Flipkart → ETL → Indexing)**

```
+----------------------+       +-----------------------+       +----------------------------+       +-------------------------+
| Amazon / Flipkart   | ----> |   Crawlers / API      | ----> |  Aggregation + Normalizer  | ----> |  Kafka Topic (Prices)   |
| APIs / HTML Pages   |       | (Parallel Workers)    |       | (Unify fields, cleanse)    |       |  & (Product Updates)    |
+----------------------+       +-----------------------+       +----------------------------+       +-------------------------+
                                                                                                               |
                                                                                                               v
                                                                                                    +-----------------------+
                                                                                                    | Stream Consumers     |
                                                                                                    | (Price Updater Svc)  |
                                                                                                    +-----------------------+
                                                                                                               |
                                                  +--------------------------+                           |
                                                  | Batch ETL (Nightly)      | <------------------------+
                                                  | (Deep data refresh)      |
                                                  +--------------------------+
                                                                                                               |
                                                                                                               v
                                                                                                   +-------------------------+
                                                                                                   | Elasticsearch Index     |
                                                                                                   | (Update price fields)   |
                                                                                                   +-------------------------+
                                                                                                               |
                                                                                                               v
                                                                                                   +------------------------+
                                                                                                   | Postgres Product DB   |
                                                                                                   | (Insert/update meta)  |
                                                                                                   +------------------------+
```

### **Flow Explanation**

* Downstream systems → Amazon/Flipkart exposed APIs or crawled webpages.
* **Crawlers/Workers** fetch data at scale.
* **Aggregator/Normalizer** standardizes fields (title, price, rating, delivery estimate).
* Data pushed into **Kafka topics**.
* **Consumers** update ES and DB in near real-time.
* A **batch ETL** refreshes full catalogs every night.

