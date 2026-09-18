# Functions

Docs: https://pgjev.com/docs/functions.md

All functions take the **row** as first argument: the table alias, view alias or subquery alias
(`jev(people, …)`, `jev(p, …)` after `FROM people p`). Postgres passes the whole row as a composite value; the
extension serialises it with `to_json` (column order preserved) and sends it to the API. Column names are part of
what the model sees, so descriptive names help.

All are `STABLE`, so they can be used in `WHERE`, `SELECT`, `ORDER BY`, `GROUP BY`, `HAVING`, `CASE`, joins and
views, but not in index definitions or generated columns.

## Judgment functions

### `jev(row, condition text [, threshold float8]) → boolean`

`jev_prob(row, condition) >= coalesce(threshold, jev.threshold, 0.5)`. The predicate. `threshold` argument beats
the `jev.threshold` GUC beats `0.5`.

```sql
SELECT * FROM reviews WHERE jev(reviews, 'the customer sounds frustrated');
SELECT * FROM reviews WHERE jev(reviews, 'the customer sounds frustrated', 0.8);
```

### `jev_prob(row, condition text) → float8`

Probability 0..1 that the row satisfies the condition (a TypeSafe *noul* question over
`{"condition": …, "rows": […]}`). Use for ranking, distributions and choosing a threshold. Calibrated: ambiguous
rows sit near 0.5.

```sql
SELECT subject, jev_prob(tickets, 'the customer is angry') AS p FROM tickets ORDER BY p DESC LIMIT 20;
```

### `jev_choice(row, question text, options text[]) → text`

The most likely option. Returns one element of `options` verbatim. Options are a closed set; there is no
"none of the above" unless you add one, so prefer a set where every row has a sensible answer.

```sql
SELECT jev_choice(tickets, 'which team should handle this?', ARRAY['billing','technical','security','sales']) AS team,
       count(*)
FROM tickets GROUP BY 1;
```

### `jev_score(row, question text, levels text[]) → float8`

Probability-weighted position on the ordered `levels`, from `0` (first level) to `n-1` (last). A row that the
model puts at 60 % `premium` / 40 % `luxury` on `['budget','mid-range','premium','luxury']` scores `2.4`.
Order matters: list levels from low to high.

### `jev_score_norm(row, question text, levels text[]) → float8`

`jev_score / (n-1)`, i.e. 0..1, so scores on rubrics with different lengths are comparable.

### `jev_confidence(row, question text, kind text, options text[]) → float8`

Confidence 0..1 of a `'choice'` or `'score'` answer (the API's `confidence` field). Useful to route low-confidence
rows to a human:

```sql
SELECT id,
       jev_choice(t, 'which team?', ARRAY['billing','technical','sales']) AS team,
       jev_confidence(t, 'which team?', 'choice', ARRAY['billing','technical','sales']) AS conf
FROM tickets t
WHERE jev_confidence(t, 'which team?', 'choice', ARRAY['billing','technical','sales']) < 0.6;
```

The same `(question, kind, options)` triple hits the same cache entry, so calling `jev_choice` and
`jev_confidence` with identical arguments costs one API call, not two.

### `jev_eval(row, question text, kind text DEFAULT 'noul', options text[] DEFAULT NULL) → jsonb`

The raw answer. `kind` is `'noul'`, `'choice'` or `'score'`; `options` is required for the last two.

| kind | jsonb shape |
| --- | --- |
| `noul` | `{"type":"noul","noul":0.93}` |
| `choice` | `{"type":"choice","choice":"billing","probabilities":{"billing":0.8,"technical":0.15,"sales":0.05},"confidence":0.8}` |
| `score` | `{"type":"score","score":2.4,"legend":{"0":"budget","1":"mid-range","2":"premium","3":"luxury"},"probabilities":{"0":0.0,"1":0.0,"2":0.6,"3":0.4},"confidence":0.6}` |

Use it when you need the full probability vector (e.g. multi-label routing: every option above 0.3).

## Session helpers

### `jev_stats() → jsonb`

Counters for the current backend session:

```
requests, input_tokens, output_tokens, rows_evaluated, cache_hits, api_ms, batches, errors, retries,
estimated_cost_usd, cached_answers, in_flight, connections
```

`estimated_cost_usd = input_tokens × $0.042 / 1M` (jev-1.13 list price; output tokens are free).
`connections` is the number of idle pooled HTTPS connections.

### `jev_cache_clear() → void`

Forgets cached answers and read-ahead state for this session only. Answers are cached by row content, so an
`UPDATE` to a row changes its hash and it is re-judged automatically; you rarely need this except when switching
`jev.model` and wanting fresh answers.

### `jev_version() → text`

Extension version, e.g. `0.2.0`. Compare with `SELECT default_version FROM pg_available_extensions WHERE name='jev'`
to see whether `ALTER EXTENSION jev UPDATE` is pending.

## The internal function

`_jev_eval(rel_type text, row_json text, query text, kind text, options text)` is what every wrapper calls. Do not
call it directly in user-facing SQL; its signature is not part of the stable API.
