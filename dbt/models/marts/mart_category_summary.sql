-- mart_category_summary: one row per category with key business metrics.
-- SQL patterns demonstrated: GROUP BY, AVG, COUNT, MIN, MAX, conditional COUNT.

WITH dim AS (
    SELECT * FROM {{ ref('dim_books') }}
)

SELECT
    category_id,
    category_name,

    -- Volume
    COUNT(*)                                                    AS total_books,

    -- Pricing
    ROUND(AVG(price_gbp), 2)                                   AS avg_price_gbp,
    MIN(price_gbp)                                              AS min_price_gbp,
    MAX(price_gbp)                                              AS max_price_gbp,

    -- Quality
    ROUND(AVG(rating_stars), 2)                                AS avg_rating_stars,

    -- Inventory health
    SUM(num_in_stock)                                          AS total_stock,
    COUNT(CASE WHEN stock_status = 'Out of Stock' THEN 1 END)  AS out_of_stock_count,
    COUNT(CASE WHEN stock_status = 'Low Stock'    THEN 1 END)  AS low_stock_count

FROM dim
GROUP BY category_id, category_name
ORDER BY total_books DESC