-- Build the typed core model and reusable marts from raw.
-- Revenue means product price on delivered orders only.

DROP VIEW IF EXISTS mart.category_sales;
DROP VIEW IF EXISTS mart.customer_orders;
DROP VIEW IF EXISTS mart.seller_sales;
DROP VIEW IF EXISTS mart.monthly_sales;
DROP VIEW IF EXISTS mart.order_financials;

DROP TABLE IF EXISTS core.order_reviews;
DROP TABLE IF EXISTS core.order_payments;
DROP TABLE IF EXISTS core.order_items;
DROP TABLE IF EXISTS core.orders;
DROP TABLE IF EXISTS core.products;
DROP TABLE IF EXISTS core.categories;
DROP TABLE IF EXISTS core.sellers;
DROP TABLE IF EXISTS core.customers;

CREATE TABLE core.customers (
    customer_id text PRIMARY KEY,
    customer_unique_id text NOT NULL,
    zip_code_prefix integer,
    city text,
    state text
);

CREATE TABLE core.sellers (
    seller_id text PRIMARY KEY,
    zip_code_prefix integer,
    city text,
    state text
);

CREATE TABLE core.categories (
    category_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_name_pt text UNIQUE,
    category_name_en text,
    is_translated boolean NOT NULL DEFAULT false,
    CONSTRAINT categories_name_present CHECK (category_name_pt IS NOT NULL OR category_name_en IS NULL)
);

CREATE UNIQUE INDEX categories_null_name_uq
    ON core.categories ((category_name_pt IS NULL))
    WHERE category_name_pt IS NULL;

CREATE TABLE core.products (
    product_id text PRIMARY KEY,
    category_id bigint REFERENCES core.categories(category_id),
    name_length integer,
    description_length integer,
    photos_qty integer,
    weight_g numeric,
    length_cm numeric,
    height_cm numeric,
    width_cm numeric
);

CREATE TABLE core.orders (
    order_id text PRIMARY KEY,
    customer_id text NOT NULL REFERENCES core.customers(customer_id),
    order_status text NOT NULL,
    purchased_at timestamp NOT NULL,
    approved_at timestamp,
    delivered_carrier_at timestamp,
    delivered_customer_at timestamp,
    estimated_delivery_at timestamp
);

