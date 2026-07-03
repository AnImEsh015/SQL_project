-- DATA CLEANING 


-- Product Metadata
-- 1. Updating Proten Shake --> Protein Shake AND Protein bar --> Protein Bar
UPDATE product_metadata
SET category = CASE
	WHEN category = 'Proten Shake' THEN 'Protein Shake'
    WHEN category = 'Protein bar' THEN 'Protein Bar'
    ELSE category
END;

-- 2. Deleting all the rows which has ' ' values in category column
DELETE FROM product_metadata 
WHERE category = '';


-- Geography occasion 
-- 1. Updating NY --> New York and Calfornia --> California
UPDATE geography_occasion
SET state = CASE
	WHEN state = 'NY' THEN 'New York'
    WHEN state = 'Calfornia' THEN 'California'
    ELSE state
END;

-- 2.DELETED ROWS WHICH HAS UNKNOWN VALUE IN CITY_TIER COLUMN
DELETE FROM geography_occasion
WHERE city_tier = 'unknown';


-- Competitor Pricing
-- 1. Deleted all the rows containing ' ' values in price column
DELETE FROM competitor_pricing
WHERE price = '';


-- Competitor Insights
-- 1. Deleted all the rows containing ' ' values in price column
DELETE FROM consumer_insights
WHERE persona = '';


-- Transactions
-- 1. Removing all the products from each product group which doesn't lie within it's group interquartile range
CREATE OR REPLACE VIEW clean_transactions AS
WITH price_stats AS (
    SELECT
        product_id,
        MAX(CASE WHEN pct_rank <= 0.25 THEN price END) AS q1,
        MAX(CASE WHEN pct_rank <= 0.75 THEN price END) AS q3
    FROM (
        SELECT
            product_id,
            price,
            PERCENT_RANK() OVER (PARTITION BY product_id ORDER BY price) AS pct_rank
        FROM transactions
        WHERE price > 0
    ) ranked
    GROUP BY product_id
)
SELECT
    t.order_id,
    t.user_id,
    t.product_id,
    t.price,
    t.quantity,
    t.price * t.quantity                         AS line_revenue,
    t.timestamp,
    YEAR(t.timestamp)                            AS sale_year,
    MONTH(t.timestamp)                           AS sale_month,
    t.channel
FROM transactions  t
JOIN price_stats       ps ON t.product_id = ps.product_id
WHERE
    t.price    > 0
    AND t.quantity > 0
    AND t.price BETWEEN (ps.q1 - 1.5 * (ps.q3 - ps.q1))
                    AND (ps.q3 + 1.5 * (ps.q3 - ps.q1));
                    
