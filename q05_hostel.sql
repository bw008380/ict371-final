-- ICT371 Q5 Hostel Room Allocation (PostgreSQL)
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path = q5;

-- (a) Tables ---------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT ck_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
     OR (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT  NOT NULL,
  free_beds     INT  NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
  ('H001', 'Alice Mwansa'), ('H002', 'Brian Lungu'), ('H003', 'Cynthia Daka'),
  ('H004', 'David Ngoma'),  ('H005', 'Esther Musonda');
INSERT INTO rooms (room_number, capacity) VALUES
  ('R101', 2),   -- will be full
  ('R102', 3),   -- will be partly occupied
  ('R103', 2);   -- will be empty (history only)

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room_id %', p_room_id;
  END IF;
  SELECT COUNT(*) INTO v_active FROM allocations
   WHERE room_id = p_room_id AND status = 'ACTIVE';   -- ENDED rows ignored
  RETURN v_cap - v_active;
END $$;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;   -- serialise allocations per room
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id %', p_room_id; END IF;
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (d) Trigger (guards direct INSERT/UPDATE too) --------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_others INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;  -- lock the room
    -- one ACTIVE allocation per student (exclude the row being updated)
    IF EXISTS (SELECT 1 FROM allocations
                WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                  AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    -- capacity (exclude the row being updated)
    SELECT COUNT(*) INTO v_others FROM allocations
     WHERE room_id = NEW.room_id AND status = 'ACTIVE'
       AND allocation_id IS DISTINCT FROM NEW.allocation_id;
    IF v_others >= v_cap THEN
      RAISE EXCEPTION 'Room % is at capacity (%)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- Seed allocations: full (R101), partly occupied (R102), empty-with-history (R103)
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 20);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 10);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');   -- history only

-- Tests
SELECT fn_free_beds(1) AS r101_full, fn_free_beds(2) AS r102_partly, fn_free_beds(3) AS r103_empty;
DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);      -- room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);      -- student already active
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN                                                  -- direct SQL is blocked too
  INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- (e) View -----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'   -- keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index ----------------------------------------------------------------
-- Partial index holds only ACTIVE rows (history grows forever, active rows
-- are bounded by total beds). Serves fn_free_beds, the trigger and the view.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds::INT, free_beds::INT
  FROM v_room_occupancy                       -- every room, including empty ones
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                  -- rerun replaces values, no duplicate rows
SELECT * FROM occupancy_snapshot ORDER BY room_id;

SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *',
  $$SET search_path = q5, public; CALL pr_refresh_occupancy()$$);
