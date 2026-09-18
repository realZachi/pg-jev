# Query patterns

Docs: https://pgjev.com/docs/guides/filter-and-rank.md, https://pgjev.com/docs/guides/classify-and-score.md,
https://pgjev.com/docs/guides/sql.md, https://pgjev.com/docs/guides/conditions.md,
https://pgjev.com/docs/guides/large-tables.md

How to turn a request into SQL: (1) decide the output shape → function, (2) write every cheap condition in SQL
first, (3) phrase the model's condition literally, (4) call it on a base table or view, (5) if the user has not
chosen a threshold, start with `jev_prob()` and look. Cost note: ~175 input tokens per row, $0.042/M tokens.

## 1. Filter (yes/no)

```sql
SELECT id, subject
FROM tickets
WHERE status = 'open'                              -- cheap, indexed, runs first
  AND created_at >= now() - interval '7 days'
  AND jev(tickets, 'the customer threatens to cancel or asks for a refund');
```

Stricter cut: `jev(tickets, '…', 0.8)`. Negation: `NOT jev(tickets, '…')` works, but note it keeps rows below the
threshold, including ambiguous ones; for "clearly not X" use `jev_prob(...) < 0.2`.

## 2. Rank / top-N

```sql
SELECT subject, jev_prob(tickets, 'the customer is angry') AS p
FROM tickets
WHERE status = 'open'
ORDER BY p DESC
LIMIT 20;
```

`LIMIT` does not save API calls here (sorting needs every probability), but a `WHERE jev(...)` + `LIMIT` without
`ORDER BY` stops the read-ahead after the in-flight window (2 × concurrency requests).

## 3. Pick a threshold from the distribution

```sql
SELECT width_bucket(jev_prob(reviews, 'the customer sounds frustrated'), 0, 1, 10) AS bucket, count(*)
FROM reviews
GROUP BY 1 ORDER BY 1;
```

Then `SELECT … WHERE jev(reviews, '…', 0.7)`. The second statement is free: same table + condition → cache.
Spot-check the middle: `WHERE jev_prob(...) BETWEEN 0.4 AND 0.6` shows what the model finds ambiguous, which
usually points at wording to tighten.

## 4. Classify into a closed set

```sql
SELECT jev_choice(tickets, 'which team should handle this ticket?',
                  ARRAY['billing', 'technical', 'security', 'sales']) AS team,
       count(*)
FROM tickets
WHERE status = 'open'
GROUP BY 1
ORDER BY 2 DESC;
```

Write the options as a person would read them (`'refund request'`, not `'REF'`); every row must fit one.
Route uncertain ones to a human with `jev_confidence(..., 'choice', ...) < 0.6`, or use `jev_eval` for
multi-label: `(jev_eval(t, 'which topics apply?', 'choice', ARRAY[...])->'probabilities')`.

Persisting labels:

```sql
UPDATE tickets t
SET team = jev_choice(t, 'which team should handle this ticket?', ARRAY['billing','technical','security','sales'])
WHERE team IS NULL;
```

Note `UPDATE` (and `INSERT … SELECT`) work like any other volatile-free function use; the model is called once per
row and the answer cached for the session.

## 5. Score on a rubric

```sql
SELECT name,
       jev_score(products, 'how luxurious is this product?',
                 ARRAY['budget', 'mid-range', 'premium', 'luxury']) AS luxury      -- 0..3
FROM products
ORDER BY luxury DESC;
```

Levels go low → high. `jev_score_norm` gives 0..1 when you combine rubrics:

```sql
SELECT name,
       0.6 * jev_score_norm(p, 'how luxurious?', ARRAY['budget','mid-range','premium','luxury'])
     + 0.4 * jev_score_norm(p, 'how urgent is restocking?', ARRAY['not at all','somewhat','very'])  AS priority
FROM products p
ORDER BY priority DESC;
```

## 6. Limit what the model sees (privacy, tokens): a view

The whole row is sent. When the table has columns the model does not need (PII, large blobs, internal ids), make
a view. Views are streamed and batched like tables.

```sql
CREATE VIEW ticket_text AS
SELECT id, subject, body FROM tickets WHERE status = 'open';

SELECT id FROM ticket_text v WHERE jev(v, 'the customer threatens legal action');
```

A pre-filter inside the view also shrinks the read-ahead. Avoid the tempting alternative:

```sql
-- Works, but each row is one API request: the subquery yields an anonymous record
SELECT * FROM (SELECT id, subject, body FROM tickets) s WHERE jev(s, '…');
```

If a subquery/CTE is unavoidable, make the inner result a real type: `SELECT … FROM tickets t WHERE … ` and call
`jev(t, …)` inside, or materialise into a temp table first.

## 7. Joins

`jev()` takes one row type, so judge the side that carries the text and join the rest:

```sql
SELECT c.name, t.subject
FROM tickets t
JOIN customers c ON c.id = t.customer_id
WHERE c.plan = 'enterprise'
  AND jev(t, 'this is a billing dispute');
```

To judge a combination of columns from two tables, build a view over the join and call `jev(view, …)`.

## 8. Aggregates and CASE

```sql
SELECT date_trunc('week', created_at) AS week,
       count(*) FILTER (WHERE jev(reviews, 'the customer sounds frustrated')) AS frustrated,
       count(*) AS total
FROM reviews
WHERE created_at >= now() - interval '90 days'
GROUP BY 1 ORDER BY 1;
```

```sql
SELECT id,
       CASE WHEN jev_prob(r, 'mentions a competitor by name') > 0.8 THEN 'competitor'
            WHEN jev_prob(r, 'asks for a feature we do not have') > 0.8 THEN 'feature'
            ELSE 'other' END AS kind
FROM reviews r;
```

Two different conditions are two scans of the table through the API (two cache keys). Prefer one `jev_choice`
with both options when they are mutually exclusive.

## 9. Large tables and spend

Every row reaching `jev()` costs tokens. In order of preference:

1. Indexed predicates before `jev()` (`status`, dates, ids, `tsvector @@` for keywords).
2. A view with only the needed columns (fewer characters per row).
3. A spend guard while exploring: `SET jev.max_rows_per_statement = 2000;`
4. `LIMIT` with a plain `WHERE jev(...)` (stops early). With `ORDER BY jev_prob(...)` it does not.
5. Sample first to test the wording: `FROM reviews TABLESAMPLE SYSTEM (5) WHERE jev(reviews, '…')`.

Estimate before running: rows × ~175 tokens × $0.042 / 1M. 10,000 rows ≈ 1.75M tokens ≈ $0.07 and roughly
15–20 s from Europe at the default concurrency.

## 10. Same session, repeated exploration

Answers are cached per (relation type, question, kind, options) and row content for the backend session. Iterating
on thresholds, sorting, `LIMIT`, joins or aggregates over the same condition is free; changing a single word of
the condition is a new scan. Keep the session (or the pooled connection) open while exploring; `SELECT jev_stats()`
shows `cache_hits` climbing.

## Wording checklist for the condition

- Name the observable behaviour, not the label: `'the reviewer says the product broke within a month'` rather
  than `'quality issue'`.
- One condition per call. "A or B" is fine when the user wants either; "A and B" is fine; a list of five things is
  better as `jev_choice`.
- Refer to the row as "the record", "the ticket", "the customer", matching the column names the model will see.
- Do not ask for computation (`'the total is above 100'`): put it in SQL.
- Language: the condition can be in the user's language; the data can be in another. Say which language a text
  column is in if it matters (`'the review, written in German, is sarcastic'`).
