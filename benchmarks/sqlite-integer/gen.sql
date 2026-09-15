-- Data generator for the AN-encoding SQLite benchmark.
-- Pure-integer data only (build is compiled with -DSQLITE_OMIT_FLOATING_POINT):
-- every value is a 64-bit integer or short text; no reals anywhere.
-- Row count is injected by setup.sh via the __N__ placeholder.

PRAGMA journal_mode = MEMORY;
PRAGMA synchronous  = OFF;

DROP TABLE IF EXISTS big;
DROP TABLE IF EXISTS dim;

-- Small dimension table for the join (1000 groups).
CREATE TABLE dim(g INTEGER PRIMARY KEY, name TEXT);
INSERT INTO dim(g, name)
WITH RECURSIVE d(g) AS (
  SELECT 0 UNION ALL SELECT g+1 FROM d WHERE g < 999
)
SELECT g, 'group_' || g FROM d;

-- Main fact table. No index on a/b/c/pad/v, so ORDER BY / DISTINCT must do real work.
CREATE TABLE big(
  id  INTEGER PRIMARY KEY,
  g   INTEGER,   -- foreign key into dim (0..999)
  a   INTEGER,   -- 0 .. 999,999   (filter + sort + avg target)
  b   INTEGER,   -- 0 .. 999,999,999
  c   INTEGER,   -- 0 .. 99        (low-cardinality filter)
  pad TEXT,      -- 12-char hex, for text sorting
  v   INTEGER    -- 0 .. 999,999,999,999  (i64 range: forces 8-byte SQLite storage)
);

BEGIN;
INSERT INTO big(id, g, a, b, c, pad, v)
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n < __N__
)
SELECT
  n,
  abs(random()) % 1000,
  abs(random()) % 1000000,
  abs(random()) % 1000000000,
  abs(random()) % 100,
  hex(randomblob(6)),
  abs(random()) % 1000000000000
FROM seq;
COMMIT;

SELECT 'rows_built', count(*) FROM big;
