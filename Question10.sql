-- (a) START: Create tables and insert data

CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(10),
    new_status VARCHAR(10),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name)
VALUES
('ST001', 'Alice Banda'),
('ST002', 'Brian Phiri'),
('ST003', 'Chanda Zulu');

INSERT INTO applications
(student_id, age_at_application, monthly_income, average_mark, submitted_on)
VALUES
(1, 20, 2500, 80, CURRENT_DATE - 6),
(1, 18, 3000, 70, CURRENT_DATE - 5),
(2, 26, 2000, 85, CURRENT_DATE - 4),
(2, 22, 3500, 90, CURRENT_DATE - 3),
(3, 24, 2800, 65, CURRENT_DATE - 2),
(3, 25, 3000, 75, CURRENT_DATE - 1);

-- (a) END


-- (b) START: Function

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;

    IF p_age <= 0 OR p_income < 0 OR p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid application values';
    END IF;

    RETURN
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70;
END;
$$;

-- (b) END


-- (c) START: Assessment procedure

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_age INTEGER;
    v_income NUMERIC(10,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(10);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application not found';
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application has already been assessed';
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    IF v_eligible THEN
        UPDATE applications
        SET status = 'APPROVED'
        WHERE application_id = p_application_id;
    ELSE
        UPDATE applications
        SET status = 'REJECTED'
        WHERE application_id = p_application_id;
    END IF;
END;
$$;

-- (c) END


-- (d) START: Audit trigger

CREATE OR REPLACE FUNCTION fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO decision_audit
        (application_id, old_status, new_status)
        VALUES
        (NEW.application_id, OLD.status, NEW.status);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_decision_audit();

CALL pr_assess_application(1);
CALL pr_assess_application(2);
CALL pr_assess_application(3);
CALL pr_assess_application(4);
CALL pr_assess_application(5);
CALL pr_assess_application(6);

-- (d) END


-- (e) START: View

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s
ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (e) END


-- (f) START: Index

CREATE INDEX idx_applications_status_date
ON applications(status, submitted_on);

EXPLAIN
SELECT *
FROM applications
WHERE status = 'APPROVED'
AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (f) END


-- (g) START: Scheduled job

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    app RECORD;
BEGIN
    FOR app IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(app.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'scholarship_assessment_job',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);

-- (g) END