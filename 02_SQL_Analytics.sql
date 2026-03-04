CREATE DATABASE olist_dwh;
GO
USE olist_dwh

--------------

------------------------------------------------------------------------------
--  What is monthly revenue, and what is the MoM and YoY growth rate? 
------------------------------------------------------------------------------
CREATE VIEW vw_revenue_trends AS
WITH monthly_base AS (
    SELECT
        DATEFROMPARTS(YEAR(o.order_purchase_timestamp), 
                      MONTH(o.order_purchase_timestamp), 1)    AS month_start,
        COUNT(DISTINCT o.order_id)                             AS total_orders,
        COUNT(DISTINCT o.customer_id)                          AS unique_customers,
        ROUND(SUM(oi.price + oi.freight_value), 2)             AS gross_revenue,
        ROUND(SUM(oi.price), 2)                                AS product_revenue,
        ROUND(SUM(oi.freight_value), 2)                        AS freight_revenue,
        ROUND(SUM(oi.price + oi.freight_value) 
              / COUNT(DISTINCT o.order_id), 2)                 AS aov
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY 
        YEAR(o.order_purchase_timestamp),
        MONTH(o.order_purchase_timestamp)
),
growth_calc AS (
    SELECT
        month_start,
        total_orders,
        unique_customers,
        gross_revenue,
        product_revenue,
        freight_revenue,
        aov,

        -- MoM Growth
        LAG(gross_revenue, 1) OVER (ORDER BY month_start)     AS prev_month_revenue,
        ROUND(
            (gross_revenue - LAG(gross_revenue,1) OVER (ORDER BY month_start))
            / NULLIF(LAG(gross_revenue,1) OVER (ORDER BY month_start), 0) * 100
        , 2)                                                   AS mom_growth_pct,

        -- YoY Growth
        LAG(gross_revenue, 12) OVER (ORDER BY month_start)    AS same_month_last_year,
        ROUND(
            (gross_revenue - LAG(gross_revenue,12) OVER (ORDER BY month_start))
            / NULLIF(LAG(gross_revenue,12) OVER (ORDER BY month_start), 0) * 100
        , 2)                                                   AS yoy_growth_pct,

        -- 3-Month Moving Average
        ROUND(AVG(gross_revenue) OVER (
            ORDER BY month_start 
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ), 2)                                                  AS revenue_3mo_avg,

        -- Cumulative Revenue (YTD)
        ROUND(SUM(gross_revenue) OVER (
            PARTITION BY YEAR(month_start)
            ORDER BY month_start
        ), 2)                                                  AS ytd_revenue

    FROM monthly_base
)
SELECT * FROM growth_calc;

SELECT month_start, total_orders, gross_revenue, aov, mom_growth_pct, yoy_growth_pct, ytd_revenue FROM vw_revenue_trends




------------------------------------------------------------------------------------------
--   What are the top-performing product categories by revenue and order volume? 
------------------------------------------------------------------------------------------


