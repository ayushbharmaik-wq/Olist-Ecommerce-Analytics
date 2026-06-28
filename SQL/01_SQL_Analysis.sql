-- ============================================================
--  OLIST E-COMMERCE  |  SQL SERVER
--  Phase 1 — CSV Import + Analysis Queries
-- ============================================================

USE OlistEcommerce;
GO

-- ============================================================
-- PART A: HOW TO IMPORT CSVs INTO SSMS
-- ============================================================
/*
IMPORT ORDER (follow this exact sequence due to foreign keys):

  1. product_category_name_translation
  2. olist_customers
  3. olist_geolocation
  4. olist_sellers
  5. olist_products
  6. olist_orders
  7. olist_order_items
  8. olist_order_payments
  9. olist_order_reviews

STEPS IN SSMS:
  1. Right-click your database → Tasks → Import Flat File
  2. Browse to the CSV file
  3. Set table name to match exactly (e.g. olist_customers)
  4. Preview columns & confirm data types match the schema
  5. Click Finish

  ⚠️  TIP: If Import Flat File gives errors, use:
       Tasks → Import Data → Flat File Source
       This gives more control over delimiters & data types.

  ⚠️  For olist_order_reviews: set review_comment_message 
       to nvarchar(MAX) to avoid truncation errors.
*/

-- ============================================================
-- PART B: ROW COUNT CHECK (run after import)
-- ============================================================
SELECT 'olist_customers'                   AS table_name, COUNT(*) AS row_count FROM olist_customers
UNION ALL
SELECT 'olist_geolocation',                               COUNT(*) FROM olist_geolocation
UNION ALL
SELECT 'olist_sellers',                                   COUNT(*) FROM olist_sellers
UNION ALL
SELECT 'olist_products',                                  COUNT(*) FROM olist_products
UNION ALL
SELECT 'product_category_name_translation',               COUNT(*) FROM product_category_name_translation
UNION ALL
SELECT 'olist_orders',                                    COUNT(*) FROM olist_orders
UNION ALL
SELECT 'olist_order_items',                               COUNT(*) FROM olist_order_items
UNION ALL
SELECT 'olist_order_payments',                            COUNT(*) FROM olist_order_payments
UNION ALL
SELECT 'olist_order_reviews',                             COUNT(*) FROM olist_order_reviews;


-- ============================================================
-- PART C: ANALYSIS QUERIES
-- ============================================================

-- ── Q1: Overall Business KPIs ──────────────────────────────

WITH delivered_orders AS (
    SELECT
        o.order_id,
        o.customer_id,
        SUM(i.price + i.freight_value) AS order_value,
        COUNT(*) AS items_in_order
    FROM olist_orders o
    JOIN olist_order_items i
        ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY
        o.order_id,
        o.customer_id
),

review_summary AS (
    SELECT
        order_id,
        AVG(CAST(review_score AS FLOAT)) AS avg_review_score
    FROM olist_order_reviews
    GROUP BY order_id
),

seller_summary AS (
    SELECT
        COUNT(DISTINCT seller_id) AS total_sellers
    FROM olist_order_items
),

product_summary AS (
    SELECT COUNT(DISTINCT i.product_id) AS total_products
    FROM olist_order_items i
    JOIN olist_orders o 
        ON i.order_id = o.order_id
    WHERE o.order_status = 'delivered'
)

SELECT
    COUNT(DISTINCT d.order_id) AS total_orders,
    COUNT(DISTINCT d.customer_id) AS total_customers,
    MAX(s.total_sellers) AS total_sellers,
    MAX(p.total_products) AS total_products,
    SUM(d.items_in_order) AS total_items_sold,
    ROUND(SUM(d.order_value), 2) AS total_revenue,
    ROUND(AVG(d.order_value), 2) AS avg_order_value,
    ROUND(AVG(r.avg_review_score), 2) AS avg_review_score
FROM delivered_orders d
LEFT JOIN review_summary r
    ON d.order_id = r.order_id
CROSS JOIN seller_summary s
CROSS JOIN product_summary p;

