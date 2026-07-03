--  PHASE 2 — CONTEXTUAL OPTIMISATION
--  1. TREND-CLAIM PRICING PREMIUM  
--  price_premium vs avg:
--  AVG(price) for this claim − AVG(AVG(price)) across ALL claims
--  Positive = this claim earns above the average claim price
--  Negative = this claim underperforms vs average
    
WITH exploded_claims AS (
    SELECT
        pm.product_id,
        TRIM(
            SUBSTRING_INDEX(
                SUBSTRING_INDEX(pm.claims, ',', nums.num),
                                           
                ',', -1
            )
        ) AS claim
    FROM product_metadata pm     
    JOIN (
        SELECT 1 AS num UNION SELECT 2 UNION SELECT 3
        UNION SELECT 4  UNION SELECT 5 UNION SELECT 6
    ) nums                             
    ON CHAR_LENGTH(pm.claims)
       - CHAR_LENGTH(REPLACE(pm.claims, ',', '')) >= nums.num - 1
),
price_ranked AS (
    
    SELECT
        product_id,
        order_id,
        price,
        line_revenue,
        PERCENT_RANK() OVER (ORDER BY price) AS pct_rank
    FROM clean_transactions
)
SELECT
    ec.claim,
    COUNT(DISTINCT t.order_id)               AS orders,
    ROUND(AVG(t.price), 2)                   AS avg_price,
    ROUND(MAX(CASE WHEN t.pct_rank <= 0.75
                   THEN t.price END), 2)     AS p75_price,
    ROUND(SUM(t.line_revenue), 2)            AS total_revenue,
    ROUND(
        AVG(t.price) - AVG(AVG(t.price)) OVER ()
    , 2)                                     AS price_premium_vs_avg
FROM exploded_claims       ec
JOIN price_ranked          t  ON ec.product_id = t.product_id
GROUP BY ec.claim
ORDER BY avg_price DESC;


-- 2. CATEGORY PRICING POWER RANKING
--  revenue_rank → which category generates the most total money?
--  price_rank   → which category commands the highest avg unit price?

SELECT
    pm.category,
    COUNT(DISTINCT t.order_id)                  AS orders,
    SUM(t.quantity)                             AS units_sold,
    ROUND(AVG(t.price), 2)                      AS avg_price,
    ROUND(MIN(t.price), 2)                      AS min_price,
    ROUND(MAX(t.price), 2)                      AS max_price,
    ROUND(SUM(t.line_revenue), 2)               AS total_revenue,
    RANK() OVER (ORDER BY SUM(t.line_revenue) DESC)  AS revenue_rank,
    RANK() OVER (ORDER BY AVG(t.price) DESC)         AS price_rank
 
FROM clean_transactions      t
JOIN product_metadata  pm ON t.product_id = pm.product_id
GROUP BY pm.category
ORDER BY revenue_rank;

-- 3. PACK-SIZE PRICE-PER-UNIT ANALYSIS
-- unit_price_delta vs category:
--    = pack's per-unit price − average per-unit price for the category
--    Positive → buyer pays MORE per unit in this pack format (premium bundling)
--    Negative → buyer pays LESS per unit (discount bundling, drives volume)
--
--  Strategic insight:
--    If 12-Pack has a negative delta → buyers expect bulk discount, priced right.
--    If 12-Pack has a positive delta → pricing is inconsistent, buyers may resist.

WITH per_unit AS (
    SELECT
        pm.category,
        pm.pack_size,
        t.price,
        t.line_revenue,
        t.quantity,
        t.price / CASE pm.pack_size
                      WHEN 'Single'  THEN 1
                      WHEN '4-Pack'  THEN 4
                      WHEN '12-Pack' THEN 12
                      ELSE 1         
                  END AS price_per_unit
    FROM clean_transactions     t
    JOIN product_metadata pm ON t.product_id = pm.product_id
)
SELECT
    category,
    pack_size,
    COUNT(*)                                    AS transactions,
    ROUND(AVG(price), 2)                        AS avg_listed_price,
    ROUND(AVG(price_per_unit), 2)               AS avg_price_per_unit,
    ROUND(SUM(line_revenue), 2)                 AS total_revenue,
    ROUND(
        AVG(price_per_unit)
        - AVG(AVG(price_per_unit)) OVER (PARTITION BY category)
    , 2)                                        AS unit_price_delta_vs_category
 
FROM per_unit
GROUP BY category, pack_size
ORDER BY category, avg_price_per_unit DESC;


