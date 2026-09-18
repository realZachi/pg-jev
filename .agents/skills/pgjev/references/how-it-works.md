# How it works, what it costs, what to be honest about

Docs: https://pgjev.com/docs/how-it-works.md, https://pgjev.com/docs/caveats.md

## The model

Every row is judged by **TypeSafe's Jev** (https://docs.typesafe.ai), a "System One" model: it does not generate
text, it returns calibrated probabilities for typed questions over a JSON *state*. pgjev uses three question types:

- **noul** (yes/no): `jev`, `jev_prob` → a probability that the row satisfies `condition`.
- **choice**: `jev_choice` → a probability per option.
- **score**: `jev_score`, `jev_score_norm` → a probability per ordered level, collapsed to a weighted index.

Because answers are probabilities, `jev_prob` is meaningful for ranking and thresholds, and confidence values
are real rather than self-reported.

## The pipeline (version 0.2.0)

1. **Row in.** `jev(tickets, '…')` receives the row as a composite; it is serialised with `to_json` and hashed.
   A cache hit for that (relation, question) and row content returns immediately without touching SPI or the API.
2. **Read-ahead.** The first miss for a table + question starts a job that streams the relation in physical
   order: TID range scans for tables and materialised views, `OFFSET`/`LIMIT` pages for views, partitioned and
   foreign tables, 1,000 rows per SPI page. Memory stays constant whatever the table size.
3. **Batch.** Rows are packed `jev.batch_size` (20) per request into one shared state
   `{"condition": …, "rows": […]}` with one question per row (`Does the record rows[i] satisfy the condition?`).
   One request judges all 20 in parallel, which amortises the ~270-token request overhead: about 175 input tokens
   per row in batches of 20 versus ~435 for a row alone.
4. **In flight.** Up to 2 × `jev.concurrency` (32) requests are in flight on a per-session thread pool, over
   persistent HTTPS connections with TCP keepalive (one TLS handshake per connection, not per request). Each row
   is answered as soon as its batch returns, so the executor never waits for the whole table, a `LIMIT` stops the
   read-ahead after the in-flight window, and rows filtered out by cheaper predicates are skipped, not judged.
5. **Out-of-order rows.** Rows the executor asks for out of physical order (index scans, joins, backward scans)
   are batched with their skipped neighbours rather than sent alone; `jev.max_prefetch_rows` bounds how far the
   read-ahead searches and how many skipped rows it remembers.
6. **Cache.** Answers are cached by row content in the backend session (PL/Python `GD`). Re-running, changing the
   threshold, sorting by `jev_prob`, aggregating: free. A different condition is a new scan.
7. **Rows without a relation** (subquery/CTE producing an anonymous `record`) cannot be read ahead and are judged
   one request per row. That is the single most common reason for a slow pgjev query.

Retries honour `Retry-After` on 429/529/5xx; pooled connections are checked before reuse and replaced when the
server closed them or they idled longer than `jev.keepalive`. Waits are sliced at 250 ms so `statement_timeout`
and cancel requests work.

## Why 20 rows per request

The model finds `rows[i]` by position inside the array. Against ground truth from structured columns (job title,
EU membership, a phrase in a free-text field; 400 rows each), batches of 1–20 rows were 100 % correct, batches of
40 were 92–98 %, batches of 80 were 77–94 %. Row width (up to 1,000 characters) made no difference at 20. Batches
of 20 cost only 4 % more tokens than 40 and are as fast, because request latency barely depends on size. So
`jev.batch_size` defaults to 20 and should stay there.

## Measured numbers (from Europe, ~190 ms RTT to the API)

| Scenario | Result |
| --- | --- |
| 2,000-row table, new condition | ≈ 3.5 s, 100 requests, ≈ 296k input tokens, ≈ $0.012 |
| same query again in the session | ≈ 50 ms (cache) |
| `LIMIT 3` on a new condition | ≈ 0.6 s |
| new condition with warm pooled connections | ≈ 2.3 s (the first request on each fresh connection pays 0.9–1.9 s of TLS + server setup, then ≈ 0.3 s each) |
| version 0.1.0 for comparison | 8.5 s and 338k tokens for the same full query |

Cost formula: `input_tokens × $0.042 / 1M` (jev-1.13 list price; output tokens free). Rule of thumb
**≈ 175 tokens ≈ $0.0000074 per row**, so 1k rows ≈ $0.007, 100k rows ≈ $0.7. `jev_stats()` reports the running
total as `estimated_cost_usd`; the per-table `NOTICE` reports it per statement.

## Caveats to state plainly

- **Full scan by design.** No index can answer a plain-language condition; every row that reaches `jev()` is
  judged (once per session). Cut the set in SQL first.
- **Data leaves Postgres.** Row contents go to TypeSafe's API over HTTPS. Do not use it on data that may not be
  shared; use a view to send only what is needed.
- **Untrusted language, superuser install.** `plpython3u` runs with the OS privileges of the server process. Only
  superusers can create the extension; managed hosts (Supabase, Neon, RDS…) cannot run it.
- **Cache per backend.** Connection pools with many backends each warm their own cache. `jev_cache_clear()`
  clears only the current session.
- **Answers can change** between model releases. Pin `jev.model = 'jev-1.13.0'` when results feed reports.
- **Not a substitute for SQL.** Arithmetic, dates, equality and joins stay in SQL; the model is for meaning.

## Versions

| Version | Notes |
| --- | --- |
| 0.2.0 (2026-09-18) | streaming read-ahead, persistent connections, batch 20, concurrency 16, timeout 30, `jev.keepalive`, spend guards, progress notices, interruptible waits |
| 0.1.0 | whole-table prefetch up to `max_prefetch_rows`, batch 40, concurrency 6, timeout 90 |

`SELECT jev_version();` tells which one is loaded; `ALTER EXTENSION jev UPDATE;` after `make install` upgrades.