CREATE VIEW vw_category_performance AS
WITH category_base AS (
    SELECT
        p.category_name,
        COUNT(DISTINCT o.order_id)                            AS total_orders,
        COUNT(oi.order_item_id)                               AS units_sold,
        ROUND(SUM(oi.price), 2)                               AS total_revenue,
        ROUND(AVG(oi.price), 2)                               AS avg_price,
        ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)          AS avg_review_score
    FROM order_items oi
    JOIN orders o          ON oi.order_id   = o.order_id
    JOIN products p        ON oi.product_id = p.product_id
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND p.category_name IS NOT NULL
    GROUP BY p.category_name
)
SELECT
    category_name,
    total_orders,
    units_sold,
    total_revenue,
    avg_price,
    avg_review_score,
    RANK() OVER (ORDER BY total_revenue DESC)                 AS revenue_rank,
    ROUND(total_revenue / SUM(total_revenue) OVER() * 100, 2) AS revenue_share_pct,
    ROUND(SUM(total_revenue) OVER (
        ORDER BY total_revenue DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / SUM(total_revenue) OVER() * 100, 2)                  AS cumulative_revenue_pct,
    CASE WHEN
        SUM(total_revenue) OVER (
            ORDER BY total_revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) / SUM(total_revenue) OVER() * 100 <= 80
    THEN 'Top 80%' ELSE 'Long Tail' END                       AS pareto_group
FROM category_base;

SELECT * FROM vw_category_performance

------------------------------------------------------------------------------------------
--   Is there a correlation between product price and review score?
------------------------------------------------------------------------------------------
CREATE VIEW vw_price_review_correlation AS
WITH buckets AS (
    SELECT
        CASE
            WHEN oi.price < 50                                THEN 'Under R$50'
            WHEN oi.price BETWEEN 50  AND 100                 THEN 'R$50–100'
            WHEN oi.price BETWEEN 100 AND 250                 THEN 'R$100–250'
            WHEN oi.price BETWEEN 250 AND 500                 THEN 'R$250–500'
            ELSE 'Over R$500'
        END                                                    AS price_bucket,
        CASE
            WHEN oi.price < 50   THEN 1
            WHEN oi.price < 100  THEN 2
            WHEN oi.price < 250  THEN 3
            WHEN oi.price < 500  THEN 4
            ELSE 5
        END                                                    AS bucket_order,
        r.review_score,
        oi.price
    FROM order_items oi
    JOIN orders o          ON oi.order_id   = o.order_id
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND r.review_score IS NOT NULL
)
SELECT
    price_bucket,
    bucket_order,
    COUNT(*)                                                   AS total_records,
    ROUND(AVG(CAST(review_score AS FLOAT)), 3)                 AS avg_review_score,
    ROUND(AVG(price), 2)                                       AS avg_price,
    ROUND(STDEV(CAST(review_score AS FLOAT)), 3)               AS review_score_stdev
FROM buckets
GROUP BY price_bucket, bucket_order;

SELECT * FROM vw_price_review_correlation


------------------------------------------------------------------------------------------------
--  What percentage of customers make more than one purchase? (Repeat Purchase Rate)
------------------------------------------------------------------------------------------------

CREATE VIEW vw_repeat_purchase_rate AS
WITH customer_orders AS (
    SELECT
        c.customer_unique_id,
        COUNT(DISTINCT o.order_id)                             AS total_orders,
        MIN(o.order_purchase_timestamp)                        AS first_purchase,
        MAX(o.order_purchase_timestamp)                        AS last_purchase,
        DATEDIFF(DAY,
            MIN(o.order_purchase_timestamp),
            MAX(o.order_purchase_timestamp))                   AS customer_lifespan_days
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id          -- ← unique_id, not customer_id
)
SELECT
    total_orders                                               AS order_count_bucket,
    COUNT(customer_unique_id)                                  AS customer_count,
    ROUND(COUNT(customer_unique_id) * 100.0
          / SUM(COUNT(customer_unique_id)) OVER(), 2)          AS pct_of_customers,
    CASE
        WHEN total_orders = 1             THEN 'One-Time Buyer'
        WHEN total_orders BETWEEN 2 AND 3 THEN 'Occasional'
        WHEN total_orders BETWEEN 4 AND 6 THEN 'Regular'
        ELSE 'Loyal'
    END                                                        AS buyer_type
FROM customer_orders
GROUP BY total_orders;



SELECT * FROM vw_repeat_purchase_rate




------------------------------------------------------------------------------------------------
--  How do customer cohorts retain over time?
------------------------------------------------------------------------------------------------

CREATE VIEW vw_cohort_retention AS
WITH customer_first_order AS (
    SELECT
        c.customer_unique_id,
        MIN(DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp), 1))             AS cohort_month
    FROM orders o
    JOIN customers c ON o.customer_id = c.customer_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
order_months AS (
    SELECT
        c.customer_unique_id,
        DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp), 1)              AS order_month,
        cfo.cohort_month,
        DATEDIFF(MONTH,
            cfo.cohort_month,
            DATEFROMPARTS(
                YEAR(o.order_purchase_timestamp),
                MONTH(o.order_purchase_timestamp), 1))         AS month_number
    FROM orders o
    JOIN customers c             ON o.customer_id  = c.customer_id
    JOIN customer_first_order cfo ON c.customer_unique_id = cfo.customer_unique_id
    WHERE o.order_status = 'delivered'
),
cohort_size AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT customer_unique_id)                     AS cohort_customers
    FROM customer_first_order
    GROUP BY cohort_month
)
SELECT
    om.cohort_month,
    cs.cohort_customers,
    om.month_number,
    COUNT(DISTINCT om.customer_unique_id)                      AS active_customers,
    ROUND(COUNT(DISTINCT om.customer_unique_id) * 100.0
          / cs.cohort_customers, 2)                            AS retention_rate_pct
