-- (a) START: Create tables and insert data

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(100) NOT NULL
);

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) DEFAULT 0,
    CHECK (due_on >= borrowed_on),
    CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL,
    total_fine NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title)
VALUES
('Database Systems'),
('Computer Networks'),
('Operating Systems');

INSERT INTO loans
(book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount)
VALUES
(1, 'Alice Banda', CURRENT_DATE - 20, CURRENT_DATE - 10, NULL, 0),
(2, 'Brian Phiri', CURRENT_DATE - 15, CURRENT_DATE - 5, CURRENT_DATE - 5, 0),
(3, 'Chanda Zulu', CURRENT_DATE - 12, CURRENT_DATE - 7, CURRENT_DATE - 3, 8),
(1, 'David Tembo', CURRENT_DATE - 8, CURRENT_DATE + 2, NULL, 0),
(2, 'Esther Zulu', CURRENT_DATE - 10, CURRENT_DATE - 2, NULL, 0),
(3, 'Felix Musonda', CURRENT_DATE - 5, CURRENT_DATE + 5, NULL, 0);

-- (a) END


-- (b) START: Function

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_due DATE;
    v_returned DATE;
    v_end_date DATE;
BEGIN
    SELECT due_on, returned_on
    INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan not found';
    END IF;

    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Date cannot be NULL';
    END IF;

    v_end_date := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN GREATEST(v_end_date - v_due, 0) * 2.00;
END;
$$;

-- (b) END


-- (c) START: Procedure

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine NUMERIC(10,2);
BEGIN
    SELECT borrowed_on, returned_on
    INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan not found';
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan has already been returned';
    END IF;

    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Invalid return date';
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (c) END


-- (d) START: Audit trigger

CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit
        (loan_id, old_returned_on, new_returned_on)
        VALUES
        (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_loan_audit();

CALL pr_return_loan(2, CURRENT_DATE);
CALL pr_return_loan(4, CURRENT_DATE);
CALL pr_return_loan(5, CURRENT_DATE);

-- (d) END


-- (e) START: View

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (e) END


-- (f) START: Index

CREATE INDEX idx_loans_unreturned_book
ON loans(book_id)
WHERE returned_on IS NULL;

EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
AND returned_on IS NULL;

-- (f) END


-- (g) START: Scheduled job

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary
    (snapshot_date, overdue_count, total_fine)
    SELECT
        p_as_of,
        COUNT(*)::INTEGER,
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE returned_on IS NULL
    AND due_on < p_as_of
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'library_overdue_job',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);

-- (g) END