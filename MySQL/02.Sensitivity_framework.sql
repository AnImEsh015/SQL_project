-- 1. Price Bucket Price Distribution in Dollars

SELECT
    CASE
        WHEN price < 10                    THEN 'A: Under 10'
        WHEN price BETWEEN 10  AND 19.99   THEN 'B: 10–20'
        WHEN price BETWEEN 20  AND 34.99   THEN 'C: 20–35'
        WHEN price BETWEEN 35  AND 59.99   THEN 'D: 35–60'
        WHEN price BETWEEN 60  AND 99.99   THEN 'E: 60–100'
        ELSE                                    'F: 100+'
    END                                        AS price_bucket,
    COUNT(*)                                   AS transaction_count,
    SUM(quantity)                              AS total_units_sold,
    ROUND(AVG(price), 2)                       AS avg_price,
    ROUND(SUM(line_revenue), 2)                AS total_revenue,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2
    )                                          AS pct_of_transactions
FROM clean_transactions
GROUP BY price_bucket
ORDER BY total_units_sold DESC;

-- 2. REVENUE vs. VOLUME TRADE-OFF BY BUCKET
--  Compare each bucket's share of REVENUE vs its share of VOLUME
--  rev_vol_gap = revenue_share% - volume_share%
--    Positive → bucket earns more revenue than its volume share suggests
--               (revenue-rich, high-margin zone → protect or raise price)
--    Negative → bucket sells a lot but earns little per sale
--               (volume-heavy, thin-margin zone → only chase if needed)

SELECT
    CASE
        WHEN price < 10                    THEN 'A: Under ₹10'
        WHEN price BETWEEN 10  AND 19.99   THEN 'B: ₹10–₹20'
        WHEN price BETWEEN 20  AND 34.99   THEN 'C: ₹20–₹35'
        WHEN price BETWEEN 35  AND 59.99   THEN 'D: ₹35–₹60'
        WHEN price BETWEEN 60  AND 99.99   THEN 'E: ₹60–₹100'
        ELSE                                    'F: ₹100+'
    END                                        AS price_bucket,
    SUM(quantity)                              AS total_units,
    ROUND(SUM(line_revenue), 2)                AS total_revenue,
    ROUND(AVG(line_revenue / quantity), 2)     AS avg_revenue_per_unit,
    ROUND(
        100.0 * SUM(line_revenue) / SUM(SUM(line_revenue)) OVER (), 2
    )                                          AS revenue_share_pct,
    ROUND(
        100.0 * SUM(quantity) / SUM(SUM(quantity)) OVER (), 2
    )                                          AS volume_share_pct,
    ROUND(
        ( 100.0 * SUM(line_revenue) / SUM(SUM(line_revenue)) OVER () ) -
        ( 100.0 * SUM(quantity)     / SUM(SUM(quantity))     OVER () ), 2
    )                                          AS rev_vol_gap
FROM clean_transactions
GROUP BY price_bucket
ORDER BY price_bucket;

-- 3. PRICE-THRESHOLD CLIFF DETECTION
-- Find the exact dollar values where demand drops 15%+ in one step

WITH price_band AS (
	SELECT 
		FLOOR(price) 		AS 'floor_price',
		SUM(quantity) 		AS 'units_sold'
	FROM clean_transactions
	WHERE price BETWEEN 1 AND 60
	GROUP BY FLOOR(price)
),
with_lag AS (
	SELECT 
		floor_price,
        units_sold,
        LAG(units_sold) OVER(ORDER BY floor_price) AS 'prev_units'
	FROM price_band
)
SELECT 
	floor_price		AS 'price_point',
    units_sold		AS 'units_this_dollar',
    prev_units		AS 'units_prev_dollar',
    ROUND(
		100.0 * (units_sold - prev_units) / NULLIF(prev_units, 0) ,1) AS 'demand_change_pct',
    CASE
        WHEN (units_sold - prev_units) / NULLIF(prev_units, 0) <= -0.15
        THEN 'CLIFF – demand drops >15%'
        ELSE 'Normal'
    END                                    AS cliff_flag
 
