-- (a) START: Create tables and insert data

CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL,
    weight_kg NUMERIC(10,2) NOT NULL,
    unit_rate NUMERIC(10,2),
    total_value NUMERIC(12,2),
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(12,2) NOT NULL,
    total_value NUMERIC(12,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name)
VALUES
('F001', 'Alice Banda'),
('F002', 'Brian Phiri'),
('F003', 'Chanda Zulu');

-- (a) END


-- (b) START: Function

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE UPPER(p_grade)
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported maize grade';
    END CASE;
END;
$$;

-- (b) END


-- (c) START: Procedure

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade CHAR(1),
    p_weight NUMERIC(10,2),
    p_date DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM farmers
        WHERE farmer_id = p_farmer_id
    ) THEN
        RAISE EXCEPTION 'Farmer not found';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 OR p_date IS NULL THEN
        RAISE EXCEPTION 'Invalid delivery details';
    END IF;

    PERFORM fn_maize_rate(p_grade);

    INSERT INTO deliveries
    (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES
    (p_farmer_id, UPPER(p_grade), p_weight, p_date, FALSE);
END;
$$;

-- (c) END


-- (d) START: Pricing trigger

CREATE OR REPLACE FUNCTION fn_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight must be positive';
    END IF;

    NEW.unit_rate := fn_maize_rate(NEW.grade);
    NEW.total_value := NEW.weight_kg * NEW.unit_rate;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_calculate_delivery_value
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_value();

CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 150, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'A', 120, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 180, CURRENT_DATE);
CALL pr_receive_delivery(3, 'C', 90, CURRENT_DATE);

UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id IN (1, 3, 5);

-- (d) END


-- (e) START: View

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(
        CASE WHEN d.is_paid = FALSE
        THEN d.total_value
        ELSE 0 END
    ), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d
ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- (e) END


-- (f) START: Index

CREATE INDEX idx_deliveries_farmer_date
ON deliveries(farmer_id, delivered_on);

EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (f) END


-- (g) START: Scheduled job

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases
    (purchase_date, total_weight, total_value)
    SELECT
        p_day,
        COALESCE(SUM(weight_kg), 0),
        COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'daily_maize_purchases_job',
    '30 1 * * *',
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$
);

-- (g) END