# books-pipeline

An end-to-end data engineering pipeline demonstrating the Modern Data Stack:
scraping [books.toscrape.com](http://books.toscrape.com), staging raw data in AWS S3,
loading into Snowflake, and transforming with dbt — orchestrated by Apache Airflow.

---

## Architecture

```
books.toscrape.com
        │
        │  BeautifulSoup scraper (3 parallel tasks)
        ▼
   AWS S3 — books-pipeline-data/
   ├── raw/books/
   ├── raw/categories/
   └── raw/inventory/
        │
        │  Snowflake COPY INTO (bulk load)
        ▼
 Snowflake — BOOKS_WAREHOUSE
   RAW schema      raw_books, raw_categories, raw_inventory
   STAGING schema  stg_books, stg_categories, stg_inventory   ← dbt views
   MARTS schema    dim_books, mart_category_summary,
                   mart_price_bands                           ← dbt tables
        ▲
   Apache Airflow (Docker) — daily schedule, full orchestration
```

### DAG task graph

```
scrape_categories ──► load_categories ──┐
scrape_books      ──► load_books      ──┼──► dbt_deps ──► dbt_run ──► dbt_test
scrape_inventory  ──► load_inventory  ──┘
```

Scrape tasks run in parallel. Each feeds its own load task independently.
All three loads must succeed before dbt begins.

---
## What dbt produces and potential analysis
 
The three raw CSVs land in Snowflake exactly as scraped — messy strings, no
types enforced, duplicates possible. dbt transforms them across two layers into
clean, query-ready analytical tables.
 
**Staging layer (views)** cleans each raw table independently. Price strings
like `£12.99` are stripped and cast to `DECIMAL`. Star ratings stored as English
words (`Three`) are mapped to integers (`3`). Duplicate rows from multiple scrape
runs are collapsed to the most recent record per book using `ROW_NUMBER()`. The
result is three typed, deduplicated views — one per source — that are safe to join.
 
**Marts layer (tables)** joins and aggregates the staging views into three
purpose-built analytical surfaces:
 
`dim_books` is the central dimension table — one row per book with all attributes
joined: title, price, rating, category name, stock count, and a derived
`stock_status` label (Available / Low Stock / Out of Stock). It is the foundation
for any ad-hoc book-level query and is where foreign key integrity is validated
(every `category_id` must resolve to a real category).
 
`mart_category_summary` aggregates to one row per category, exposing average
price, average rating, total stock, and counts of low-stock and out-of-stock
books per category. This table directly answers questions like: which genres
command the highest prices, which are highest rated, and where is inventory
running low.
 
`mart_price_bands` buckets all books into five price ranges and ranks books
within each band by rating. It surfaces the top-rated book per band, enabling
value-for-money comparisons across the catalogue.
 
**Analysis the tables would enable:**
- Correlation between price and rating — do expensive books actually rate higher?
- Category-level inventory health — which genres are running low on stock?
- Best-value identification — highest-rated books in the cheapest price band
- Cross-category pricing benchmarks — which genres are over or under-priced relative to their average rating?
 

---

## Design decisions

### ELT over ETL
Raw CSV files are uploaded to S3 before any transformation occurs. This preserves
an immutable audit trail: if transformation logic changes in dbt, historical data
can be re-transformed from the original files without re-scraping the website.

### Idempotency
Every load task follows TRUNCATE → COPY INTO. If Airflow retries a failed task,
the result is identical to a first run — no duplicate rows accumulate in the
warehouse. The raw S3 files are never deleted, satisfying both idempotency
and the audit trail requirement simultaneously.

### Deduplication in staging, not in loading
The raw tables are append-only and accumulate every scrape run. Deduplication
is handled in the staging layer using `ROW_NUMBER() OVER (PARTITION BY <key>
ORDER BY extracted_at DESC) = 1` — keeping the most recent scrape of each record.
This separation means the raw layer is always a complete historical record, while
the staging layer always presents a clean, current view.

### Snowflake COPY INTO over pandas df.to_sql()
The original local project used `df.to_sql()` to write to Postgres. For Snowflake,
the industrial pattern is a native `COPY INTO` from S3 — Snowflake reads the files
directly from object storage without the data passing through the Python process.
This is significantly faster at scale and removes the memory constraint of loading
a full dataset into a pandas DataFrame.

### Separation of orchestration and transformation
Airflow handles scheduling, retries, and task dependencies. dbt handles all SQL
transformation logic. Neither system does the other's job. This separation — the
core of the Modern Data Stack — means transformation logic can be tested, versioned,
and reviewed independently of pipeline scheduling.

### dbt schema layering
Each layer of the dbt project writes to a dedicated Snowflake schema:
- `RAW` — owned by Airflow; dbt never writes here
- `STAGING` — one view per source table; cleaning and typing only, no joins
- `MARTS` — dimensional and aggregated tables; business logic and joins live here

---

## dbt model graph

```
sources (RAW schema)
  raw_books ──────────────┐
  raw_categories ─────────┤
  raw_inventory ──────────┘
          │
          ▼ (staging — views, deduplication and type casting)
  stg_books ──────────────┐
  stg_categories ─────────┤
  stg_inventory ──────────┘
          │
          ▼ (marts — tables, joins and aggregations)
  dim_books                  (central join: books + categories + inventory)
  mart_category_summary      (GROUP BY category: avg price, avg rating, stock health)
  mart_price_bands           (CASE WHEN bucketing + RANK() window function)
```

### Tests implemented

| Layer | Test type | Purpose |
|---|---|---|
| Staging | `not_null` | Every column that feeds a join must be populated |
| Staging | `unique` | Primary keys are enforced before reaching marts |
| Staging | `accepted_values` | `rating_word` can only be One/Two/Three/Four/Five |
| Staging | `expression_is_true` | `price_gbp >= 0`, `num_in_stock >= 0` |
| Marts | `relationships` | Every `category_id` in `dim_books` exists in `stg_categories` |
| Marts | `accepted_values` | `stock_status` is always one of three expected values |

---

## Project structure

```
books-pipeline/
├── .github/
│   └── workflows/              
├── airflow/
│   ├── dags/
│   │   └── books_pipeline.py   
│   ├── Dockerfile
│   ├── docker-compose.yaml
│   └── requirements.txt
├── dbt/
│   ├── macros/
│   │   └── generate_schema_name.sql
│   ├── models/
│   │   ├── staging/
│   │   │   ├── sources.yml
│   │   │   ├── stg_books.sql + stg_books.yml
│   │   │   ├── stg_categories.sql + stg_categories.yml
│   │   │   └── stg_inventory.sql + stg_inventory.yml
│   │   └── marts/
│   │       ├── dim_books.sql + dim_books.yml
│   │       ├── mart_category_summary.sql + mart_category_summary.yml
│   │       └── mart_price_bands.sql + mart_price_bands.yml
│   ├── dbt_project.yml
│   ├── packages.yml
│   └── profiles.yml
├── snowflake_setup.sql         # One-time Snowflake bootstrap (placeholder credentials)
├── .env.example                # Credential template — copy to .env and fill in
├── .gitignore
└── README.md
```

---

## Local setup

### Prerequisites
- Docker Desktop
- AWS account — S3 bucket `books-pipeline-data` in `ap-southeast-2`
- Snowflake account — run `snowflake_setup.sql` to bootstrap the warehouse

### 1. Clone and configure

```bash
git clone <repo-url>
cd books-pipeline
cp .env.example airflow/.env
# Fill in all credential values in airflow/.env
```

### 2. Bootstrap Snowflake

Open `snowflake_setup.sql`, substitute the placeholder credential values from
your `.env`, and run each block in order in a Snowflake worksheet as ACCOUNTADMIN.

### 3. Start Airflow

```bash
cd airflow
mkdir -p logs plugins
docker compose up airflow-init
docker compose up -d
docker ps   # expecting: postgres, airflow-webserver, airflow-scheduler
```

Airflow UI: http://localhost:8081 (user: `airflow` / password: `airflow`)

### 4. Trigger the pipeline

Enable and manually trigger the `books_pipeline` DAG in the Airflow UI.

### 5. Verify results in Snowflake

```sql
SELECT * FROM BOOKS_WAREHOUSE.MARTS.DIM_BOOKS LIMIT 10;
SELECT * FROM BOOKS_WAREHOUSE.MARTS.MART_CATEGORY_SUMMARY ORDER BY avg_rating_stars DESC;
SELECT * FROM BOOKS_WAREHOUSE.MARTS.MART_PRICE_BANDS;
```



---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Snowflake MFA error on load tasks | Trial account enforces MFA for all users | Run Block 4 of `snowflake_setup.sql` |
| Stage not authorised | SYSADMIN lacks explicit stage privileges | Run stage GRANT lines in `snowflake_setup.sql` Block 5 |
| Unique test failures after retries | COPY INTO loads all CSVs in prefix | Already handled via `ROW_NUMBER()` deduplication in staging |
| dbt_utils macro not found | `dbt_packages/` not populated | Run `dbt deps --profiles-dir .` inside the container |
| Volume mount error on startup | `logs/` or `plugins/` missing | `mkdir -p airflow/logs airflow/plugins` |

---


## Misc.
### 1. CI/CD of Data Pipelines
The CI/CD workflows only operate on the dbt transformation layer — compiling SQL, building models into Snowflake, running schema tests. None of that touches S3. The scraping and S3 loading is handled entirely by Airflow running locally on its daily schedule, which GitHub Actions has no reason to trigger or verify.