FROM with_lag
WHERE prev_units IS NOT NULL  
ORDER BY floor_price;
	
    
-- 4. PERSONA-LEVEL PRICE SENSITIVITY
-- STDDEV (standard deviation) tells you how consistent the persona is:
--    Low stddev → very price-consistent buyers (easy to target)
--    High stddev → wide range of prices accepted (flexible pricing ok)

--  Key metrics used as WTP (Willingness-To-Pay) proxies:
--    • avg_price_paid      → central tendency of what they pay
--    • median_price        → less affected by outliers than avg
--    • p75_price           → 75% of this persona pays BELOW this amount
--    • price_ceiling_p90   → 90% of this persona pays BELOW this amount

WITH BaseStats AS (
    SELECT 
        ci.persona,
        COUNT(*)                  AS transactions,
        ROUND(AVG(t.price), 2)    AS avg_price_paid,
        ROUND(MIN(t.price), 2)    AS floor_price,
        ROUND(MAX(t.price), 2)    AS ceiling_price,
        ROUND(STDDEV(t.price), 2) AS price_std_dev
    FROM clean_transactions t
    JOIN consumer_insights ci ON t.user_id = ci.user_id
    GROUP BY ci.persona
),
RankedPrices AS (
    SELECT 
        ci.persona,
        t.price,
        PERCENT_RANK() OVER (PARTITION BY ci.persona ORDER BY t.price) AS pct_rank
    FROM clean_transactions t
    JOIN consumer_insights ci ON t.user_id = ci.user_id
),
PersonaPercentiles AS (
    SELECT 
        persona,
        ROUND(MIN(CASE WHEN pct_rank >= 0.50 THEN price END), 2) AS median_price,
        ROUND(MIN(CASE WHEN pct_rank >= 0.75 THEN price END), 2) AS p75_price,
        ROUND(MIN(CASE WHEN pct_rank >= 0.90 THEN price END), 2) AS price_ceiling_p90
    FROM RankedPrices
    GROUP BY persona
)
SELECT 
    b.persona,
    b.transactions,
    b.avg_price_paid,
    b.floor_price,
    b.ceiling_price,
    b.price_std_dev,
    p.median_price,
    p.p75_price,
    p.price_ceiling_p90
FROM BaseStats b
JOIN PersonaPercentiles p ON b.persona = p.persona
ORDER BY b.avg_price_paid DESC; 

-- 5. CHANNEL-LEVEL PRICE TOLERANCE
--  The 5 channels in this dataset:
--    Marketplace → Amazon-style listing, very price-visible, buyers compare
--    App         → brand's own app, loyal users, possibly premium-tolerant
--    Retail      → physical store, impulse-driven, price-sensitive
--    Gym Kiosk   → captive audience (no alternatives nearby), premium ok
--    Website     → direct-to-consumer, middle ground
--
--  price_index_vs_avg:
--    AVG(price) / AVG(AVG(price)) OVER () × 100
--    The inner AVG(price) = this channel's average.
--    The outer AVG(AVG(price)) OVER () = average of all channel averages.
--    Result: 100 = exactly average | 115 = 15% above average | 85 = 15% below.
--
--  Strategic use:
--    Channels with index > 105 → launch premium SKUs there first.
--    Channels with index < 95  → use for entry-level / promotional pricing.

WITH BaseStats AS (
    SELECT 
        channel,
        COUNT(*)                      AS orders,
        SUM(quantity)                 AS units_sold,
        ROUND(AVG(price), 2)          AS avg_price,
        ROUND(SUM(line_revenue), 2)   AS total_revenue
    FROM clean_transactions
    GROUP BY channel
),
RankedPrices AS (
    SELECT 
        channel,
        price,
        PERCENT_RANK() OVER (PARTITION BY channel ORDER BY price) AS pct_rank
    FROM clean_transactions
),
ChannelPercentiles AS (
    SELECT 
        channel,
        ROUND(MIN(CASE WHEN pct_rank >= 0.50 THEN price END), 2) AS median_price,
        ROUND(MIN(CASE WHEN pct_rank >= 0.90 THEN price END), 2) AS p90_price
    FROM RankedPrices
    GROUP BY channel
)

