# jev — natural-language `WHERE` clauses for PostgreSQL

[![CI](https://github.com/realZachi/pg-jev/actions/workflows/ci.yml/badge.svg)](https://github.com/realZachi/pg-jev/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-PostgreSQL-blue.svg)](LICENSE)

`jev` lets you filter, rank and classify rows with plain English. Every row is judged by
[TypeSafe's Jev](https://docs.typesafe.ai), a System One model that returns calibrated probabilities
instead of generated text. No index, no embeddings, no vector column.

```sql
CREATE EXTENSION jev;

SELECT * FROM people WHERE jev(people, 'the name is European');

SELECT subject, jev_prob(tickets, 'the customer is angry') AS p
FROM tickets ORDER BY p DESC LIMIT 20;

SELECT jev_choice(tickets, 'which team should handle this?',
                  ARRAY['billing', 'technical', 'security', 'sales']) AS team, count(*)
FROM tickets GROUP BY 1;

SELECT name, jev_score(products, 'how luxurious is this product?',
                       ARRAY['budget', 'mid-range', 'premium', 'luxury']) AS luxury
FROM products ORDER BY luxury DESC;
```

`jev()` is an ordinary boolean function, so it composes with everything else in SQL: `AND age > 40`,
joins, `GROUP BY`, `LIMIT`, `ORDER BY jev_prob(...)`.

## How it works

1. `jev(table, 'condition')` receives the row as a composite value. On the first call for a table + condition
   the extension reads the whole table ahead (up to `jev.max_prefetch_rows`).
2. Rows are packed `jev.batch_size` per request into one shared *state*
   (`{"condition": ..., "rows": [...]}`) with one yes/no [Noul](https://docs.typesafe.ai/primitives/noul)
   question per row. Jev evaluates all questions over one state in parallel, which is far cheaper than one
   request per row.
3. Requests run concurrently (`jev.concurrency`). Answers are cached per row content for the session, so
   re-running, changing the threshold or sorting by probability is free.
4. Rows from a subquery or CTE (anonymous `record` type) can't be read ahead and are judged one request at a
   time. Put `jev()` on base tables when you can.

Measured on a 129-row table: first run ≈ 1 s, 4 requests, ≈ 21k input tokens, ≈ $0.0009. Second run ≈ 6 ms.

## Install

Requirements: PostgreSQL 14–17 with `plpython3u` (package `postgresql-plpython3-NN` on Debian/Ubuntu,
included in the EDB and Postgres.app builds), and a TypeSafe API key from https://console.typesafe.ai.

### From source (PGXS)

```bash
git clone https://github.com/realZachi/pg-jev.git && cd pg-jev
make install            # uses pg_config on PATH; or: make install PG_CONFIG=/path/to/pg_config
psql -c "CREATE EXTENSION jev"   # requires superuser (plpython3u is an untrusted language)
```

### Docker

```bash
docker build -t pg-jev .                       # add --build-arg PG_MAJOR=17 for another major
docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=pw -e TYPESAFE_API_KEY=your-key pg-jev
psql postgres://postgres:pw@localhost/postgres -c "CREATE EXTENSION jev"
```

### API key

Either export `TYPESAFE_API_KEY` in the environment of the PostgreSQL server process, or set it per session
or per role:

```sql
SET jev.api_key = 'your-key';
ALTER ROLE analyst SET jev.api_key = 'your-key';   -- persistent, per role
```

## Functions

| Function | Returns | Purpose |
| --- | --- | --- |
| `jev(row, condition [, threshold])` | boolean | `WHERE` predicate. Threshold: argument → `jev.threshold` → 0.5 |
| `jev_prob(row, condition)` | float8 | Probability 0..1 that the row satisfies the condition |
| `jev_score(row, question, levels text[])` | float8 | Probability-weighted position on ordered levels (0 .. n-1) |
| `jev_score_norm(row, question, levels)` | float8 | Same, normalised to 0..1 |
| `jev_choice(row, question, options text[])` | text | The most likely option for the row |
| `jev_confidence(row, question, kind, options)` | float8 | Confidence of a `score`/`choice` answer |
| `jev_eval(row, question, kind, options)` | jsonb | Full raw answer (probabilities, legend, confidence) |
| `jev_stats()` | jsonb | Requests, tokens, estimated cost, cache hits for this session |
| `jev_cache_clear()` | void | Forget cached judgments |
| `jev_version()` | text | Extension version |

`row` is the table alias itself (`jev(people, ...)`) or a subquery alias.

## Settings

All settings are plain GUCs: `SET jev.<name> = ...`, `ALTER ROLE ... SET`, `ALTER DATABASE ... SET`, or `postgresql.conf`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `jev.api_key` | env `TYPESAFE_API_KEY` | TypeSafe API key |
| `jev.model` | `jev-latest` | Model name or pinned version such as `jev-1.13.0` |
| `jev.threshold` | `0.5` | Probability at which `jev()` returns true |
| `jev.batch_size` | `40` | Rows per API request |
| `jev.concurrency` | `6` | Parallel API requests |
| `jev.max_prefetch_rows` | `5000` | Rows read ahead from the scanned table |
| `jev.notices` | `on` | Emit a `NOTICE` per batch run with request count, tokens, estimated cost and time |
| `jev.api_url` | `https://api.typesafe.ai/v1/systemone` | Endpoint (proxies, mocks) |
| `jev.timeout` | `90` | Seconds per API request |

## Writing good conditions

Jev answers the question you wrote, literally. A few things that help (more in the
[TypeSafe docs](https://docs.typesafe.ai/model-jaggedness/jev-1.13)):

- State the exact condition: `'the customer threatens to leave, dispute a charge, or take legal action'`
  beats `'churn risk'`.
- Keep arithmetic, dates and exact matches in SQL; let the model judge meaning.
- Look at the distribution with `jev_prob()` before picking a threshold. Ambiguous cases really do land
  near 0.5.
- Send only the columns the judgment needs: `jev((SELECT r FROM (SELECT name, bio) r), ...)` is possible, but a
  simpler pattern is a view with the relevant columns and `jev(view_alias, ...)` on the view.

## Caveats

- This is a full scan by design: every row goes to the API. Filter with indexed predicates first when the table
  is large, or raise `jev.max_prefetch_rows` deliberately.
- Row contents are sent to a third-party API. Do not use it on data you may not share.
- The cache lives in the backend session (PL/Python `GD`). Connection pools with many sessions each warm their
  own cache.
- `plpython3u` is an untrusted language: only superusers can create the extension, and functions run with the
  server's OS privileges.

## Development

```bash
make docker-test                 # builds test/Dockerfile and runs the regression suite (PG_MAJOR=16 by default)
make docker-test PG_MAJOR=17
```

Locally with a running server and `pg_config` on `PATH`:

```bash
make install
python3 test/mock_api.py &       # deterministic stand-in for the TypeSafe API
make installcheck                # pg_regress, tests in test/sql, expected output in test/expected
```

The regression tests never call the live API. To try the real thing, `SET jev.api_key` and run any query.

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/PUBLISHING.md](docs/PUBLISHING.md) for release steps.

## License

[PostgreSQL License](LICENSE). Jev and TypeSafe are trademarks of their respective owners; this project is not
affiliated with TypeSafe.
