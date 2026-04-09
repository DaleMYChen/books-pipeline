WITH raw AS (
    SELECT * FROM {{ source('raw', 'raw_categories') }}
),

deduped AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY CATEGORY_ID
            ORDER BY EXTRACTED_AT DESC
        ) AS row_num
    FROM raw
)

SELECT
    CATEGORY_ID,
    TRIM(CATEGORY_NAME)                 AS category_name,
    CAST(EXTRACTED_AT AS TIMESTAMP_NTZ) AS extracted_at
FROM deduped
WHERE row_num = 1