FROM order_months om
JOIN cohort_size cs ON om.cohort_month = cs.cohort_month
GROUP BY om.cohort_month, cs.cohort_customers, om.month_number;


SELECT * FROM vw_cohort_retention
 


------------------------------------------------------------------------------------------------
-- What is each customer's RFM score and segment?
------------------------------------------------------------------------------------------------
CREATE VIEW vw_rfm_segments AS
WITH snapshot AS (
    SELECT MAX(order_purchase_timestamp) AS snapshot_date
    FROM orders
    WHERE order_status = 'delivered'
),
rfm_raw AS (
    SELECT
        c.customer_unique_id,
        DATEDIFF(DAY,
            MAX(o.order_purchase_timestamp),
            (SELECT snapshot_date FROM snapshot))              AS recency_days,
        COUNT(DISTINCT o.order_id)                             AS frequency,
        ROUND(SUM(oi.price + oi.freight_value), 2)             AS monetary
    FROM orders o
    JOIN customers c    ON o.customer_id  = c.customer_id
    JOIN order_items oi ON o.order_id     = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
),
rfm_scored AS (
    SELECT
        customer_unique_id,
        recency_days,
        frequency,
        monetary,
        NTILE(5) OVER (ORDER BY recency_days ASC)              AS r_score,
        NTILE(5) OVER (ORDER BY frequency    DESC)             AS f_score,
        NTILE(5) OVER (ORDER BY monetary     DESC)             AS m_score
    FROM rfm_raw
)
SELECT
    customer_unique_id,
    recency_days,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    CAST(r_score AS VARCHAR)
        + CAST(f_score AS VARCHAR)
        + CAST(m_score AS VARCHAR)                             AS rfm_score,
    r_score + f_score + m_score                                AS rfm_total,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4   THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3   THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2                    THEN 'Recent Customers'
        WHEN r_score >= 3 AND f_score <= 2 AND m_score >= 3   THEN 'Potential Loyalists'
        WHEN r_score <= 2 AND f_score >= 3 AND m_score >= 3   THEN 'At Risk'
        WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 4   THEN 'Cannot Lose Them'
        WHEN r_score <= 2 AND f_score <= 2 AND m_score <= 2   THEN 'Hibernating'
        ELSE 'Needs Attention'
    END                                                        AS rfm_segment
FROM rfm_scored;



SELECT * FROM vw_rfm_segments