SELECT 
    b.channel,
    b.orders,
    b.units_sold,
    b.avg_price,
    p.median_price,
    p.p90_price,
    b.total_revenue,
    
    ROUND(
        (b.avg_price / AVG(b.avg_price) OVER ()) * 100
    , 2) AS price_index_vs_avg

FROM BaseStats b
JOIN ChannelPercentiles p ON b.channel = p.channel
ORDER BY b.avg_price DESC;


-- 6. PRICE ELASTICITY PROXY
--  Measure how sensitive demand is to price changes in each $5 range.
--  |E| > 1 = ELASTIC   → demand reacts a lot, risky to raise price
--  |E| < 1 = INELASTIC → demand barely reacts, safe to raise price

WITH five_dollar_bands AS (
    SELECT
        FLOOR(price / 5) * 5   AS band_floor,
        SUM(quantity)          AS total_units
    FROM clean_transactions
    WHERE price BETWEEN 1 AND 60
    GROUP BY FLOOR(price / 5) * 5
),
with_lag AS (
    SELECT
        band_floor,
        total_units,
        LAG(total_units) OVER (ORDER BY band_floor) AS prev_units,
        LAG(band_floor)  OVER (ORDER BY band_floor) AS prev_band
    FROM five_dollar_bands
)
SELECT
    CONCAT('$', prev_band, '–$', band_floor)   AS price_range,
    prev_units                                 AS lower_band_units,
    total_units                                AS upper_band_units,
 
    ROUND(
        ( (total_units - prev_units) / ( (total_units + prev_units) / 2.0 ) )
        /
        ( (band_floor  - prev_band)  / ( (band_floor  + prev_band)  / 2.0 ) )
    , 3)                                       AS arc_elasticity,
 
    CASE
        WHEN ABS(
            ( (total_units - prev_units) / ( (total_units + prev_units) / 2.0 ) ) /
            ( (band_floor  - prev_band)  / ( (band_floor  + prev_band)  / 2.0 ) )
        ) > 1 THEN 'ELASTIC – price-sensitive, risky to raise'
        ELSE       'INELASTIC – price-tolerant, safe to raise'
    END                                        AS elasticity_verdict
 
FROM with_lag
WHERE prev_units IS NOT NULL
ORDER BY prev_band;


-- 7. INCOME-BRACKET × PERSONA SENSITIVITY OVERLAY

--  wtp_index (Willingness-To-Pay Index):
--    AVG(price) / AVG(AVG(price)) OVER () × 100
--    Works exactly like the price_index in Q-05 but computed here over
--    the entire table (not just within a channel).
--    100 = average buyer. 120 = pays 20% above average.
--
--  avg_basket_value = average of (price × quantity) per order for that cell.
--    This captures not just unit price tolerance but how much they
--    spend per visit overall — important for promotion design.

SELECT 
	t2.income_bracket,
    t2.persona,
    COUNT(*) 																AS 'transactions',
    ROUND(AVG(t1.price),2)													AS 'avg_price',
    ROUND(AVG(t1.quantity),2) 												AS 'avg_quantity_per_order',
    ROUND(AVG(t1.line_revenue), 2)       									AS 'avg_basket_value',
    ROUND(AVG(t1.price) / AVG(AVG(t1.price)) OVER () * 100,1)   			AS 'wtp_index'
    FROM clean_transactions t1
    JOIN consumer_insights t2
    ON t1.user_id = t2.user_id
    GROUP BY t2.income_bracket, t2.persona
    ORDER BY t2.income_bracket, avg_price DESC;
    
    
  

