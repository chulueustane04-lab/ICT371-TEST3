-- (a) START: Create tables and insert data

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(10,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(10,2) NOT NULL CHECK (amount > 0),
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(10,2) NOT NULL,
    logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due)
VALUES
('STU001', 'Alice Banda', 5000),
('STU002', 'Brian Phiri', 4200),
('STU003', 'Chanda Zulu', 3500);

-- (a) END


-- (b) START: Function

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_fee NUMERIC(10,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student ID';
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- (b) END


-- (c) START: Payment procedure

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(10,2),
    p_paid_on DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 OR p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Invalid payment amount or date';
    END IF;

    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student not found';
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment exceeds outstanding balance';
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (c) END


-- (d) START: Audit trigger

CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payment_audit
        (payment_id, student_id, amount, logged_at)
    VALUES
        (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();

CALL pr_receive_payment(1, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 700, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 300, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 250, CURRENT_DATE);
CALL pr_receive_payment(2, 450, CURRENT_DATE);

-- (d) END


-- (e) START: View

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p
ON p.student_id = s.student_id
GROUP BY
    s.student_id,
    s.student_number,
    s.full_name,
    s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;

-- (e) END


-- (f) START: Index

CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on);

EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
AND paid_on >= DATE '2026-01-01'
AND paid_on < DATE '2027-01-01';

-- (f) END


-- (g) START: Daily collections and schedule

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections
        (collection_date, payment_count, total_amount)
    SELECT
        p_day,
        COUNT(*)::INTEGER,
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371_daily_fee_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$
);

-- (g) END