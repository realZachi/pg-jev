-- Read-ahead behaviour on a table larger than one page: streaming, LIMIT, filters, scan order, views.
\set VERBOSITY terse
SET jev.api_url = 'http://127.0.0.1:8765/v1/systemone';
SET jev.api_key = 'test-key';
SET jev.notices = off;
SET jev.batch_size = 20;
SET jev.concurrency = 4;

CREATE TABLE big AS
  SELECT g AS id, 'row ' || g AS label, CASE WHEN g % 100 = 0 THEN 'special' ELSE 'plain' END AS tag
  FROM generate_series(1, 2500) g;
CREATE INDEX big_id ON big (id);
ANALYZE big;

-- A full scan judges every row exactly once, 20 rows per request, whatever the table size
SELECT count(*) AS special FROM big WHERE jev(big, 'the tag is special');
SELECT (jev_stats()->>'requests')::int AS requests, (jev_stats()->>'rows_evaluated')::int AS rows_evaluated;

-- LIMIT stops the read-ahead early: only the in-flight window (2 x concurrency requests) is judged
SELECT id FROM big WHERE jev(big, 'the tag is plain') LIMIT 1;
SELECT (jev_stats()->>'rows_evaluated')::int - 2500 BETWEEN 20 AND 160 AS limit_judged_only_a_window;
-- Finishing the same condition later reuses those answers: 2500 rows, 125 requests in total
SELECT count(*) AS plain FROM big WHERE jev(big, 'the tag is plain');
SELECT (jev_stats()->>'requests')::int AS requests, (jev_stats()->>'rows_evaluated')::int AS rows_evaluated;

-- Rows filtered out by cheaper predicates before jev() runs are skipped, not judged
SELECT count(*) AS every_500th FROM big WHERE id % 500 = 0 AND jev(big, 'the label is row');
SELECT (jev_stats()->>'rows_evaluated')::int - 5000 <= 800 AS filtered_rows_skipped;
-- ... and the rest of the table is judged once when a later statement needs it
SELECT count(*) AS all_rows FROM big WHERE jev(big, 'the label is row');
SELECT (jev_stats()->>'rows_evaluated')::int AS rows_evaluated;

-- A backward index scan asks for rows in reverse physical order: they are still batched, not judged one by one
SELECT (jev_stats()->>'rows_evaluated')::int AS rows_before, (jev_stats()->>'requests')::int AS requests_before \gset
SET enable_seqscan = off;
SET enable_sort = off;
SELECT id FROM big WHERE jev(big, 'this is a row') ORDER BY id DESC LIMIT 3;
RESET enable_seqscan;
RESET enable_sort;
SELECT (jev_stats()->>'rows_evaluated')::int - :rows_before AS rows_judged, (jev_stats()->>'requests')::int - :requests_before AS requests;

-- Views cannot be paged by ctid and are streamed with OFFSET/LIMIT instead
SELECT (jev_stats()->>'rows_evaluated')::int AS rows_before, (jev_stats()->>'requests')::int AS requests_before \gset
CREATE VIEW special_rows AS SELECT * FROM big WHERE tag = 'special';
SELECT count(*) AS via_view FROM special_rows WHERE jev(special_rows, 'the tag is special');
SELECT (jev_stats()->>'rows_evaluated')::int - :rows_before AS rows_judged, (jev_stats()->>'requests')::int - :requests_before AS requests,
       (jev_stats()->>'errors')::int AS errors;

-- Idle keep-alive connections are pooled per session
SELECT (jev_stats()->>'connections')::int BETWEEN 1 AND 4 AS pooled_connections;
