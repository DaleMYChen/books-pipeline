-- mart_price_bands: books bucketed by price range with in-band ranking.
-- SQL patterns demonstrated: CASE WHEN bucketing, RANK() window function,
-- aggregation on a derived column, MAX with filter to find top-ranked item.

WITH dim AS (
    SELECT * FROM {{ ref('dim_books') }}
),

-- Step 1: assign each book to a price band and rank it within that band
banded AS (
    SELECT
        book_title,
        price_gbp,
        rating_stars,
        category_name,
        stock_status,

        CASE
            WHEN price_gbp < 10 THEN 'A: Under £10'
            WHEN price_gbp < 20 THEN 'B: £10–£20'
            WHEN price_gbp < 30 THEN 'C: £20–£30'
            WHEN price_gbp < 40 THEN 'D: £30–£40'
            ELSE                     'E: £40 and above'
        END AS price_band,

        -- Rank by highest rating first; ties broken by lower price (better value)
        RANK() OVER (
            PARTITION BY
                CASE
                    WHEN price_gbp < 10 THEN 'A: Under £10'
                    WHEN price_gbp < 20 THEN 'B: £10–£20'
                    WHEN price_gbp < 30 THEN 'C: £20–£30'
                    WHEN price_gbp < 40 THEN 'D: £30–£40'
                    ELSE                     'E: £40 and above'
                END
            ORDER BY rating_stars DESC, price_gbp ASC
        ) AS rank_in_band

    FROM dim
)

-- Step 2: aggregate to one row per band; surface the top-ranked book
SELECT
    price_band,
    COUNT(*)                                                        AS total_books,
    ROUND(AVG(price_gbp), 2)                                       AS avg_price_gbp,
    ROUND(AVG(rating_stars), 2)                                    AS avg_rating_stars,

    -- Pick the title of the rank-1 book in each band
    MAX(CASE WHEN rank_in_band = 1 THEN book_title END)            AS top_rated_book,
    MAX(CASE WHEN rank_in_band = 1 THEN category_name END)         AS top_rated_book_category

FROM banded
GROUP BY price_band
ORDER BY price_band