-- 4. GEOGRAPHIC PRICING — STATE-LEVEL OPTIMAL RANGE
--  state_price_index:
--    110 means this state pays 10% above the national average.
--    90  means this state pays 10% below the national average.

WITH ranked AS (
    SELECT
        go.state,
        t.price,
        t.quantity,
        t.line_revenue,
        PERCENT_RANK() OVER (
            PARTITION BY go.state   
            ORDER BY t.price
        ) AS pct_rank
    FROM clean_transactions         t
    JOIN geography_occasion   go ON t.order_id = go.order_id
    WHERE go.state IS NOT NULL
)
SELECT
    state,
    COUNT(*)                                                         AS transactions,
    SUM(quantity)                                                    AS units_sold,
    ROUND(AVG(price), 2)                                             AS avg_price,
    ROUND(MAX(CASE WHEN pct_rank <= 0.25 THEN price END), 2)         AS p25_price,
    ROUND(MAX(CASE WHEN pct_rank <= 0.75 THEN price END), 2)         AS p75_price,
    ROUND(SUM(line_revenue), 2)                                      AS total_revenue,
    ROUND(
        AVG(price) / AVG(AVG(price)) OVER () * 100
    , 1)                                                             AS state_price_index,
    RANK() OVER (ORDER BY AVG(price) DESC)                           AS price_rank
FROM ranked
GROUP BY state
ORDER BY avg_price DESC
LIMIT 20;


-- 5. CITY-TIER DEMAND & REVENUE INTENSITY
--   Quantify how much more Tier-1 city buyers pay vs Tier-2 vs Tier-3.
SELECT
    go.city_tier,
    COUNT(*)                                     AS transactions,
    SUM(t.quantity)                              AS units_sold,
    ROUND(AVG(t.price), 2)                       AS avg_price,
    ROUND(SUM(t.line_revenue), 2)                AS total_revenue,
    ROUND(AVG(t.quantity), 2)                    AS avg_order_size,
    ROUND(SUM(t.line_revenue) / COUNT(*), 2)     AS revenue_per_order,
    ROUND(
        AVG(t.price) / AVG(AVG(t.price)) OVER () * 100
    , 1)                                         AS tier_price_index
FROM clean_transactions         t
JOIN geography_occasion   go ON t.order_id = go.order_id
WHERE go.city_tier IS NOT NULL
GROUP BY go.city_tier
ORDER BY avg_price DESC;


-- 6. OCCASION-BASED PRICING OPPORTUNITY
--   Find which consumption occasion (gym, festive, marathon-prep etc.)
--        drives buyers to pay more than their normal persona average.
--    Positive = this occasion drives above-normal spending for this persona.
--    Negative = this occasion is more price-sensitive than usual.

WITH ranked AS (
    SELECT
        go.occasion,
        ci.persona,
        t.price,
        t.quantity,
        t.line_revenue,
        PERCENT_RANK() OVER (
            PARTITION BY go.occasion, ci.persona  
            ORDER BY t.price
        ) AS pct_rank
    FROM clean_transactions         t
    JOIN geography_occasion   go ON t.order_id = go.order_id
    JOIN consumer_insights    ci ON t.user_id  = ci.user_id
    WHERE ci.persona != 'unknown'
      AND go.occasion IS NOT NULL
)
SELECT
    occasion,
    persona,
    COUNT(*)                                                         AS transactions,
    SUM(quantity)                                                    AS units,
    ROUND(AVG(price), 2)                                             AS avg_price,
    ROUND(MAX(CASE WHEN pct_rank <= 0.75 THEN price END), 2)         AS p75_price,       
    ROUND(SUM(line_revenue), 2)                                      AS total_revenue,
    ROUND(
        AVG(price)
        - AVG(AVG(price)) OVER (PARTITION BY persona) 
    , 2)                                                             AS occasion_premium
FROM ranked
GROUP BY occasion, persona
ORDER BY persona, avg_price DESC;



--  7. COMPETITOR BENCHMARK GAP ANALYSIS
--  Compare our average price to competitors over the last 90 days.
--    This is intentional — competitors are benchmarked globally here.
--  gap_pct > 10%  → we are PREMIUM vs market
--  gap_pct < -10% → we are UNDERPRICED (opportunity to raise)
--  within ±10%    → COMPETITIVE (roughly in line with market)

