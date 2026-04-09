WITH raw AS (
    SELECT * FROM {{ source('raw', 'raw_inventory') }}
),

deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY BOOK_URL
            ORDER BY EXTRACTED_AT DESC
        ) AS row_num
    FROM raw
)

SELECT
    BOOK_URL,
    UPPER(UPC)                          AS upc,
    NUM_IN_STOCK,
    NUM_REVIEWS,
    CAST(EXTRACTED_AT AS TIMESTAMP_NTZ) AS extracted_at
FROM deduped
WHERE row_num = 1