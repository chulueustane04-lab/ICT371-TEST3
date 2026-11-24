-- (a) START: Create tables and insert data

CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL
);

CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL,
    gross_pay NUMERIC(12,2) NOT NULL,
    net_pay NUMERIC(12,2) NOT NULL,
    UNIQUE (employee_id, pay_month),
    CHECK (EXTRACT(DAY FROM pay_month) = 1)
);

CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2),
    new_salary NUMERIC(12,2),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees
(full_name, basic_salary, allowance, deduction, active)
VALUES
('Alice Banda', 5000, 500, 300, TRUE),
('Brian Phiri', 4500, 400, 250, TRUE),
('Chanda Zulu', 6000, 600, 400, TRUE),
('David Tembo', 3500, 300, 200, FALSE);

-- (a) END


-- (b) START: Function

CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee not found';
    END IF;

    v_net := v_basic + v_allowance - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay cannot be negative';
    END IF;

    RETURN v_net;
END;
$$;

-- (b) END


-- (c) START: Procedure

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    emp RECORD;
    v_net NUMERIC(12,2);
    v_gross NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Pay month must be the first day of a month';
    END IF;

    FOR emp IN
        SELECT *
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(emp.employee_id);
        v_gross := emp.basic_salary + emp.allowance;

        INSERT INTO payroll
        (employee_id, pay_month, gross_pay, net_pay)
        VALUES
        (emp.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

CALL pr_process_payroll(DATE '2026-10-01');
CALL pr_process_payroll(DATE '2026-11-01');

-- (c) END


-- (d) START: Audit trigger

CREATE OR REPLACE FUNCTION fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN
        INSERT INTO salary_audit
        (employee_id, old_salary, new_salary)
        VALUES
        (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_salary_audit();

-- (d) END


-- (e) START: View

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e
ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report;

-- (e) END


-- (f) START: Index

CREATE INDEX idx_payroll_month
ON payroll(pay_month);

EXPLAIN
SELECT *
FROM payroll
WHERE pay_month = DATE '2026-11-01';

-- (f) END


-- (g) START: Scheduled job

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'monthly_payroll_job',
    '0 2 1 * *',
    $$CALL pr_process_payroll(
        (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::DATE
    );$$
);

SELECT * FROM cron.job
WHERE jobname = 'monthly_payroll_job';

SELECT *
FROM cron.job_run_details
WHERE jobid = (
    SELECT jobid FROM cron.job
    WHERE jobname = 'monthly_payroll_job'
)
ORDER BY start_time DESC;

-- (g) END