-- ── Q2: Order Status Breakdown ─────────────────────────────
SELECT
    order_status,
    COUNT(*)                                            AS total_orders,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2)  AS percentage
FROM olist_orders
GROUP BY order_status
ORDER BY total_orders DESC;


-- Q3: Monthly Trend (Quick View) — for Power BI
SELECT
    FORMAT(o.order_purchase_timestamp, 'yyyy-MM')       AS order_month,
    COUNT(DISTINCT o.order_id)                          AS total_orders,
    ROUND(SUM(i.price), 2)                              AS total_revenue,
    ROUND(SUM(i.freight_value), 2)                      AS total_freight,
    ROUND(AVG(i.price), 2)                              AS avg_item_price
FROM olist_orders o
JOIN olist_order_items i ON o.order_id = i.order_id
WHERE o.order_status = 'delivered'
  AND o.order_purchase_timestamp IS NOT NULL
GROUP BY FORMAT(o.order_purchase_timestamp, 'yyyy-MM')
ORDER BY order_month;


-- ── Q4: Top 10 Product Categories by Revenue ───────────────
SELECT TOP 10
    COALESCE(t.product_category_name_english, p.product_category_name, 'Unknown') AS category,
    COUNT(DISTINCT i.order_id)              AS total_orders,
    ROUND(SUM(i.price), 2)                  AS total_revenue,
    ROUND(AVG(i.price), 2)                  AS avg_price
FROM olist_order_items i
JOIN olist_products    p ON i.product_id = p.product_id
LEFT JOIN product_category_name_translation t 
    ON p.product_category_name = t.product_category_name
GROUP BY COALESCE(t.product_category_name_english, p.product_category_name, 'Unknown')
ORDER BY total_revenue DESC;


-- ── Q5: Delivery Performance — On-Time vs Late ─────────────
SELECT
    COUNT(*)                                                        AS total_delivered,
    SUM(CASE WHEN order_delivered_customer_date 
                  <= order_estimated_delivery_date THEN 1 ELSE 0 END) AS on_time,
    SUM(CASE WHEN order_delivered_customer_date 
                  >  order_estimated_delivery_date THEN 1 ELSE 0 END) AS late,
    ROUND(
        SUM(CASE WHEN order_delivered_customer_date 
                      <= order_estimated_delivery_date THEN 1 ELSE 0 END) 
        * 100.0 / COUNT(*), 2
    )                                                               AS on_time_pct,
    ROUND(AVG(
        DATEDIFF(DAY, order_purchase_timestamp, order_delivered_customer_date)
    ), 1)                                                           AS avg_delivery_days
FROM olist_orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_estimated_delivery_date IS NOT NULL;


-- ── Q6: Average Delivery Delay by State ────────────────────
SELECT TOP 15
    c.customer_state,
    COUNT(DISTINCT o.order_id)                          AS total_orders,
    ROUND(AVG(
        DATEDIFF(DAY, o.order_estimated_delivery_date, 
                      o.order_delivered_customer_date)
    ), 1)                                               AS avg_delay_days,
    -- Negative = early, Positive = late
    SUM(CASE WHEN o.order_delivered_customer_date 
                  > o.order_estimated_delivery_date THEN 1 ELSE 0 END) AS late_orders
FROM olist_orders o
JOIN olist_customers c ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY c.customer_state
ORDER BY avg_delay_days DESC;


-- ── Q7: Payment Method Analysis ────────────────────────────
SELECT
    payment_type,
    COUNT(DISTINCT order_id)                            AS total_orders,
    ROUND(SUM(payment_value), 2)                        AS total_payment_value,
    ROUND(AVG(payment_value), 2)                        AS avg_payment_value,
    ROUND(AVG(CAST(payment_installments AS FLOAT)), 1)  AS avg_installments
FROM olist_order_payments
GROUP BY payment_type
ORDER BY total_orders DESC;


