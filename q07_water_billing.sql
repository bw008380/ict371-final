-- ICT371 Q7 Water Meter Readings and Billing (PostgreSQL)
DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path = q7;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE customers (
  customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
  bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(10,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(14,2) NOT NULL
);

-- (d) Trigger first, so seed readings are validated too ---------------------------
CREATE OR REPLACE FUNCTION trg_fn_reading_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                    NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;          -- raising aborts the statement, so nothing is stored
END $$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_reading_check();

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10,2) LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Consumption must be a non-negative number (got %)', p_units;
  END IF;
  -- first 10 units at K5, units above 10 at K8; zero units -> 0
  RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2)::NUMERIC(10,2);
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN
    RAISE EXCEPTION 'Due date is required';
  END IF;
  SELECT current_reading - previous_reading INTO v_units
    FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
  END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END $$;

-- (a) continued: three customers, six readings (units 0, 10, 15, 4, 30, 10) ---------
INSERT INTO customers (full_name) VALUES ('Joseph Mbewe'), ('Mary Yamba'), ('Lameck Zimba');
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
  (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 100,  100),  -- 1: 0 units
  (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  100,  110),  -- 2: exactly 10
  (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,  50,   65),  -- 3: 15 units
  (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   65,   69),  -- 4: 4 units
  (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,   0,   30),  -- 5: 30 units
  (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   30,   40);  -- 6: exactly 10

SELECT fn_water_charge(0) a, fn_water_charge(10) b, fn_water_charge(15) c, fn_water_charge(30) d;
-- 0.00, 50.00, 90.00, 210.00

-- bills: older month overdue, recent month not yet due
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 10);
UPDATE bills SET amount_paid = 50 WHERE reading_id = 3;   -- part payment of K90

-- Tests
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);          -- duplicate bill
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);        -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN                                                   -- trigger rejects bad import
  INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
  VALUES (1, date_trunc('month', CURRENT_DATE)::date, 200, 150);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_stored FROM readings;             -- still 6

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Index ----------------------------------------------------------------
-- Partial index on due_on covering only unpaid bills. Settled bills (the vast
-- majority over time) are excluded, so the index stays small and a
-- "due_on < today" search reads only candidate overdue rows.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();      -- rerun replaces today's total
SELECT * FROM receivable_snapshot;

SELECT cron.schedule('q7_refresh_receivables', '30 0 * * *',
  $$SET search_path = q7, public; CALL pr_refresh_receivables()$$);
