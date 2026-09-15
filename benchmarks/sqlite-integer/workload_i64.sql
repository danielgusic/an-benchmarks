-- i64 workload for the AN-encoding SQLite benchmark.
-- Mirrors the structure of workload_i32.sql (reads + a full write suite that
-- grows the database) so that the memory overhead comparison between i32 and
-- i64 is apples-to-apples.  Only touches the v column (0..999,999,999,999),
-- which forces SQLite to use 8-byte integer storage for every data operation.

PRAGMA journal_mode = DELETE;
PRAGMA synchronous  = NORMAL;

-- ---- READS ----------------------------------------------------------------

-- R8: full-table aggregate on i64 column (scan + sum/min/max of 8-byte values)
SELECT 'R8', count(*), sum(v), min(v), max(v) FROM big;

-- R9: selective filter on i64 column (~50% selectivity, no index)
SELECT 'R9', count(*) FROM big WHERE v < 500000000000;

-- R10: group-by on i64 ranges (bucket v into 10 bands of 100 B each)
SELECT 'R10', v/100000000000 AS band, count(*) cnt, sum(v) sv
FROM big GROUP BY band ORDER BY cnt DESC LIMIT 5;

-- R11: full sort on v DESC (no index → real sort on 8-byte keys)
SELECT 'R11', id, v FROM big ORDER BY v DESC LIMIT 10;

-- R12: distinct-cardinality approximation (high-cardinality i64 column)
SELECT 'R12', count(DISTINCT v/1000000000) FROM big;

-- ---- WRITES ---------------------------------------------------------------

-- W1v: bulk insert ~20% more rows in one transaction.
-- Same deterministic formula as W1 in the i32 workload so AN-off and AN-on
-- insert identical rows and the end-to-end correctness diff stays meaningful.
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
SELECT 'W1v_inserted_now_total', count(*) FROM big;

-- W2v: large UPDATE on i64 column (~50% of rows, full-scan predicate)
UPDATE big SET v = v + 1000000000000 WHERE v < 500000000000;
SELECT 'W2v_updated', changes();

-- W3v: DELETE a subset based on v (frees pages, writes journal)
DELETE FROM big WHERE v < 50000000000;
SELECT 'W3v_deleted', changes();

-- W4v: create an index on v (write-heavy: sorts + builds a b-tree on 8-byte keys)
CREATE INDEX idx_big_v ON big(v);
SELECT 'W4v_indexed_rows', count(*) FROM big;

-- W5v: indexed point-ish range read after the index exists
SELECT 'W5v', count(*), sum(v) FROM big WHERE v BETWEEN 100000000000 AND 200000000000;

-- W6: reclaim space / rewrite the whole file
VACUUM;
SELECT 'W6_vacuum_done', count(*) FROM big;
