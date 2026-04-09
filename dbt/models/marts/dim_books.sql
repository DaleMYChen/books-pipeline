-- dim_books: the central dimensional table.
-- Joins books → categories → inventory into one query-ready surface.
-- The `relationships` test in dim_books.yml validates FK integrity.

WITH books AS (
    SELECT * FROM {{ ref('stg_books') }}
),
categories AS (
    SELECT * FROM {{ ref('stg_categories') }}
),
inventory AS (
    SELECT * FROM {{ ref('stg_inventory') }}
)

SELECT
    b.book_title,
    b.price_gbp,
    b.rating_stars,
    b.rating_word,

    -- Category dimension
    b.category_id,
    c.category_name,

    -- Inventory dimension
    i.upc,
    i.num_in_stock,
    i.num_reviews,

    -- Derived stock label — business logic lives in marts, not raw
    CASE
        WHEN i.num_in_stock = 0 THEN 'Out of Stock'
        WHEN i.num_in_stock < 5 THEN 'Low Stock'
        ELSE 'Available'
    END AS stock_status,

    b.extracted_at

FROM books b
LEFT JOIN categories c ON b.category_id = c.category_id
LEFT JOIN inventory  i ON b.book_url    = i.book_url