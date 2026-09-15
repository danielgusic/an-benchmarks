-- i32 workload for the AN-encoding SQLite benchmark.
-- Only touches i32-range columns (a, b, c, g, pad). Column v is included in
-- W1 so the INSERT stays schema-valid, but no i64-specific reads or writes
-- are issued here. See workload_i64.sql for the i64 counterpart.

PRAGMA journal_mode = DELETE;
PRAGMA synchronous  = NORMAL;

-- ---- READS ----------------------------------------------------------------

-- R1: full-table aggregate (scan + avg/sum/min/max)
SELECT 'R1', count(*), sum(a), avg(a), min(a), max(b) FROM big;

-- R2: selective filter + count (full scan, low-cardinality predicate)
SELECT 'R2', count(*) FROM big WHERE a < 250000 AND c = 7;

-- R3: group-by aggregate over 1000 groups, ordered
SELECT 'R3', g, count(*) cnt, sum(a) sa, avg(b) ab
FROM big GROUP BY g ORDER BY cnt DESC LIMIT 5;

-- R4: full sort on a non-indexed column (no index -> real sort)
SELECT 'R4', id, a FROM big ORDER BY a DESC, b ASC LIMIT 10;

-- R5: distinct cardinality (hash/sort of all rows)
SELECT 'R5', count(DISTINCT a) FROM big;

-- R6: join big -> dim, grouped and ordered
SELECT 'R6', d.name, count(*) c, avg(b.b) ab
FROM big b JOIN dim d ON b.g = d.g
GROUP BY d.name ORDER BY c DESC LIMIT 5;

-- R7: text sort on non-indexed TEXT column
SELECT 'R7', pad FROM big ORDER BY pad LIMIT 5;

-- ---- WRITES ---------------------------------------------------------------

-- W1: bulk insert ~20% more rows in one transaction.
-- Values are a DETERMINISTIC function of n (not random()), so AN-off and AN-on
-- insert identical rows and the end-to-end correctness diff is meaningful.
BEGIN;
INSERT INTO big(g, a, b, c, pad, v)
WITH RECURSIVE s(n) AS (
  SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n < (SELECT count(*)/5 FROM big)
)
SELECT (n*31)            % 1000,
       (n*2654435761)    % 1000000,
       (n*40503 + 12345) % 1000000000,
       (n*97)            % 100,
       printf('%012x', (n*2246822519) % 4294967296),
       (n*999999999937)  % 1000000000000
FROM s;
COMMIT;
SELECT 'W1_inserted_now_total', count(*) FROM big;

-- W2: large UPDATE across many rows (full-scan predicate)
UPDATE big SET b = b + 1, c = (c + 1) % 100 WHERE a < 500000;
SELECT 'W2_updated', changes();

-- W3: DELETE a subset (frees pages, writes journal)
DELETE FROM big WHERE a < 50000;
SELECT 'W3_deleted', changes();

-- W4: create an index (write-heavy: sorts + builds a b-tree on disk)
CREATE INDEX idx_big_a ON big(a);
SELECT 'W4_indexed_rows', count(*) FROM big;

-- W5: indexed point-ish range read after the index exists
SELECT 'W5', count(*), sum(b) FROM big WHERE a BETWEEN 100000 AND 200000;

-- W6: reclaim space / rewrite the whole file
VACUUM;
SELECT 'W6_vacuum_done', count(*) FROM big;