------------------------------------------------------------------------------------------------
-- What is the average Customer Lifetime Value (CLV) by segment?
------------------------------------------------------------------------------------------------
CREATE VIEW vw_customer_ltv AS
WITH customer_metrics AS (
    SELECT
        c.customer_unique_id,
        ROUND(SUM(oi.price + oi.freight_value), 2) AS total_spent
    FROM orders o
    JOIN customers c    ON o.customer_id  = c.customer_id
    JOIN order_items oi ON o.order_id     = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT
    rfm.rfm_segment,
    ROUND(AVG(cm.total_spent), 2) AS avg_clv
FROM customer_metrics cm
JOIN vw_rfm_segments rfm
    ON cm.customer_unique_id = rfm.customer_unique_id
GROUP BY rfm.rfm_segment;



SELECT * FROM vw_customer_ltv



------------------------------------------------------------------------------------------
-- Who are the top and bottom performing sellers by revenue, volume, and review score? 
------------------------------------------------------------------------------------------

CREATE VIEW vw_seller_performance AS
WITH seller_base AS (
    SELECT
        oi.seller_id,
        s.seller_city,
        s.seller_state,
        COUNT(DISTINCT o.order_id)                            AS total_orders,
        COUNT(oi.order_item_id)                               AS units_sold,
        ROUND(SUM(oi.price), 2)                               AS total_revenue,
        ROUND(AVG(oi.price), 2)                               AS avg_selling_price,
        ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)          AS avg_review_score,
        COUNT(DISTINCT oi.product_id)                         AS unique_products,
        MIN(o.order_purchase_timestamp)                       AS first_sale_date,
        MAX(o.order_purchase_timestamp)                       AS last_sale_date,
        DATEDIFF(DAY,
            MIN(o.order_purchase_timestamp),S
            MAX(o.order_purchase_timestamp)) + 1              AS active_days
    FROM order_items oi
    JOIN orders o          ON oi.order_id   = o.order_id
    JOIN sellers s         ON oi.seller_id  = s.seller_id
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY oi.seller_id, s.seller_city, s.seller_state
)
SELECT
    seller_id,
    seller_city,
    seller_state,
    total_orders,
    units_sold,
    total_revenue,
    avg_selling_price,
    avg_review_score,
    unique_products,
    active_days,
    ROUND(total_revenue / NULLIF(active_days, 0) * 30, 2)     AS monthly_revenue_rate,
    RANK() OVER (ORDER BY total_revenue DESC)                  AS revenue_rank,
    RANK() OVER (ORDER BY avg_review_score DESC)               AS review_rank,
    NTILE(4) OVER (ORDER BY total_revenue DESC)                AS revenue_quartile,
    -- Seller health score (composite)
    ROUND((
        NTILE(5) OVER (ORDER BY total_revenue   DESC) * 0.4 +
        NTILE(5) OVER (ORDER BY avg_review_score ASC) * 0.3 +
        NTILE(5) OVER (ORDER BY total_orders     DESC) * 0.3
    ), 2)                                                      AS seller_health_score
FROM seller_base;

SELECT * FROM vw_seller_performance


------------------------------------------------------------------------------------------------
--  What is each seller's on-time delivery rate and how does it affect their review score?
------------------------------------------------------------------------------------------------

CREATE VIEW vw_seller_delivery_vs_reviews AS
WITH seller_delivery AS (
    SELECT
        oi.seller_id,
        COUNT(DISTINCT o.order_id)                            AS total_orders,
        SUM(CASE
            WHEN o.order_delivered_customer_date
                 <= o.order_estimated_delivery_date
            THEN 1 ELSE 0 END)                                AS on_time_deliveries,
        ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)          AS avg_review_score,
        ROUND(AVG(DATEDIFF(DAY,
            o.order_delivered_carrier_date,
            o.order_delivered_customer_date)), 1)              AS avg_transit_days,
        ROUND(AVG(DATEDIFF(DAY,
            o.order_delivered_customer_date,
            o.order_estimated_delivery_date)), 1)              AS avg_days_vs_estimate
    FROM order_items oi
    JOIN orders o          ON oi.order_id   = o.order_id
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
    GROUP BY oi.seller_id
)
SELECT
    seller_id,
    total_orders,
    on_time_deliveries,
    ROUND(on_time_deliveries * 100.0
          / NULLIF(total_orders, 0), 2)                        AS on_time_rate_pct,
    avg_review_score,
    avg_transit_days,
    avg_days_vs_estimate,
    CASE
        WHEN on_time_deliveries * 100.0
             / NULLIF(total_orders,0) >= 90                    THEN 'High Performer'
        WHEN on_time_deliveries * 100.0
             / NULLIF(total_orders,0) >= 70                    THEN 'Average'
        ELSE 'Needs Improvement'
    END                                                        AS delivery_tier
FROM seller_delivery;

SELECT * FROM vw_seller_delivery_vs_reviews



------------------------------------------------------------------------------------------------
--  What payment methods do customers prefer, and how does this vary by order value?
------------------------------------------------------------------------------------------------


CREATE VIEW vw_payment_method_analysis AS
    SELECT
        op.payment_type,
        COUNT(DISTINCT op.order_id)                           AS total_orders,
        ROUND(SUM(op.payment_value), 2)                       AS total_payment_value,
        ROUND(AVG(op.payment_value), 2)                       AS avg_payment_value,
        ROUND(AVG(CAST(op.payment_installments AS FLOAT)), 2) AS avg_installments,
        SUM(CASE WHEN op.payment_installments > 1
                 THEN 1 ELSE 0 END)                           AS installment_orders
    FROM order_payments op
    JOIN orders o ON op.order_id = o.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY op.payment_type

