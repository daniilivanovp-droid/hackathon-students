-- Проверки запускаются после сборки core и mart, до фиксации транзакции.
-- Любое расхождение останавливает psql и откатывает новую модель.

DO $$
DECLARE
    t record;
    raw_rows bigint;
    core_rows bigint;
BEGIN
    FOR t IN
        SELECT * FROM (VALUES
            ('customers', 99441::bigint),
            ('sellers', 3095::bigint),
            ('products', 32951::bigint),
            ('orders', 99441::bigint),
            ('order_items', 112650::bigint),
            ('order_payments', 103886::bigint),
            ('order_reviews', 99224::bigint)
        ) AS expected(table_name, row_count)
    LOOP
        EXECUTE format('SELECT count(*) FROM raw.%I', t.table_name) INTO raw_rows;
        IF raw_rows <> t.row_count THEN
            RAISE EXCEPTION 'raw.%: ожидалось % строк, найдено %',
                t.table_name, t.row_count, raw_rows;
        END IF;

        EXECUTE format('SELECT count(*) FROM core.%I', t.table_name) INTO core_rows;
        IF core_rows <> raw_rows THEN
            RAISE EXCEPTION 'core.%: % строк против % в raw',
                t.table_name, core_rows, raw_rows;
        END IF;
    END LOOP;

    SELECT count(*) INTO raw_rows FROM raw.product_category_translation;
    IF raw_rows <> 71 THEN
        RAISE EXCEPTION 'raw.product_category_translation: ожидалось 71 строка, найдено %',
            raw_rows;
    END IF;
END $$;

DO $$
BEGIN
    -- Источники не должны содержать повторов естественных ключей.
    IF EXISTS (SELECT 1 FROM raw.customers GROUP BY customer_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM raw.customers WHERE NULLIF(customer_id, '') IS NULL) THEN
        RAISE EXCEPTION 'raw.customers: пустой или повторный customer_id';
    END IF;
    IF EXISTS (SELECT 1 FROM raw.sellers GROUP BY seller_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM raw.sellers WHERE NULLIF(seller_id, '') IS NULL) THEN
        RAISE EXCEPTION 'raw.sellers: пустой или повторный seller_id';
    END IF;
    IF EXISTS (SELECT 1 FROM raw.products GROUP BY product_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM raw.products WHERE NULLIF(product_id, '') IS NULL) THEN
        RAISE EXCEPTION 'raw.products: пустой или повторный product_id';
    END IF;
    IF EXISTS (SELECT 1 FROM raw.orders GROUP BY order_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM raw.orders WHERE NULLIF(order_id, '') IS NULL) THEN
        RAISE EXCEPTION 'raw.orders: пустой или повторный order_id';
    END IF;
    IF EXISTS (
        SELECT 1 FROM raw.order_items
        GROUP BY order_id, order_item_id HAVING count(*) > 1
    ) OR EXISTS (
        SELECT 1 FROM raw.order_items
        WHERE NULLIF(order_id, '') IS NULL OR NULLIF(order_item_id, '') IS NULL
    ) THEN
        RAISE EXCEPTION 'raw.order_items: пустой или повторный (order_id, order_item_id)';
    END IF;
    IF EXISTS (
        SELECT 1 FROM raw.order_payments
        GROUP BY order_id, payment_sequential HAVING count(*) > 1
    ) OR EXISTS (
        SELECT 1 FROM raw.order_payments
        WHERE NULLIF(order_id, '') IS NULL OR NULLIF(payment_sequential, '') IS NULL
    ) THEN
        RAISE EXCEPTION 'raw.order_payments: пустой или повторный (order_id, payment_sequential)';
    END IF;
    IF EXISTS (
        SELECT 1 FROM raw.order_reviews
        GROUP BY review_id, order_id HAVING count(*) > 1
    ) OR EXISTS (
        SELECT 1 FROM raw.order_reviews
        WHERE NULLIF(review_id, '') IS NULL OR NULLIF(order_id, '') IS NULL
    ) THEN
        RAISE EXCEPTION 'raw.order_reviews: пустой или повторный (review_id, order_id)';
    END IF;
    IF EXISTS (
        SELECT 1 FROM raw.product_category_translation
        GROUP BY product_category_name HAVING count(*) > 1
    ) OR EXISTS (
        SELECT 1 FROM raw.product_category_translation
        WHERE NULLIF(product_category_name, '') IS NULL
    ) THEN
        RAISE EXCEPTION 'raw.product_category_translation: пустой или повторный ключ категории';
    END IF;
END $$;

