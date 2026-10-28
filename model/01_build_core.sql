-- Типизированная модель и повторно используемые витрины из raw.
-- Выручка: только цена товара в доставленных заказах, без доставки.

-- Проверяем ключи и связи до удаления прежней модели.
DO $$
DECLARE
    rule record;
    has_duplicates boolean;
BEGIN
    FOR rule IN
        SELECT * FROM (VALUES
            ('customers', 'customer_id'),
            ('sellers', 'seller_id'),
            ('products', 'product_id'),
            ('orders', 'order_id'),
            ('order_items', 'order_id, order_item_id'),
            ('order_payments', 'order_id, payment_sequential'),
            ('order_reviews', 'review_id, order_id'),
            ('product_category_translation', 'product_category_name')
        ) AS keys(table_name, key_columns)
    LOOP
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM raw.%I GROUP BY %s HAVING count(*) > 1)',
            rule.table_name, rule.key_columns
        ) INTO has_duplicates;
        IF has_duplicates THEN
            RAISE EXCEPTION 'Дубликат ключа в raw.%: %', rule.table_name, rule.key_columns;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1 FROM raw.orders o
        LEFT JOIN raw.customers c ON c.customer_id = o.customer_id
        WHERE c.customer_id IS NULL
    ) THEN RAISE EXCEPTION 'Заказ без покупателя в raw.orders'; END IF;

    IF EXISTS (
        SELECT 1 FROM raw.order_items i
        LEFT JOIN raw.orders o ON o.order_id = i.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'Позиция без заказа в raw.order_items'; END IF;

    IF EXISTS (
        SELECT 1 FROM raw.order_items i
        LEFT JOIN raw.products p ON p.product_id = i.product_id
        WHERE p.product_id IS NULL
    ) THEN RAISE EXCEPTION 'Позиция без товара в raw.order_items'; END IF;

    IF EXISTS (
        SELECT 1 FROM raw.order_items i
        LEFT JOIN raw.sellers s ON s.seller_id = i.seller_id
        WHERE s.seller_id IS NULL
    ) THEN RAISE EXCEPTION 'Позиция без продавца в raw.order_items'; END IF;

    IF EXISTS (
        SELECT 1 FROM raw.order_payments p
        LEFT JOIN raw.orders o ON o.order_id = p.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'Платёж без заказа в raw.order_payments'; END IF;

    IF EXISTS (
        SELECT 1 FROM raw.order_reviews r
        LEFT JOIN raw.orders o ON o.order_id = r.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'Отзыв без заказа в raw.order_reviews'; END IF;
END $$;

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
    zip_code_prefix text,
    city text,
    state text
);

CREATE TABLE core.sellers (
    seller_id text PRIMARY KEY,
    zip_code_prefix text,
    city text,
    state text
);

CREATE TABLE core.categories (
    category_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_name_pt text UNIQUE,
    category_name_en text NOT NULL,
    is_translated boolean NOT NULL,
    translation_source text NOT NULL CHECK (translation_source IN ('source', 'manual', 'missing')),
    CONSTRAINT categories_name_present CHECK (
        (category_name_pt IS NULL AND category_name_en = 'Non category'
         AND translation_source = 'missing' AND NOT is_translated)
        OR
        (category_name_pt IS NOT NULL AND category_name_en <> 'Non category'
         AND translation_source IN ('source', 'manual') AND is_translated)
    )
);

CREATE UNIQUE INDEX categories_null_name_uq
    ON core.categories ((category_name_pt IS NULL))
    WHERE category_name_pt IS NULL;

CREATE TABLE core.products (
    product_id text PRIMARY KEY,
    category_id bigint NOT NULL REFERENCES core.categories(category_id),
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
    product_id text NOT NULL REFERENCES core.products(product_id),
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
       NULLIF(customer_zip_code_prefix, ''),
       NULLIF(customer_city, ''),
       NULLIF(customer_state, '')
FROM raw.customers;

INSERT INTO core.sellers
SELECT seller_id,
       NULLIF(seller_zip_code_prefix, ''),
       NULLIF(seller_city, ''),
       NULLIF(seller_state, '')
FROM raw.sellers;

-- Сначала переводы источника; два отсутствующих имени дополняем вручную.
-- Если источник позже добавит такой перевод, его запись заменит ручную.
INSERT INTO core.categories (category_name_pt, category_name_en, is_translated, translation_source)
SELECT NULLIF(t.product_category_name, ''),
       NULLIF(t.product_category_name_english, ''),
       true,
       'source'
FROM raw.product_category_translation t
UNION ALL
SELECT m.category_name_pt,
       m.category_name_en,
       true,
       'manual'
FROM (VALUES
    ('pc_gamer', 'gaming_pcs'),
    ('portateis_cozinha_e_preparadores_de_alimentos', 'portable_kitchen_and_food_processors')
) AS m(category_name_pt, category_name_en)
WHERE NOT EXISTS (
    SELECT 1 FROM raw.product_category_translation t
    WHERE t.product_category_name = m.category_name_pt
)
UNION ALL
SELECT NULL, 'Non category', false, 'missing';

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
  ON c.category_name_pt IS NOT DISTINCT FROM NULLIF(p.product_category_name, '');

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
       product_id,
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
           count(*)::integer AS unit_count,
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
       COALESCE(i.unit_count, 0) AS unit_count,
       COALESCE(i.product_revenue, 0)::numeric(14, 2) AS product_revenue,
       COALESCE(i.freight_value, 0)::numeric(14, 2) AS freight_value,
       (COALESCE(i.product_revenue, 0) + COALESCE(i.freight_value, 0))::numeric(14, 2) AS order_value,
       (o.order_status = 'delivered') AS is_revenue_order
FROM core.orders o
JOIN core.customers c ON c.customer_id = o.customer_id
LEFT JOIN item_totals i ON i.order_id = o.order_id;

CREATE VIEW mart.monthly_sales AS
SELECT date_trunc('month', f.purchased_at)::date AS month,
       count(f.order_id) FILTER (WHERE f.is_revenue_order)::integer AS order_count,
       COALESCE(sum(f.product_revenue) FILTER (WHERE f.is_revenue_order), 0)::numeric(14, 2) AS revenue
FROM mart.order_financials f
GROUP BY 1;

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

-- Количество и даты покупок учитывают все оформленные заказы;
-- выручка остаётся только по доставленным.
CREATE VIEW mart.customer_orders AS
SELECT f.customer_unique_id,
       count(*)::integer AS order_count,
       min(f.purchased_at) AS first_order_at,
       max(f.purchased_at) AS last_order_at,
       COALESCE(sum(f.product_revenue) FILTER (WHERE f.is_revenue_order), 0)::numeric(14, 2) AS revenue
FROM mart.order_financials f
GROUP BY f.customer_unique_id;

CREATE VIEW mart.category_sales AS
SELECT c.category_name_en AS category,
       c.category_name_pt,
       c.category_name_en,
       c.is_translated,
       c.translation_source,
       COALESCE(sum(i.price) FILTER (WHERE o.order_status = 'delivered'), 0)::numeric(14, 2) AS revenue,
       CASE
           WHEN COALESCE(sum(sum(i.price) FILTER (WHERE o.order_status = 'delivered')) OVER (), 0) = 0 THEN 0
           ELSE (COALESCE(sum(i.price) FILTER (WHERE o.order_status = 'delivered'), 0)
                 / sum(sum(i.price) FILTER (WHERE o.order_status = 'delivered')) OVER () * 100)::numeric(7, 3)
       END AS revenue_share_pct
FROM core.categories c
LEFT JOIN core.products p ON p.category_id = c.category_id
LEFT JOIN core.order_items i ON i.product_id = p.product_id
LEFT JOIN core.orders o ON o.order_id = i.order_id
GROUP BY c.category_id, c.category_name_pt, c.category_name_en, c.is_translated, c.translation_source
HAVING count(i.order_id) FILTER (WHERE o.order_status = 'delivered') > 0
ORDER BY revenue DESC, category;
