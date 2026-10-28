-- Ответы аналитикам строятся только из core и mart.

-- 1. Заказы и выручка по месяцам. Календарный ряд сохраняет месяц без заказов.
WITH months AS (
    SELECT generate_series(
        date '2016-09-01',
        date '2018-08-01',
        interval '1 month'
    )::date AS month
)
SELECT months.month,
       COALESCE(s.order_count, 0)::integer AS order_count,
       COALESCE(s.revenue, 0)::numeric(14, 2) AS revenue
FROM months
LEFT JOIN mart.monthly_sales s ON s.month = months.month
ORDER BY months.month;

-- 2. Десять продавцов с наибольшей выручкой по их позициям.
SELECT seller_id, city, state, order_count, unit_count, revenue
FROM mart.seller_sales
ORDER BY revenue DESC, seller_id
LIMIT 10;

-- 3. Средний чек с доставкой, рассчитанный на уровне заказа.
SELECT avg(order_value)::numeric(14, 2) AS average_order_value,
       avg(item_count)::numeric(14, 2) AS average_lines_per_order,
       avg(unit_count)::numeric(14, 2) AS average_units_per_order
FROM mart.order_financials
WHERE is_revenue_order;

-- 4. Покупатели и повторные покупки по всем оформленным заказам.
-- customer_unique_id объединяет записи одного человека.
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

-- 5. Выручка по категориям. Non category и категории с добавленным
-- переводом сохраняются отдельными строками.
SELECT category, revenue, revenue_share_pct
FROM mart.category_sales
ORDER BY revenue DESC, category;