-- ── Q8: Top 10 Sellers by Revenue ──────────────────────────
SELECT TOP 10
    i.seller_id,
    s.seller_city,
    s.seller_state,
    COUNT(DISTINCT i.order_id)          AS total_orders,
    ROUND(SUM(i.price), 2)              AS total_revenue,
    ROUND(AVG(r.review_score), 2)       AS avg_review_score
FROM olist_order_items i
JOIN olist_sellers        s ON i.seller_id  = s.seller_id
JOIN olist_orders         o ON i.order_id   = o.order_id
LEFT JOIN olist_order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
GROUP BY i.seller_id, s.seller_city, s.seller_state
ORDER BY total_revenue DESC;


-- ── Q9: Customer Retention — Repeat Buyers ─────────────────
WITH customer_orders AS (
    SELECT 
        c.customer_unique_id,
        COUNT(o.order_id) AS order_count
    FROM olist_orders    o
    JOIN olist_customers c ON o.customer_id = c.customer_id
    GROUP BY c.customer_unique_id
)
SELECT
    SUM(CASE WHEN order_count = 1 THEN 1 ELSE 0 END)   AS one_time_buyers,
    SUM(CASE WHEN order_count > 1 THEN 1 ELSE 0 END)   AS repeat_buyers,
    COUNT(*)                                            AS total_unique_customers,
    ROUND(
        SUM(CASE WHEN order_count > 1 THEN 1 ELSE 0 END) 
        * 100.0 / COUNT(*), 2
    )                                                   AS repeat_rate_pct
FROM customer_orders;


-- ── Q10: Review Score Distribution by Category ─────────────
SELECT
    COALESCE(t.product_category_name_english, 
             p.product_category_name, 'Unknown')        AS category,
    COUNT(r.review_id)                                  AS total_reviews,
    ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)        AS avg_score,
    SUM(CASE WHEN r.review_score = 5 THEN 1 ELSE 0 END) AS five_star,
    SUM(CASE WHEN r.review_score = 1 THEN 1 ELSE 0 END) AS one_star
FROM olist_order_reviews r
JOIN olist_orders        o ON r.order_id   = o.order_id
JOIN olist_order_items   i ON o.order_id   = i.order_id
JOIN olist_products      p ON i.product_id = p.product_id
LEFT JOIN product_category_name_translation t 
    ON p.product_category_name = t.product_category_name
GROUP BY COALESCE(t.product_category_name_english, p.product_category_name, 'Unknown')
HAVING COUNT(r.review_id) > 100
ORDER BY avg_score DESC;

-- ============================================================
-- PART D: TIME SERIES DATASET FOR PYTHON FORECASTING
-- ============================================================

-- Monthly revenue dataset for ARIMA / SARIMA / Holt-Winters
WITH monthly_order_revenue AS (
    SELECT
        DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp),
            1
        )                               AS order_month,
        o.order_id,
        SUM(i.price + i.freight_value)  AS order_value,
        SUM(i.price)                    AS product_revenue,
        SUM(i.freight_value)            AS freight_revenue,
        SUM(i.price)                    AS total_price_sum,      -- for exact avg
        COUNT(i.order_item_id)          AS total_items           -- for exact avg
    FROM olist_orders o
    JOIN olist_order_items i
        ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp IS NOT NULL
    GROUP BY
        DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp),
            1
        ),
        o.order_id
),
review_summary AS (
    SELECT
        order_id,
        AVG(CAST(review_score AS FLOAT)) AS avg_review_score
    FROM olist_order_reviews
    GROUP BY order_id
)
SELECT
    m.order_month,
    COUNT(DISTINCT m.order_id)                              AS total_orders,
    ROUND(SUM(m.order_value), 2)                            AS total_revenue,
    ROUND(SUM(m.product_revenue), 2)                        AS product_revenue,
    ROUND(SUM(m.freight_revenue), 2)                        AS freight_revenue,
    ROUND(SUM(m.total_price_sum) / SUM(m.total_items), 2)  AS avg_item_price,   -- exact
    ROUND(AVG(m.order_value), 2)                            AS avg_order_value,
    ROUND(AVG(r.avg_review_score), 2)                       AS avg_review_score
