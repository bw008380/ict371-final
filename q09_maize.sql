-- ICT371 Q9 Farmer Cooperative Maize Deliveries (PostgreSQL)
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path = q9;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE farmers (
  farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
  weight_kg    NUMERIC(10,2) NOT NULL,
  unit_rate    NUMERIC(10,2) NOT NULL,      -- set by trigger
  total_value  NUMERIC(14,2) NOT NULL,      -- set by trigger
  delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(14,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
  ('F001', 'Mwape Chisenga'), ('F002', 'Bwalya Kasonde'), ('F003', 'Natasha Lombe');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_rate NUMERIC;
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade is required';
  END IF;
  v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'Unsupported grade "%"; use A, B or C', p_grade;
  END IF;
  RETURN v_rate;
END $$;

-- (d) Trigger (installed before any delivery is loaded) -----------------------
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);           -- caller-supplied values are overridden
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_delivery_pricing();

-- (c) Procedure ------------------------------------------------------------
-- Inserts only the basic fields; the trigger fills unit_rate and total_value.
-- (The NOT NULL checks run after BEFORE triggers, so omitting them is valid.)
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date is required';
  END IF;
  PERFORM fn_maize_rate(p_grade);                        -- rejects NULL / unsupported grade early
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
  END IF;
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (a) continued: six deliveries covering all grades and both payment states ---------
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'B',  80, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 120, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A',  50, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'B',  60, CURRENT_DATE - 2);
-- direct SQL: trigger still applies the pricing rule (supplied rate/value ignored)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'C', 40, 999, 0, CURRENT_DATE - 2, FALSE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 4, 6);   -- both states present

SELECT delivery_id, grade, weight_kg, unit_rate, total_value, is_paid FROM deliveries ORDER BY 1;
SELECT fn_maize_rate('A') a, fn_maize_rate('B') b, fn_maize_rate('C') c;
DO $$ BEGIN CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);      -- bad grade
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);      -- bad weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(77, 'A', 5, CURRENT_DATE);      -- unknown farmer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id     -- keeps farmers with no unpaid rows
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index ----------------------------------------------------------------
-- farmer_id (equality) then delivered_on (range) for "this farmer between two dates".
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE                 -- replace, never add on top
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);            -- rerun: same totals
SELECT * FROM daily_purchases;

SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *',
  $$SET search_path = q9, public; CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