SELECT * FROM vw_payment_method_analysis




------------------------------------------------------------------------------------------------
--  What is the monthly revenue split by payment method?
------------------------------------------------------------------------------------------------
CREATE VIEW vw_monthly_revenue_by_payment AS
SELECT
    DATEFROMPARTS(
        YEAR(o.order_purchase_timestamp),
        MONTH(o.order_purchase_timestamp), 1)                 AS month_start,
    op.payment_type,
    COUNT(DISTINCT op.order_id)                               AS total_orders,
    ROUND(SUM(op.payment_value), 2)                           AS total_revenue,
    ROUND(AVG(op.payment_value), 2)                           AS avg_order_value,
    ROUND(SUM(op.payment_value) * 100.0 / SUM(SUM(op.payment_value)) OVER (
        PARTITION BY DATEFROMPARTS(
            YEAR(o.order_purchase_timestamp),
            MONTH(o.order_purchase_timestamp), 1)
    ), 2)                                                     AS monthly_revenue_share_pct
FROM order_payments op
JOIN orders o ON op.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY
    YEAR(o.order_purchase_timestamp),
    MONTH(o.order_purchase_timestamp),
    op.payment_type;


SELECT * FROM vw_monthly_revenue_by_payment









-- Needed for Filled Map
CREATE VIEW vw_revenue_by_state AS
SELECT
    c.customer_state,
    COUNT(DISTINCT o.order_id)                                AS total_orders,
    COUNT(DISTINCT c.customer_unique_id)                      AS unique_customers,
    ROUND(SUM(oi.price + oi.freight_value), 2)                AS total_revenue,
    ROUND(AVG(oi.price + oi.freight_value), 2)                AS avg_order_value,
    ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)              AS avg_review_score,
    ROUND(SUM(oi.price + oi.freight_value) * 100.0
          / SUM(SUM(oi.price + oi.freight_value)) OVER(), 2)  AS revenue_share_pct
FROM orders o
JOIN customers c       ON o.customer_id  = c.customer_id
JOIN order_items oi    ON o.order_id     = oi.order_id
LEFT JOIN order_reviews r ON o.order_id  = r.order_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state;

SELECT * FROM vw_revenue_by_state





-- 1. Monthly delivery performance
CREATE VIEW vw_delivery_performance_monthly AS
SELECT
    DATEFROMPARTS(
        YEAR(order_purchase_timestamp),
        MONTH(order_purchase_timestamp), 1)                   AS month_start,
    COUNT(order_id)                                           AS total_orders,
    SUM(CASE WHEN order_delivered_customer_date
             <= order_estimated_delivery_date
             THEN 1 ELSE 0 END)                               AS on_time,
    SUM(CASE WHEN order_delivered_customer_date
             > order_estimated_delivery_date
             THEN 1 ELSE 0 END)                               AS late,
    ROUND(SUM(CASE WHEN order_delivered_customer_date
                   <= order_estimated_delivery_date
                   THEN 1.0 ELSE 0 END)
          / NULLIF(COUNT(order_id), 0) * 100, 2)              AS on_time_rate_pct,
    ROUND(AVG(DATEDIFF(DAY,
        order_purchase_timestamp,
        order_delivered_customer_date)), 1)                   AS avg_delivery_days,
    ROUND(AVG(DATEDIFF(DAY,
        order_delivered_customer_date,
        order_estimated_delivery_date)), 1)                   AS avg_days_vs_estimate
FROM orders
WHERE order_status = 'delivered'
GROUP BY
    YEAR(order_purchase_timestamp),
    MONTH(order_purchase_timestamp);








    -- 2. Delivery performance by state
