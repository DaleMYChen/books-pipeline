from __future__ import annotations  # backports that syntax to 3.8 for airflow container
import os
import io
import re
import time
import requests
import pandas as pd
import boto3
import snowflake.connector
from urllib.parse import urljoin
from bs4 import BeautifulSoup
from datetime import datetime
from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator

# ── Config ───────────────────────────────────────────────────────────────────
BASE_URL    = "http://books.toscrape.com"
# Bucket storing the tables:
BUCKET_NAME = os.environ.get("S3_BUCKET_NAME", "books-pipeline-data")
AWS_REGION  = os.environ.get("AWS_REGION", "ap-southeast-2")
# Warehouse & stage to load the tables:
SNOWFLAKE_DB = "BOOKS_WAREHOUSE"
STAGE        = f"{SNOWFLAKE_DB}.RAW.BOOKS_S3_STAGE"
 
# ── Shared clients ───────────────────────────────────────────────────────────
def get_s3_client():
    return boto3.client(
        "s3",
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=AWS_REGION,
    ) 

def get_snowflake_conn():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_DATABASE"],
    )

def upload_df_to_s3(df:pd.DataFrame, s3_key:str) -> None:
    buf = io.StringIO()
    df.to_csv(buf, index=False)
    get_s3_client().put_object(
        Bucket=BUCKET_NAME,
        Key=s3_key,
        Body=buf.getvalue().encode('utf-8'),
    )
    print(f"✓ Uploaded {len(df)} rows → s3://{BUCKET_NAME}/{s3_key}")


 
# ── Helper: discover all category URLs from the sidebar ─────────────────────
def _get_category_urls() -> list[tuple[int, str]]:
    """Returns list of (category_id, full_url) for every leaf category."""
    resp = requests.get(f"{BASE_URL}/index.html", timeout=10)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.content, "html.parser")
 
    nav = soup.find("ul", class_="nav-list")
    sub_nav = nav.find("ul")       # child <ul> holds the 50 subcategories
 
    results = []
    for li in sub_nav.find_all("li"):
        a = li.find("a")
        href = a["href"]           # e.g. "catalogue/category/books/travel_2/index.html"
        parts = href.split("/")    # [..., 'travel_2', 'index.html']
        slug = parts[-2]           # "travel_2"
        category_id = int(slug.split("_")[-1])
        full_url = urljoin(BASE_URL + "/", href)
        results.append((category_id, full_url))
 
    return results[:3]

# ── Task 1: Scrape Categories ────────────────────────────────────────────────
def scrape_categories() -> None:
    rows = []
    for category_id, full_url in _get_category_urls():
        resp = requests.get(full_url, timeout=10)
        resp.raise_for_status()
        # parse html content
        soup = BeautifulSoup(resp.content, 'html.parser')
        category_name = soup.find('div', class_='page-header').find('h1').text.strip()
        rows.append({
            'category_id': category_id,
            'category_name':category_name,
            "extracted_at": datetime.utcnow().isoformat(),
        })
        time.sleep(0.15)

    df = pd.DataFrame(rows)
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M")
    upload_df_to_s3(df, f"raw/categories/raw_categories_{ts}.csv")


