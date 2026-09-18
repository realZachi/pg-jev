-- pgjev smoke test: one call per function on a five-row temp table, then session stats.
--   psql -d mydb -f smoke_test.sql
-- Needs the extension created and an API key (SET jev.api_key / TYPESAFE_API_KEY on the server).
-- Sends 5 small rows to the API once (a few hundred tokens, well under a cent). Nothing is left behind.
\set ON_ERROR_STOP on
\set QUIET on
\pset footer off

SELECT jev_version() AS jev_version;

CREATE TEMP TABLE jev_smoke (id int, product text, review text);
INSERT INTO jev_smoke VALUES
  (1, 'Espresso machine', 'Broke after two weeks, support never answered. Never buying from them again.'),
  (2, 'Hiking boots',     'Comfortable from day one, survived a rainy week in Scotland.'),
  (3, 'Desk lamp',        'Does what it says. Nothing special, nothing wrong.'),
  (4, 'Headphones',       'Sound is fine but the left ear cup cracked; I want a refund.'),
  (5, 'Notebook',         'Paper is thick and the binding lies flat. Lovely.');

\echo
\echo '-- jev(): rows where the customer is unhappy'
SELECT id, product FROM jev_smoke WHERE jev(jev_smoke, 'the customer is unhappy with the product') ORDER BY id;

\echo
\echo '-- jev_prob(): the same condition as a probability (cached, no new API call)'
SELECT id, round(jev_prob(jev_smoke, 'the customer is unhappy with the product')::numeric, 2) AS p
FROM jev_smoke ORDER BY p DESC;

\echo
\echo '-- jev_choice(): what the review is mainly about'
SELECT id, jev_choice(jev_smoke, 'what is this review mainly about?',
                      ARRAY['durability', 'comfort or quality', 'customer service', 'nothing in particular']) AS topic
FROM jev_smoke ORDER BY id;

\echo
\echo '-- jev_score(): sentiment on an ordered rubric (0 = very negative .. 4 = very positive)'
SELECT id, round(jev_score(jev_smoke, 'how positive is this review?',
                           ARRAY['very negative', 'negative', 'neutral', 'positive', 'very positive'])::numeric, 2) AS sentiment
FROM jev_smoke ORDER BY sentiment;

\echo
\echo '-- jev_stats(): requests, tokens, estimated cost for this session'
SELECT jsonb_pretty(jev_stats() - 'api_ms') AS stats;

DROP TABLE jev_smoke;
\echo
\echo 'Smoke test finished. If errors = 0 above, pgjev is working.'
