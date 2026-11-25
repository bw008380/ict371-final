-- ICT371 Q1 Pharmacy Stock and Daily Sales (PostgreSQL)
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path = q1;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE medicines (
  medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL UNIQUE,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),   -- price at time of sale
  sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE stock_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
  ('Paracetamol 500mg', 2.50, 100),
  ('Amoxicillin 250mg', 8.00, 40),
  ('Ibuprofen 200mg',   4.00, 15);

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_price NUMERIC(10,2);
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be a positive number (got %)', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END $$;

-- (c) Procedure ------------------------------------------------------------
-- The whole CALL is one transaction: any RAISE rolls back both tables.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC(10,2); v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantity must be positive';
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;   -- lock row: no overselling
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_quantity, v_stock;
  END IF;
  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);          -- current price stored
  UPDATE medicines SET stock_qty = stock_qty - p_quantity          -- deducted once
   WHERE medicine_id = p_medicine_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NULL;   -- AFTER trigger: return value ignored
END $$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only real changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) continued: six valid sales loaded through the procedure ---------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1, 5,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 8,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 2,  CURRENT_DATE);
CALL pr_record_sale(3, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 2,  CURRENT_DATE);   -- Ibuprofen stock now 9

-- Invalid sale leaves tables unchanged
DO $$ BEGIN
  CALL pr_record_sale(1, 9999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;
SELECT * FROM medicines ORDER BY medicine_id;   -- unchanged by the failed call
SELECT * FROM stock_audit ORDER BY audit_id;    -- one row per successful sale
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;   -- Ibuprofen (9) appears after the sales

-- (f) Index ----------------------------------------------------------------
-- Equality on medicine_id first, range on sold_on second: the B-tree is
-- searched directly to one medicine's block, then scanned in date order.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;
SET enable_seqscan = off;   -- tiny table: force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
-- Upsert: rerun overwrites the day's row, never adds to it.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);   -- rerun: same totals
SELECT * FROM daily_sales;

-- Daily at 00:15 for the previous day (job needs the schema on its search_path)
SELECT cron.schedule('q1_refresh_sales', '15 0 * * *',
  $$SET search_path = q1, public; CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