# ── Task 2: Scrape Books ─────────────────────────────────────────────────────
def scrape_books() -> None:
    rows = []
    seen_titles = set()
    for category_id, cat_url in _get_category_urls():
        page_url = cat_url
        while page_url:
            r = requests.get(page_url, timeout=10)
            r.raise_for_status()
            soup = BeautifulSoup(r.content, 'html.parser')

            for article in soup.find_all('article', class_='product_pod'):
                title       = article.find("h3").find("a")["title"]
                price_raw   = article.find("p", class_="price_color").text.strip()
                rating_word = article.find("p", class_="star-rating")["class"][1]
                rel_href    = article.find("h3").find("a")["href"]
 
                # urljoin resolves the ../../ relative path correctly
                book_full_url = urljoin(page_url, rel_href)
                book_url = book_full_url.replace(BASE_URL + "/", "")
 
                if title not in seen_titles:
                    seen_titles.add(title)
                    rows.append({
                        "product_name": title,
                        "price":        price_raw,
                        "rating_word":  rating_word,
                        "category_id":  category_id,
                        "book_url":     book_url,
                        "extracted_at": datetime.utcnow().isoformat(),
                    })
 
            # Pagination: "next" button href is relative to current page dir
            next_btn = soup.find("li", class_="next")
            page_url = urljoin(page_url, next_btn.find("a")["href"]) if next_btn else None
            time.sleep(0.15)
 
    df = pd.DataFrame(rows)
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M")
    upload_df_to_s3(df, f"raw/books/raw_books_{ts}.csv")



# ── Task 3: Scrape Inventory (detail pages) ──────────────────────────────────
def scrape_inventory() -> None:
    # Re-discover book detail URLs independently (avoids XCom, keeps tasks decoupled)
    book_urls: set[str] = set()
 
    for _, cat_url in _get_category_urls():
        page_url = cat_url
        while page_url:
            r = requests.get(page_url, timeout=10)
            r.raise_for_status()
            soup = BeautifulSoup(r.content, "html.parser")
            for article in soup.find_all("article", class_="product_pod"):
                rel_href = article.find("h3").find("a")["href"]
                full = urljoin(page_url, rel_href)
                book_urls.add(full.replace(BASE_URL + "/", ""))
            next_btn = soup.find("li", class_="next")
            page_url = urljoin(page_url, next_btn.find("a")["href"]) if next_btn else None
            time.sleep(0.1)
 
    rows = []
    for book_url in book_urls:
        full_url = f"{BASE_URL}/{book_url}"
        try:
            r = requests.get(full_url, timeout=10)
            r.raise_for_status()
            soup = BeautifulSoup(r.content, "html.parser")
 
            # Product info table: UPC, num_reviews, etc.
            table = {
                row.find("th").text.strip(): row.find("td").text.strip()
                for row in soup.find("table", class_="table-striped").find_all("tr")
            }
 
            # "In stock (22 available)" → 22
            stock_text  = soup.find("p", class_="instock").text.strip()
            stock_match = re.search(r"\d+", stock_text)
            num_in_stock = int(stock_match.group()) if stock_match else 0
 
            rows.append({
                "book_url":     book_url,
                "upc":          table.get("UPC", ""),
                "num_in_stock": num_in_stock,
                "num_reviews":  int(table.get("Number of reviews", 0)),
                "extracted_at": datetime.utcnow().isoformat(),
            })
        except Exception as exc:
            print(f"⚠ Skipping {full_url}: {exc}")
 
        time.sleep(0.1)
 
    df = pd.DataFrame(rows)
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M")
    upload_df_to_s3(df, f"raw/inventory/raw_inventory_{ts}.csv")
 


# ── Tasks 4-6: Load S3 → Snowflake via COPY INTO ────────────────────────────
# DDL for each raw table — VARCHAR for everything scraped, cast happens in dbt
RAW_BOOKS_DDL = f"""
CREATE TABLE IF NOT EXISTS {SNOWFLAKE_DB}.RAW.RAW_BOOKS (
    PRODUCT_NAME VARCHAR,
    PRICE        VARCHAR,
    RATING_WORD  VARCHAR,
    CATEGORY_ID  INTEGER,
    BOOK_URL     VARCHAR,
    EXTRACTED_AT TIMESTAMP
)
"""
 
RAW_CATEGORIES_DDL = f"""
CREATE TABLE IF NOT EXISTS {SNOWFLAKE_DB}.RAW.RAW_CATEGORIES (
    CATEGORY_ID   INTEGER,
    CATEGORY_NAME VARCHAR,
    EXTRACTED_AT  TIMESTAMP
)
"""
 
