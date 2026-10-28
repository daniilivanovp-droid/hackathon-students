-- Required analyst reports. Every answer is sourced from the core/mart model.

-- 1. Monthly delivered revenue (product price only), September 2016-August 2018.
SELECT month, order_count, revenue
FROM mart.monthly_sales
ORDER BY month;

-- 2. Top 10 sellers by delivered product revenue.
SELECT seller_id, city, state, order_count, unit_count, revenue
FROM mart.seller_sales
ORDER BY revenue DESC, seller_id
LIMIT 10;

-- 3. Average order value includes freight; item metrics remain order-level.
SELECT avg(order_value)::numeric(14, 2) AS average_order_value,
       avg(item_count)::numeric(14, 2) AS average_lines_per_order,
       avg(unit_count)::numeric(14, 2) AS average_units_per_order
FROM mart.order_financials
WHERE is_revenue_order;

-- 4. Capibara customers and repeat purchasers use customer_unique_id.
WITH customers AS (
    SELECT customer_unique_id,
           order_count
    FROM mart.customer_orders
    WHERE order_count > 0
)
SELECT count(*)::integer AS total_customers,
       count(*) FILTER (WHERE order_count >= 2)::integer AS repeat_customers,
       (100.0 * count(*) FILTER (WHERE order_count >= 2) / count(*))::numeric(7, 2) AS repeat_share_pct
FROM customers;

-- 5. Delivered revenue by category. Untranslated/missing categories are
-- retained as separate category rows; total revenue must reconcile to #1.
SELECT category, revenue, revenue_share_pct
FROM mart.category_sales
ORDER BY revenue DESC, category;
