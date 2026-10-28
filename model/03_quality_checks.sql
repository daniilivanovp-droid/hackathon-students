-- Hard-failing controls for the marketplace model.

DO $$
DECLARE
    actual numeric;
BEGIN
    IF (SELECT count(*) FROM mart.monthly_sales) <> 24 THEN
        RAISE EXCEPTION 'monthly_sales must contain 24 rows';
    END IF;

    SELECT COALESCE(sum(revenue), 0) INTO actual FROM mart.monthly_sales;
    IF actual <> 13221498.11 THEN
        RAISE EXCEPTION 'revenue mismatch: expected 13221498.11, got %', actual;
    END IF;
END $$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM core.order_items
        GROUP BY order_id, order_item_id HAVING count(*) > 1
    ) THEN RAISE EXCEPTION 'duplicate order_items key'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.order_payments
        GROUP BY order_id, payment_sequential HAVING count(*) > 1
    ) THEN RAISE EXCEPTION 'duplicate order_payments key'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.order_reviews
        GROUP BY review_id, order_id HAVING count(*) > 1
    ) THEN RAISE EXCEPTION 'duplicate order_reviews key'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.orders o
        LEFT JOIN core.customers c ON c.customer_id = o.customer_id
        WHERE c.customer_id IS NULL
    ) THEN RAISE EXCEPTION 'orphan order customer'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.order_items i
        LEFT JOIN core.orders o ON o.order_id = i.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'orphan order item'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.order_items i
        LEFT JOIN core.sellers s ON s.seller_id = i.seller_id
        WHERE s.seller_id IS NULL
    ) THEN RAISE EXCEPTION 'orphan order item seller'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.order_payments p
        LEFT JOIN core.orders o ON o.order_id = p.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'orphan payment'; END IF;
    IF EXISTS (
        SELECT 1 FROM core.order_reviews r
        LEFT JOIN core.orders o ON o.order_id = r.order_id
        WHERE o.order_id IS NULL
    ) THEN RAISE EXCEPTION 'orphan review'; END IF;
END $$;

DO $$
DECLARE
    expected text[][] := ARRAY[
        ['customers', '99441'],
        ['sellers', '3095'],
        ['products', '32951'],
        ['orders', '99441'],
        ['order_items', '112650'],
        ['order_payments', '103886'],
        ['order_reviews', '99224']
    ];
    item text[];
    actual bigint;
BEGIN
    FOREACH item SLICE 1 IN ARRAY expected LOOP
        EXECUTE format('SELECT count(*) FROM core.%I', item[1]) INTO actual;
        IF actual <> item[2]::bigint THEN
            RAISE EXCEPTION 'row count mismatch for %: expected %, got %', item[1], item[2], actual;
        END IF;
    END LOOP;
END $$;
