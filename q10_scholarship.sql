-- ICT371 Q10 Scholarship Application Assessment (PostgreSQL)
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path = q10;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
  ('SC001', 'Anna Mutemwa'), ('SC002', 'Boniface Sichone'), ('SC003', 'Catherine Njovu');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark are all required';
  END IF;
  IF p_age <= 0 THEN
    RAISE EXCEPTION 'Age must be positive (got %)', p_age;
  END IF;
  IF p_income < 0 THEN
    RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
  END IF;
  IF p_mark < 0 OR p_mark > 100 THEN
    RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
  END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_app applications%ROWTYPE;
BEGIN
  SELECT * INTO v_app FROM applications
   WHERE application_id = p_application_id FOR UPDATE;      -- no double assessment
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Application % does not exist', p_application_id;
  END IF;
  IF v_app.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_app.status;
  END IF;
  UPDATE applications
     SET status = CASE WHEN fn_scholarship_eligible(v_app.age_at_application,
                                                    v_app.monthly_income,
                                                    v_app.average_mark)
                       THEN 'APPROVED' ELSE 'REJECTED' END
   WHERE application_id = p_application_id;
END $$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NULL;
END $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (a) continued: six PENDING applications (ids 1..6) --------------------------------
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
  (1, 22, 2500.00, 85.00, CURRENT_DATE - 10),   -- 1 qualifies
  (1, 18, 3000.00, 70.00, CURRENT_DATE - 9),    -- 2 boundary: all minimums -> qualifies
  (2, 25, 3000.00, 75.00, CURRENT_DATE - 8),    -- 3 boundary: max age and income -> qualifies
  (2, 17, 1000.00, 90.00, CURRENT_DATE - 7),    -- 4 too young
  (3, 21, 3000.01, 88.00, CURRENT_DATE - 6),    -- 5 income just over
  (3, 20, 1500.00, 69.99, CURRENT_DATE - 5);    -- 6 mark just under

SELECT fn_scholarship_eligible(20, 2000, 80) AS yes, fn_scholarship_eligible(26, 2000, 80) AS no;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 100, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_application(1);
DO $$ BEGIN CALL pr_assess_application(1);       -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);     -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (g) Batch procedure (query FOR loop, PENDING only) --------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications
            WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;

CALL pr_assess_pending();
CALL pr_assess_pending();     -- rerun: nothing PENDING, so no reassessment and no new audit rows

SELECT application_id, status FROM applications ORDER BY 1;   -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;               -- exactly six rows

-- (e) View -----------------------------------------------------------------
-- Omits monthly_income and other applicant data.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (f) Index ----------------------------------------------------------------
-- status (equality) then submitted_on (range): status-filtered date-range reports
-- and the PENDING scan are served by one index range.
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'APPROVED' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- Schedule: every Monday at 08:00
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1',
  $$SET search_path = q10, public; CALL pr_assess_pending()$$);
