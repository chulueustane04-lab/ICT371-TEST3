-- (a) START: Create tables and insert data

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month),
    CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INTEGER UNIQUE NOT NULL REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL,
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(12,2) NOT NULL
);

INSERT INTO customers (full_name)
VALUES
('Alice Banda'),
('Brian Phiri'),
('Chanda Zulu');

-- (a) END


-- (b) START: Function

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_charge NUMERIC(12,2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be NULL or negative';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

-- (b) END


-- (c) START: Procedure

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_previous NUMERIC(10,2);
    v_current NUMERIC(10,2);
    v_units NUMERIC(10,2);
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading
    INTO v_previous, v_current
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading not found';
    END IF;

    IF EXISTS (
        SELECT 1 FROM bills
        WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION 'Bill already exists for this reading';
    END IF;

    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    v_units := v_current - v_previous;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills
    (reading_id, charge, amount_paid, due_on)
    VALUES
    (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- (c) END


-- (d) START: Reading validation trigger

CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading cannot be below previous reading';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_reading();

INSERT INTO readings
(customer_id, reading_month, previous_reading, current_reading)
VALUES
(1, DATE '2026-09-01', 100, 100),
(1, DATE '2026-10-01', 100, 110),
(2, DATE '2026-09-01', 200, 215),
(2, DATE '2026-10-01', 215, 225),
(3, DATE '2026-09-01', 300, 318),
(3, DATE '2026-10-01', 318, 320);

CALL pr_generate_bill(1, CURRENT_DATE + 10);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(3, CURRENT_DATE + 10);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- (d) END


-- (e) START: View

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name,
    b.due_on,
    b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (e) END


-- (f) START: Index

CREATE INDEX idx_bills_overdue
ON bills(due_on)
WHERE amount_paid < charge;

EXPLAIN
SELECT *
FROM bills
WHERE due_on < CURRENT_DATE
AND amount_paid < charge;

-- (f) END


-- (g) START: Scheduled job

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot
    (snapshot_date, total_due)
    SELECT
        CURRENT_DATE,
        COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'water_receivables_job',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);

-- (g) END