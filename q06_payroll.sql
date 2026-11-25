-- ICT371 Q6 Monthly Payroll Processing (PostgreSQL)
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path = q6;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first day of month
  gross_pay   NUMERIC(12,2) NOT NULL,
  net_pay     NUMERIC(12,2) NOT NULL,
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_basic NUMERIC; v_allow NUMERIC; v_ded NUMERIC; v_net NUMERIC;
BEGIN
  SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
    FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
  END IF;
  v_net := v_basic + v_allow - v_ded;          -- gross minus fixed deduction
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- (c) Procedure ------------------------------------------------------------
-- A raised exception aborts the whole CALL, so no partial month is stored.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);        -- fails the whole call if invalid
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NULL;
END $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- (a) continued: seed data for two payroll months ---------------------------------
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
  ('Alice Kapata', 5000, 500, 300, TRUE),
  ('Bob Simwanza', 4000, 400, 250, TRUE),
  ('Carol Mulenga', 3000, 200, 150, TRUE),
  ('Dan Chola',     2500, 100, 100, TRUE);

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);  -- month 1

UPDATE employees SET basic_salary = 4500 WHERE employee_id = 2;   -- audited
UPDATE employees SET basic_salary = 4500 WHERE employee_id = 2;   -- unchanged: no audit row
UPDATE employees SET active = FALSE WHERE employee_id = 4;        -- Dan leaves

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);   -- month 2
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);   -- rerun: no change

SELECT * FROM salary_audit;                       -- exactly one row
SELECT * FROM payroll ORDER BY pay_month, employee_id;   -- Dan only in month 1
DO $$ BEGIN CALL pr_process_payroll(CURRENT_DATE + 1);   -- not a month start (unless 1st: adjust)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
-- No filter on employees.active, so history of later-inactive staff remains.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index ----------------------------------------------------------------
-- The unique index (employee_id, pay_month) leads with employee_id, so it cannot
-- efficiently serve "all employees for one month". An index on pay_month alone
-- has a different leading column, so it does not duplicate it.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll
WHERE pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st of each month, for the previous month ------
SELECT cron.schedule('q6_process_payroll', '0 2 1 * *',
  $$SET search_path = q6, public;
    CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_process_payroll';
SELECT d.jobid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_process_payroll'
ORDER BY d.start_time DESC;
