-- ICT371 Q2 University Fee Payments (PostgreSQL)
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path = q2;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE payment_audit (
  audit_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL,
  total_amount    NUMERIC(14,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
  ('S001', 'Chanda Mwila',   5000.00),
  ('S002', 'Mutale Banda',   3000.00),
  ('S003', 'Thandiwe Phiri', 2500.00);   -- S003 has no payments initially

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_fee NUMERIC(12,2); v_paid NUMERIC(14,2);
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;      -- full fee when there are no payments
END $$;

-- (c) Procedure (does NOT write the audit row; the trigger does) -------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise per student
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student_id %', p_student_id;
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NULL;
END $$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_fn_payment_audit();

-- (a) continued: six payments via the procedure ------------------------------
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 2);
CALL pr_receive_payment(2,  500, CURRENT_DATE - 1);

SELECT fn_fee_balance(1) AS s1, fn_fee_balance(2) AS s2, fn_fee_balance(3) AS s3_no_payments;
DO $$ BEGIN CALL pr_receive_payment(3, 99999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM payment_audit ORDER BY audit_id;   -- six rows, written by the trigger

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;     -- settled students excluded

SELECT * FROM v_fee_balances;

-- (f) Index ----------------------------------------------------------------
-- student_id (equality) first, paid_on (range) second: one contiguous index
-- range answers "this student's payments between two dates", already ordered.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 5 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM daily_collections;

SELECT cron.schedule('q2_refresh_collections', '0 1 * * *',
  $$SET search_path = q2, public; CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