RAW_INVENTORY_DDL = f"""
CREATE TABLE IF NOT EXISTS {SNOWFLAKE_DB}.RAW.RAW_INVENTORY (
    BOOK_URL     VARCHAR,
    UPC          VARCHAR,
    NUM_IN_STOCK INTEGER,
    NUM_REVIEWS  INTEGER,
    EXTRACTED_AT TIMESTAMP
)
"""
 
def _load_to_snowflake(table: str, s3_subpath:str, create_ddl:str)->None:
    # CREATE -> TRUNCATE -> COPY INTO
    conn = get_snowflake_conn()
    # Cursor: sends SQL through conn, receives results back
    cur = conn.cursor()
    try:
        cur.execute(create_ddl)
        print(f"✓ Table {table} ready")

        cur.execute(f"TRUNCATE TABLE {SNOWFLAKE_DB}.RAW.{table}")
        print(f"✓ Truncated {table}")

        # Load table from S3 to DB/RAW 
        # DB stage FILE-FORMAT inherited by COPY INTO:  will validate tables
        copy_sql = f"""
            COPY INTO {SNOWFLAKE_DB}.RAW.{table}
            FROM @{STAGE}/{s3_subpath}/
            PATTERN = '.*\\.csv'
        """
        cur.execute(copy_sql)
        result = cur.fetchall()
        print(f"✓ COPY INTO {table}: {result}")

    finally:
        cur.close()
        conn.close()

# Load tables from S3 to Snowflake
def load_books():
    _load_to_snowflake("RAW_BOOKS", "books", RAW_BOOKS_DDL)
 
def load_categories():
    _load_to_snowflake("RAW_CATEGORIES", "categories", RAW_CATEGORIES_DDL)
 
def load_inventory():
    _load_to_snowflake("RAW_INVENTORY", "inventory", RAW_INVENTORY_DDL)
 



# ── DAG Definition ───────────────────────────────────────────────────────────
default_args = {
    "owner":           "airflow",
    "depends_on_past": False,
    "start_date":      datetime(2024, 1, 1),
    "retries":         1,
}

with DAG('books_pipeline', 
         default_args=default_args,
         schedule_interval = '@daily',
         catchup = False,
         description = 'books.toscrape.com -> S3 -> Snowflake -> dbt',
         tags = ['books', 'scraping', 'snowflake'],
         ) as dag:
    
    # 1. Scrape
    t_scrape_categories = PythonOperator(
        task_id = 'scrape_categories',
        python_callable = scrape_categories,
    )
    t_scrape_books = PythonOperator(
        task_id = 'scrape_books',
        python_callable = scrape_books,
    )
    t_scrape_inventory = PythonOperator(
        task_id = 'scrape_inventory',
        python_callable = scrape_inventory,
    )

    # 2. Load
    t_load_categories = PythonOperator(
        task_id = 'load_categories_to_snowflake',
        python_callable = load_categories,
    )
    t_load_books = PythonOperator(
        task_id="load_books_to_snowflake",
        python_callable=load_books,
    )
    t_load_inventory = PythonOperator(
        task_id="load_inventory_to_snowflake",
        python_callable=load_inventory,
    )

    # 3. Transform (deps -> run -> test)
    t_dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command="cd /opt/airflow/dbt && dbt deps --profiles-dir .",
    )

    t_dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command="cd /opt/airflow/dbt && dbt run --profiles-dir .",
    )

    t_dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command="cd /opt/airflow/dbt && dbt test --profiles-dir .",
    )

    # ── Schedule ──────────────────────────────────────────────────────
    # Scrape tasks are independent → each feeds its own load task
    t_scrape_categories >> t_load_categories
    t_scrape_books      >> t_load_books
    t_scrape_inventory  >> t_load_inventory
 
    # All three loads must finish before dbt starts
    [t_load_categories, t_load_books, t_load_inventory] >> t_dbt_deps >> t_dbt_run >> t_dbt_test