WITH our_pricing AS (
    SELECT
        pm.category,
        ROUND(AVG(t.price), 2) AS our_avg_price
    FROM clean_transactions     t
    JOIN product_metadata pm ON t.product_id = pm.product_id
    WHERE t.timestamp >= DATE_SUB(
        (SELECT MAX(timestamp) FROM clean_transactions),  
        INTERVAL 90 DAY                                  
    ) 
    GROUP BY pm.category
),
comp_benchmark AS (
    SELECT
        ROUND(AVG(price), 2) AS comp_avg,
        ROUND(MIN(price), 2) AS comp_min,
        ROUND(MAX(price), 2) AS comp_max
    FROM competitor_pricing
    WHERE timestamp >= DATE_SUB(
        (SELECT MAX(timestamp) FROM competitor_pricing),
        INTERVAL 90 DAY
    )
)
SELECT
    op.category,
    op.our_avg_price,
    cb.comp_avg                                  AS competitor_avg,
    cb.comp_max                                  AS competitor_ceiling,
    ROUND(op.our_avg_price - cb.comp_avg, 2)     AS price_gap,   
    ROUND(
        100.0 * (op.our_avg_price - cb.comp_avg) / NULLIF(cb.comp_avg, 0)
    , 1)                                         AS gap_pct,   
    CASE
        WHEN op.our_avg_price > cb.comp_avg * 1.10
            THEN 'PREMIUM  (>10% above market)'
        WHEN op.our_avg_price < cb.comp_avg * 0.90
            THEN 'UNDERPRICED (>10% below market)'
        ELSE    'COMPETITIVE (within +-10%)'
    END                                          AS market_position
FROM our_pricing   op
CROSS JOIN comp_benchmark cb 
ORDER BY gap_pct DESC;


-- 8. EXECUTIVE LAUNCH PRICE RECOMMENDATION 

WITH base AS (
    SELECT
        persona,
        category,
        ROUND(AVG(price), 2)                                         AS base_avg,  
        ROUND(MAX(CASE WHEN pct_rank <= 0.75 THEN price END), 2)     AS base_p75   
    FROM (
        SELECT
            ci.persona,
            pm.category,
            t.price,
            PERCENT_RANK() OVER (
                PARTITION BY ci.persona, pm.category  
                ORDER BY t.price
            ) AS pct_rank
        FROM clean_transactions      t
        JOIN product_metadata  pm ON t.product_id = pm.product_id
        JOIN consumer_insights ci ON t.user_id    = ci.user_id
        WHERE ci.persona != 'unknown'
    ) ranked_base
    GROUP BY persona, category
),
tier_idx AS (
    SELECT
        go.city_tier,
        ROUND(
            AVG(t.price) / AVG(AVG(t.price)) OVER ()  
        , 3) AS tier_multiplier
    FROM clean_transactions         t
    JOIN geography_occasion   go ON t.order_id = go.order_id
    WHERE go.city_tier IS NOT NULL
    GROUP BY go.city_tier
),
top_occasion AS (
    SELECT
        ci.persona,
        go.occasion,
        ROUND(
            AVG(t.price) / AVG(AVG(t.price)) OVER (PARTITION BY ci.persona)  
        , 3) AS occ_multiplier,
        ROW_NUMBER() OVER (
            PARTITION BY ci.persona       
            ORDER BY AVG(t.price) DESC    
        ) AS rn
    FROM clean_transactions         t
    JOIN geography_occasion   go ON t.order_id = go.order_id
    JOIN consumer_insights    ci ON t.user_id  = ci.user_id
    WHERE ci.persona != 'unknown'
      AND go.occasion IS NOT NULL
    GROUP BY ci.persona, go.occasion
)
SELECT
    b.persona,
    b.category,
    ti.city_tier,
    oc.occasion                                  AS best_occasion,
    b.base_avg                                   AS persona_base_price,           
    ROUND(b.base_avg * ti.tier_multiplier * oc.occ_multiplier, 2)   AS recommended_price,
    ROUND(b.base_p75 * ti.tier_multiplier * oc.occ_multiplier, 2)   AS premium_ceiling,
    CONCAT(
        '$', ROUND(b.base_avg * ti.tier_multiplier * oc.occ_multiplier, 2),
        ' - $',
        ROUND(b.base_p75 * ti.tier_multiplier * oc.occ_multiplier, 2)
    )                                            AS recommended_price_band
FROM base         b
CROSS JOIN tier_idx ti                
JOIN top_occasion   oc
    ON  oc.persona = b.persona
    AND oc.rn = 1                     
WHERE ti.city_tier IS NOT NULL
ORDER BY b.persona, b.category, ti.city_tier;