DO $$
BEGIN
    -- Внешние ключи core служат первой защитой; эти проверки объясняют
    -- конкретную потерянную связь и состояние витрин.
    IF EXISTS (
        SELECT 1 FROM core.orders o
        LEFT JOIN core.customers c ON c.customer_id = o.customer_id
        WHERE c.customer_id IS NULL
    ) THEN RAISE EXCEPTION 'заказ без покупателя'; END IF;

    IF EXISTS (
        SELECT 1 FROM core.order_items i
        LEFT JOIN core.orders o ON o.order_id = i.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'позиция без заказа'; END IF;

    IF EXISTS (
        SELECT 1 FROM core.order_items i
        LEFT JOIN core.products p ON p.product_id = i.product_id
        WHERE p.product_id IS NULL
    ) THEN RAISE EXCEPTION 'позиция без товара'; END IF;

    IF EXISTS (
        SELECT 1 FROM core.order_items i
        LEFT JOIN core.sellers s ON s.seller_id = i.seller_id
        WHERE s.seller_id IS NULL
    ) THEN RAISE EXCEPTION 'позиция без продавца'; END IF;

    IF EXISTS (
        SELECT 1 FROM core.products p
        LEFT JOIN core.categories c ON c.category_id = p.category_id
        WHERE c.category_id IS NULL
    ) THEN RAISE EXCEPTION 'товар без категории'; END IF;

    IF EXISTS (
        SELECT 1 FROM core.order_payments p
        LEFT JOIN core.orders o ON o.order_id = p.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'платёж без заказа'; END IF;

    IF EXISTS (
        SELECT 1 FROM core.order_reviews r
        LEFT JOIN core.orders o ON o.order_id = r.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'отзыв без заказа'; END IF;

    IF EXISTS (
        SELECT 1 FROM raw.product_category_translation t
        LEFT JOIN core.categories c
          ON c.category_name_pt = t.product_category_name
        WHERE c.category_id IS NULL
           OR c.category_name_en IS DISTINCT FROM t.product_category_name_english
           OR c.translation_source IS DISTINCT FROM 'source'
    ) THEN
        RAISE EXCEPTION 'переводы исходного справочника не полностью сохранены';
    END IF;

    IF EXISTS (
        SELECT 1 FROM (VALUES
            ('pc_gamer', 'gaming_pcs'),
            ('portateis_cozinha_e_preparadores_de_alimentos',
             'portable_kitchen_and_food_processors')
        ) AS manual(category_name_pt, category_name_en)
        LEFT JOIN raw.product_category_translation t
          ON t.product_category_name = manual.category_name_pt
        LEFT JOIN core.categories c
          ON c.category_name_pt = manual.category_name_pt
        WHERE t.product_category_name IS NULL
          AND (c.category_id IS NULL
               OR c.category_name_en IS DISTINCT FROM manual.category_name_en
               OR c.translation_source IS DISTINCT FROM 'manual')
    ) THEN
        RAISE EXCEPTION 'ручные английские названия категорий отсутствуют';
    END IF;

    IF (SELECT count(*) FROM core.categories
        WHERE category_name_pt IS NULL
          AND category_name_en = 'Non category'
          AND translation_source = 'missing') <> 1 THEN
        RAISE EXCEPTION 'категория Non category должна быть ровно одна';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM raw.products r
        JOIN core.products p ON p.product_id = r.product_id
        JOIN core.categories c ON c.category_id = p.category_id
        WHERE (NULLIF(r.product_category_name, '') IS NULL
               AND c.translation_source <> 'missing')
           OR (NULLIF(r.product_category_name, '') IS NOT NULL
               AND c.category_name_pt IS DISTINCT FROM r.product_category_name)
    ) THEN
        RAISE EXCEPTION 'товар отнесён не к своей исходной категории';
    END IF;

    IF EXISTS (SELECT 1 FROM core.order_reviews
               WHERE review_score IS NOT NULL
                 AND review_score NOT BETWEEN 1 AND 5) THEN
        RAISE EXCEPTION 'оценка отзыва вне диапазона 1–5';
    END IF;
END $$;

DO $$
DECLARE
    item_revenue numeric;
    financial_revenue numeric;
    monthly_revenue numeric;
    seller_revenue numeric;
    category_revenue numeric;
BEGIN
    IF (SELECT count(*) FROM mart.order_financials)
       <> (SELECT count(*) FROM core.orders)
       OR EXISTS (
           SELECT 1 FROM mart.order_financials
           GROUP BY order_id HAVING count(*) > 1
       ) THEN
        RAISE EXCEPTION 'mart.order_financials: должно быть по одной строке на заказ';
    END IF;

    IF EXISTS (
        SELECT 1 FROM mart.order_financials
        WHERE unit_count <> item_count
    ) THEN
        RAISE EXCEPTION 'число единиц товара не равно числу позиций';
    END IF;

    IF EXISTS (
        (SELECT date_trunc('month', purchased_at)::date AS month FROM core.orders
         EXCEPT SELECT month FROM mart.monthly_sales)
        UNION ALL
        (SELECT month FROM mart.monthly_sales
         EXCEPT SELECT date_trunc('month', purchased_at)::date FROM core.orders)
    ) OR EXISTS (
        SELECT 1 FROM mart.monthly_sales
        GROUP BY month HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'mart.monthly_sales: месяцы не совпадают с заказами';
    END IF;

    SELECT COALESCE(sum(i.price), 0) INTO item_revenue
    FROM core.order_items i
    JOIN core.orders o ON o.order_id = i.order_id
    WHERE o.order_status = 'delivered';

    SELECT COALESCE(sum(product_revenue), 0) INTO financial_revenue
    FROM mart.order_financials WHERE is_revenue_order;
    SELECT COALESCE(sum(revenue), 0) INTO monthly_revenue FROM mart.monthly_sales;
    SELECT COALESCE(sum(revenue), 0) INTO seller_revenue FROM mart.seller_sales;
    SELECT COALESCE(sum(revenue), 0) INTO category_revenue FROM mart.category_sales;

    IF item_revenue <> financial_revenue
       OR item_revenue <> monthly_revenue
       OR item_revenue <> seller_revenue
       OR item_revenue <> category_revenue THEN
        RAISE EXCEPTION
            'выручка не сходится: позиции %, заказы %, месяцы %, продавцы %, категории %',
            item_revenue, financial_revenue, monthly_revenue,
            seller_revenue, category_revenue;
    END IF;
END $$;

DO $$
DECLARE
    report_rows bigint;
    zero_months bigint;
    report_revenue numeric;
    actual numeric;
    customers_count bigint;
    repeat_customers bigint;
    repeat_percent numeric;
    categories_count bigint;
BEGIN
    WITH months AS (
        SELECT generate_series(date '2016-09-01',
                               date '2018-08-01',
                               interval '1 month')::date AS month
    ), report AS (
        SELECT m.month, COALESCE(s.order_count, 0) AS order_count,
               COALESCE(s.revenue, 0) AS revenue
        FROM months m
        LEFT JOIN mart.monthly_sales s ON s.month = m.month
    )
    SELECT count(*), count(*) FILTER (WHERE revenue = 0), sum(revenue)
      INTO report_rows, zero_months, report_revenue
    FROM report;
    IF report_rows <> 24 OR zero_months <> 1
       OR report_revenue <> 13221498.11 THEN
        RAISE EXCEPTION
            'месячный отчёт: строк %, нулевых месяцев %, выручка %',
            report_rows, zero_months, report_revenue;
    END IF;

    SELECT revenue INTO actual
    FROM mart.seller_sales
    ORDER BY revenue DESC, seller_id
    LIMIT 1;
    IF actual IS DISTINCT FROM 226987.93 THEN
        RAISE EXCEPTION 'выручка ведущего продавца: ожидалось 226987.93, найдено %',
            actual;
    END IF;

    SELECT round(avg(order_value), 2) INTO actual
    FROM mart.order_financials
    WHERE is_revenue_order;
    IF actual IS DISTINCT FROM 159.88 THEN
        RAISE EXCEPTION 'средний чек: ожидалось 159.88, найдено %', actual;
    END IF;

    SELECT count(*),
           count(*) FILTER (WHERE order_count >= 2),
           round(100.0 * count(*) FILTER (WHERE order_count >= 2)
                 / NULLIF(count(*), 0), 2)
      INTO customers_count, repeat_customers, repeat_percent
    FROM mart.customer_orders
    WHERE order_count > 0;
    IF customers_count <> 96096 OR repeat_customers <> 2997
       OR repeat_percent IS DISTINCT FROM 3.12 THEN
        RAISE EXCEPTION
            'покупатели: ожидалось 96096 и 2997 повторных (3.12 процента), найдено %, % и %',
            customers_count, repeat_customers, repeat_percent;
    END IF;

    SELECT count(*), max(revenue) INTO categories_count, actual
    FROM mart.category_sales;
    IF categories_count <> 74 OR actual IS DISTINCT FROM 1233131.72 THEN
        RAISE EXCEPTION
            'категории: ожидалось 74 и максимум 1233131.72, найдено % и %',
            categories_count, actual;
    END IF;
END $$;