FROM monthly_order_revenue m
LEFT JOIN review_summary r
    ON m.order_id = r.order_id
GROUP BY m.order_month
ORDER BY m.order_month;

--- RFM SCORE
WITH rfm AS (
    SELECT
        c.customer_unique_id,
        DATEDIFF(
            DAY,
            MAX(CAST(o.order_purchase_timestamp AS DATE)),
            (SELECT MAX(CAST(order_purchase_timestamp AS DATE))
             FROM olist_orders
             WHERE order_status = 'delivered')
        ) AS recency_days,
        COUNT(DISTINCT o.order_id) AS frequency,
        ROUND(SUM(i.price + i.freight_value), 2) AS monetary_value
    FROM olist_orders o
    JOIN olist_customers c 
        ON o.customer_id = c.customer_id
    JOIN olist_order_items i 
        ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
rfm_scores AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days DESC) AS recency_score,
        NTILE(5) OVER (ORDER BY frequency ASC) AS frequency_score,
        NTILE(5) OVER (ORDER BY monetary_value ASC) AS monetary_score
    FROM rfm
)
SELECT *,
    (recency_score + frequency_score + monetary_score) AS rfm_total_score,
    CASE
        WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4
            THEN 'Best Customers'
        WHEN recency_score >= 4 AND frequency_score >= 3
            THEN 'Loyal Customers'
        WHEN recency_score <= 2 AND frequency_score >= 3
            THEN 'At Risk'
        WHEN recency_score >= 4 AND frequency_score <= 2
            THEN 'New Customers'
        ELSE 'Others'
    END AS customer_segment
FROM rfm_scores
ORDER BY rfm_total_score DESC;

--cancelation analysis by month
SELECT
    DATEFROMPARTS(
        YEAR(order_purchase_timestamp),
        MONTH(order_purchase_timestamp),
        1
    ) AS order_month,

    COUNT(*) AS total_orders,

    SUM(CASE WHEN order_status = 'delivered'
             THEN 1 ELSE 0 END) AS delivered_orders,

    SUM(CASE WHEN order_status = 'canceled'
             THEN 1 ELSE 0 END) AS canceled_orders,

    SUM(CASE WHEN order_status NOT IN ('delivered', 'canceled')
             THEN 1 ELSE 0 END) AS other_status_orders,

    ROUND(
        SUM(CASE WHEN order_status = 'canceled'
                 THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        2
    ) AS cancellation_rate_pct,

    ROUND(
        SUM(CASE WHEN order_status = 'delivered'
                 THEN 1 ELSE 0 END) * 100.0 / COUNT(*),
        2
    ) AS delivery_rate_pct

FROM olist_orders
WHERE order_purchase_timestamp IS NOT NULL
GROUP BY DATEFROMPARTS(
    YEAR(order_purchase_timestamp),
    MONTH(order_purchase_timestamp),
    1
)
ORDER BY order_month;

-- Monthly New vs Returning Customers
WITH first_order AS (
    SELECT
        c.customer_unique_id,
        MIN(DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp), 1
        )) AS first_order_month
    FROM olist_orders o
    JOIN olist_customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
monthly_activity AS (
    SELECT
        c.customer_unique_id,
        DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp), 1
        ) AS activity_month
    FROM olist_orders o
    JOIN olist_customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id,
        DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp), 1
        )
)
SELECT
    FORMAT(ma.activity_month, 'yyyy-MM')            AS order_month,
    COUNT(CASE WHEN ma.activity_month = fo.first_order_month
               THEN 1 END)                          AS new_customers,
    COUNT(CASE WHEN ma.activity_month > fo.first_order_month
               THEN 1 END)                          AS returning_customers,
    COUNT(ma.customer_unique_id)                    AS total_customers
FROM monthly_activity ma
JOIN first_order fo ON ma.customer_unique_id = fo.customer_unique_id
GROUP BY ma.activity_month
ORDER BY ma.activity_month;
