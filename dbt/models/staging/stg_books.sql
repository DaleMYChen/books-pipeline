WITH raw AS (
    SELECT * FROM {{ source('raw', 'raw_books') }}
),

-- COPY INTO loads every CSV file in the S3 prefix.
-- If the DAG runs more than once, multiple files accumulate and produce duplicates.
-- We keep only the most recent scrape of each book, identified by book_url.
deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY BOOK_URL
            ORDER BY EXTRACTED_AT DESC
        ) AS row_num
    FROM raw
)

SELECT
    PRODUCT_NAME                                        AS book_title,

    -- Strip the £ symbol and cast to a proper decimal for arithmetic
    CAST(REPLACE(PRICE, '£', '') AS DECIMAL(10, 2))    AS price_gbp,

    -- Keep the word form for human-readable display
    RATING_WORD                                         AS rating_word,

    -- Map to integer so we can AVG/ORDER BY in the marts layer
    CASE RATING_WORD
        WHEN 'One'   THEN 1
        WHEN 'Two'   THEN 2
        WHEN 'Three' THEN 3
        WHEN 'Four'  THEN 4
        WHEN 'Five'  THEN 5
    END                                                 AS rating_stars,

    CATEGORY_ID,
    BOOK_URL,
    CAST(EXTRACTED_AT AS TIMESTAMP_NTZ)                 AS extracted_at

FROM deduped
WHERE row_num = 1