CREATE TABLE core.order_items (
    order_id text NOT NULL REFERENCES core.orders(order_id),
    order_item_id integer NOT NULL,
    product_id text REFERENCES core.products(product_id),
    seller_id text NOT NULL REFERENCES core.sellers(seller_id),
    shipping_limit_at timestamp,
    price numeric(12, 2) NOT NULL,
    freight_value numeric(12, 2) NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE core.order_payments (
    order_id text NOT NULL REFERENCES core.orders(order_id),
    payment_sequential integer NOT NULL,
    payment_type text NOT NULL,
    payment_installments integer NOT NULL,
    payment_value numeric(12, 2) NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

CREATE TABLE core.order_reviews (
    review_id text NOT NULL,
    order_id text NOT NULL REFERENCES core.orders(order_id),
    review_score integer,
    comment_title text,
    comment_message text,
    created_at timestamp,
    answered_at timestamp,
    PRIMARY KEY (review_id, order_id)
);

INSERT INTO core.customers
SELECT customer_id,
       customer_unique_id,
       NULLIF(customer_zip_code_prefix, '')::integer,
       NULLIF(customer_city, ''),
       NULLIF(customer_state, '')
FROM raw.customers;

INSERT INTO core.sellers
SELECT seller_id,
       NULLIF(seller_zip_code_prefix, '')::integer,
       NULLIF(seller_city, ''),
       NULLIF(seller_state, '')
FROM raw.sellers;

INSERT INTO core.categories (category_name_pt, category_name_en, is_translated)
SELECT t.product_category_name,
       t.product_category_name_english,
       t.product_category_name_english IS NOT NULL
FROM raw.product_category_translation t
WHERE NULLIF(t.product_category_name, '') IS NOT NULL
UNION ALL
SELECT NULL, NULL, false
WHERE EXISTS (
    SELECT 1
    FROM raw.products p
    WHERE NULLIF(p.product_category_name, '') IS NULL
);

INSERT INTO core.products
SELECT p.product_id,
       c.category_id,
       NULLIF(p.product_name_lenght, '')::integer,
       NULLIF(p.product_description_lenght, '')::integer,
       NULLIF(p.product_photos_qty, '')::integer,
       NULLIF(p.product_weight_g, '')::numeric,
       NULLIF(p.product_length_cm, '')::numeric,
       NULLIF(p.product_height_cm, '')::numeric,
       NULLIF(p.product_width_cm, '')::numeric
FROM raw.products p
LEFT JOIN core.categories c
  ON c.category_name_pt = NULLIF(p.product_category_name, '');

INSERT INTO core.orders
SELECT order_id,
       customer_id,
       order_status,
       NULLIF(order_purchase_timestamp, '')::timestamp,
       NULLIF(order_approved_at, '')::timestamp,
       NULLIF(order_delivered_carrier_date, '')::timestamp,
       NULLIF(order_delivered_customer_date, '')::timestamp,
       NULLIF(order_estimated_delivery_date, '')::timestamp
FROM raw.orders;

INSERT INTO core.order_items
SELECT order_id,
       order_item_id::integer,
       NULLIF(product_id, ''),
       seller_id,
       NULLIF(shipping_limit_date, '')::timestamp,
       NULLIF(price, '')::numeric(12, 2),
       NULLIF(freight_value, '')::numeric(12, 2)
FROM raw.order_items;

INSERT INTO core.order_payments
SELECT order_id,
       payment_sequential::integer,
       payment_type,
       payment_installments::integer,
       payment_value::numeric(12, 2)
FROM raw.order_payments;

INSERT INTO core.order_reviews
SELECT review_id,
       order_id,
       NULLIF(review_score, '')::integer,
       NULLIF(review_comment_title, ''),
       NULLIF(review_comment_message, ''),
       NULLIF(review_creation_date, '')::timestamp,
       NULLIF(review_answer_timestamp, '')::timestamp
FROM raw.order_reviews;

CREATE VIEW mart.order_financials AS
WITH item_totals AS (
    SELECT order_id,
           count(*)::integer AS item_count,
           count(product_id)::integer AS product_count,
           sum(price)::numeric(14, 2) AS product_revenue,
           sum(freight_value)::numeric(14, 2) AS freight_value
    FROM core.order_items
    GROUP BY order_id
)
SELECT o.order_id,
       o.customer_id,
       c.customer_unique_id,
       o.order_status,
       o.purchased_at,
       COALESCE(i.item_count, 0) AS item_count,
       COALESCE(i.product_count, 0) AS unit_count,
       COALESCE(i.product_revenue, 0)::numeric(14, 2) AS product_revenue,
       COALESCE(i.freight_value, 0)::numeric(14, 2) AS freight_value,
       (COALESCE(i.product_revenue, 0) + COALESCE(i.freight_value, 0))::numeric(14, 2) AS order_value,
       (o.order_status = 'delivered') AS is_revenue_order
FROM core.orders o
JOIN core.customers c ON c.customer_id = o.customer_id
LEFT JOIN item_totals i ON i.order_id = o.order_id;

CREATE VIEW mart.monthly_sales AS
WITH months AS (
    SELECT generate_series(
        date '2016-09-01',
        date '2018-08-01',
        interval '1 month'
    )::date AS month
)
SELECT m.month,
       count(f.order_id) FILTER (WHERE f.is_revenue_order)::integer AS order_count,
       COALESCE(sum(f.product_revenue) FILTER (WHERE f.is_revenue_order), 0)::numeric(14, 2) AS revenue
FROM months m
LEFT JOIN mart.order_financials f
  ON date_trunc('month', f.purchased_at)::date = m.month
GROUP BY m.month
ORDER BY m.month;

CREATE VIEW mart.seller_sales AS
SELECT s.seller_id,
       s.city,
       s.state,
       count(DISTINCT i.order_id) FILTER (WHERE o.order_status = 'delivered')::integer AS order_count,
       count(*) FILTER (WHERE o.order_status = 'delivered')::integer AS unit_count,
       COALESCE(sum(i.price) FILTER (WHERE o.order_status = 'delivered'), 0)::numeric(14, 2) AS revenue
FROM core.sellers s
JOIN core.order_items i ON i.seller_id = s.seller_id
JOIN core.orders o ON o.order_id = i.order_id
GROUP BY s.seller_id, s.city, s.state;

CREATE VIEW mart.customer_orders AS
SELECT f.customer_unique_id,
       count(*) FILTER (WHERE f.is_revenue_order)::integer AS order_count,
       min(f.purchased_at) FILTER (WHERE f.is_revenue_order) AS first_order_at,
       max(f.purchased_at) FILTER (WHERE f.is_revenue_order) AS last_order_at,
       COALESCE(sum(f.product_revenue) FILTER (WHERE f.is_revenue_order), 0)::numeric(14, 2) AS revenue
FROM mart.order_financials f
GROUP BY f.customer_unique_id;

CREATE VIEW mart.category_sales AS
SELECT COALESCE(c.category_name_en, c.category_name_pt, '(missing category)') AS category,
       c.category_name_pt,
       c.category_name_en,
       c.is_translated,
       COALESCE(sum(i.price) FILTER (WHERE o.order_status = 'delivered'), 0)::numeric(14, 2) AS revenue,
       CASE
           WHEN sum(sum(i.price) FILTER (WHERE o.order_status = 'delivered')) OVER () = 0 THEN 0
           ELSE (COALESCE(sum(i.price) FILTER (WHERE o.order_status = 'delivered'), 0)
                 / sum(sum(i.price) FILTER (WHERE o.order_status = 'delivered')) OVER () * 100)::numeric(7, 3)
       END AS revenue_share_pct
FROM core.categories c
LEFT JOIN core.products p ON p.category_id = c.category_id
LEFT JOIN core.order_items i ON i.product_id = p.product_id
LEFT JOIN core.orders o ON o.order_id = i.order_id
GROUP BY c.category_id, c.category_name_pt, c.category_name_en, c.is_translated
HAVING count(i.order_id) FILTER (WHERE o.order_status = 'delivered') > 0
ORDER BY revenue DESC, category;