CREATE VIEW vw_delivery_by_state AS
WITH state_delivery AS (
    SELECT
        c.customer_state,
        COUNT(DISTINCT o.order_id)                            AS total_orders,
        ROUND(AVG(DATEDIFF(DAY,
            o.order_purchase_timestamp,
            o.order_delivered_customer_date)), 1)             AS avg_delivery_days,
        ROUND(AVG(DATEDIFF(DAY,
            o.order_delivered_customer_date,
            o.order_estimated_delivery_date)), 1)             AS avg_delay_days,
        SUM(CASE WHEN o.order_delivered_customer_date
                 > o.order_estimated_delivery_date
                 THEN 1 ELSE 0 END)                           AS late_orders,
        ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)          AS avg_review_score,
        ROUND(AVG(oi.freight_value), 2)                       AS avg_freight_cost
    FROM orders o
    JOIN customers c       ON o.customer_id  = c.customer_id
    JOIN order_items oi    ON o.order_id     = oi.order_id
    LEFT JOIN order_reviews r ON o.order_id  = r.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
    GROUP BY c.customer_state
)
SELECT
    customer_state,
    total_orders,
    avg_delivery_days,
    avg_delay_days,
    late_orders,
    ROUND(late_orders * 100.0
          / NULLIF(total_orders, 0), 2)                       AS late_rate_pct,
    avg_review_score,
    avg_freight_cost,
    RANK() OVER (ORDER BY avg_delivery_days DESC)             AS slowest_delivery_rank,
    RANK() OVER (ORDER BY late_orders DESC)                   AS most_late_rank
FROM state_delivery;






-- 3. Delay vs review score
CREATE VIEW vw_delay_vs_review AS
WITH order_delay AS (
    SELECT
        o.order_id,
        DATEDIFF(DAY,
            o.order_estimated_delivery_date,
            o.order_delivered_customer_date)                  AS delay_days,
        r.review_score
    FROM orders o
    LEFT JOIN order_reviews r ON o.order_id = r.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_delivered_customer_date IS NOT NULL
      AND r.review_score IS NOT NULL
)
SELECT
    CASE
        WHEN delay_days <= -7                                 THEN 'Very Early (7d+)'
        WHEN delay_days BETWEEN -6 AND -1                     THEN 'Early (1-6d)'
        WHEN delay_days = 0                                   THEN 'On Time'
        WHEN delay_days BETWEEN 1 AND 3                       THEN 'Slightly Late (1-3d)'
        WHEN delay_days BETWEEN 4 AND 7                       THEN 'Late (4-7d)'
        ELSE 'Very Late (7d+)'
    END                                                       AS delay_bucket,
    CASE
        WHEN delay_days <= -7  THEN 1
        WHEN delay_days < 0    THEN 2
        WHEN delay_days = 0    THEN 3
        WHEN delay_days <= 3   THEN 4
        WHEN delay_days <= 7   THEN 5
        ELSE 6
    END                                                       AS bucket_sort,
    COUNT(order_id)                                           AS order_count,
    ROUND(AVG(CAST(review_score AS FLOAT)), 3)                AS avg_review_score,
    SUM(CASE WHEN review_score = 5 THEN 1 ELSE 0 END)         AS five_star_count,
    SUM(CASE WHEN review_score <= 2 THEN 1 ELSE 0 END)        AS low_score_count
FROM order_delay
GROUP BY
    CASE
        WHEN delay_days <= -7                                 THEN 'Very Early (7d+)'
        WHEN delay_days BETWEEN -6 AND -1                     THEN 'Early (1-6d)'
        WHEN delay_days = 0                                   THEN 'On Time'
        WHEN delay_days BETWEEN 1 AND 3                       THEN 'Slightly Late (1-3d)'
        WHEN delay_days BETWEEN 4 AND 7                       THEN 'Late (4-7d)'
        ELSE 'Very Late (7d+)'
    END,
    CASE
        WHEN delay_days <= -7  THEN 1
        WHEN delay_days < 0    THEN 2
        WHEN delay_days = 0    THEN 3
        WHEN delay_days <= 3   THEN 4
        WHEN delay_days <= 7   THEN 5
        ELSE 6
    END;








    -- Installments analysis
CREATE VIEW vw_installments_analysis AS
SELECT
    op.payment_installments,
    COUNT(DISTINCT op.order_id)                               AS total_orders,
    ROUND(AVG(op.payment_value), 2)                           AS avg_order_value,
    ROUND(SUM(op.payment_value), 2)                           AS total_revenue,
    ROUND(AVG(CAST(r.review_score AS FLOAT)), 2)              AS avg_review_score
FROM order_payments op
JOIN orders o          ON op.order_id = o.order_id
LEFT JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND op.payment_installments > 0
GROUP BY op.payment_installments;