---
name: pgjev
description: Install, configure, query and explain pgjev (the `jev` PostgreSQL extension that filters, ranks and classifies rows with plain-language conditions via TypeSafe's Jev model). Use this skill whenever a user mentions pgjev, pg-jev, the jev extension, `jev()`, `jev_prob`, `jev_choice`, `jev_score`, a "natural-language WHERE clause", "ask my Postgres table a question", classifying or scoring rows with AI inside Postgres, or hits an error starting with `jev:`. Covers "install pgjev on my server / in Docker", "write a query that picks rows where …", "what can jev do", cost and performance questions, and troubleshooting, with scripts that check the server, install the extension and run a smoke test.
---

# pgjev — plain-language predicates for PostgreSQL

`jev(table, 'condition')` is an ordinary boolean SQL function. Every row is sent to TypeSafe's Jev model
(a "System One" model that returns calibrated probabilities, not text) and judged against the condition.
No index, no embeddings, no vector column. The sibling functions return a probability (`jev_prob`), a class
(`jev_choice`), a rubric score (`jev_score`) or the raw answer (`jev_eval`).

```sql
SELECT * FROM tickets WHERE status = 'open' AND jev(tickets, 'the customer threatens to cancel');
```

The canonical documentation is **https://pgjev.com/docs**. Every page has a Markdown twin: append `.md`
(`https://pgjev.com/docs.md`, `https://pgjev.com/docs/functions.md`, `https://pgjev.com/docs/settings.md`).
Fetch those when a question goes beyond this skill, and point users there for further reading.
Source: https://github.com/realZachi/pg-jev.

## Figure out which job you have

| The user wants… | Do this | Read |
| --- | --- | --- |
| to install or set up pgjev | follow **Install** below; run `scripts/check_server.sh` first | `references/install.md` |
| a query ("rows where …", "rank by …", "sort tickets into teams") | follow **Write a query** below | `references/query-patterns.md`, `references/functions.md` |
| to know what jev can do / how it works / what it costs | follow **Explain** below | `references/how-it-works.md` |
| to tune batching, timeouts, spend limits, model pin | look up the GUC | `references/settings.md` |
| help with an error or unexpected result | **Troubleshoot** table below | `references/install.md` (troubleshooting section) |

## Install

Hard requirement first, because it decides whether install is possible at all: pgjev needs
**self-hosted PostgreSQL 14–17 with `plpython3u`** and a **superuser** to run `CREATE EXTENSION`. It does not
run on Supabase, Neon, RDS/Aurora or other managed hosts that withhold superuser or untrusted Python. Tell the
user this early rather than after a failed build. Docker is the way to try it without touching a host.

1. Check the target server: `bash scripts/check_server.sh [psql connection args]`. It reports the version,
   whether `plpython3u` is available, whether you are superuser, whether `jev` is already installed and whether
   an API key is configured, then prints a verdict.
2. Install the extension files (nothing to compile; PGXS just copies `jev.control` + SQL). Pick one:
   - From PGXN (preferred when `pgxn` is available or `pip install pgxnclient` is acceptable; no clone to manage):
     `bash scripts/install.sh --pgxn [--pg-config /path/to/pg_config] [--db mydb]`, which runs
     `pgxn install jev` (pinned with `--ref X.Y.Z`) and then `CREATE EXTENSION IF NOT EXISTS jev CASCADE`.
     By hand: `pgxn install jev [--pg_config PATH]` (`sudo` if the extension dir is root-owned).
   - From source: `bash scripts/install.sh [--pg-config /path/to/pg_config] [--db mydb]`. It clones the repo
     into a temp dir (or uses `--source DIR` / the current checkout), runs `make install`, then
     `CREATE EXTENSION IF NOT EXISTS jev CASCADE` in `--db`. Pass `--no-create` to stop after `make install`.
   - Docker: `docker build -t pg-jev .` in a clone, then `docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=pw
     -e TYPESAFE_API_KEY=... pg-jev` and `CREATE EXTENSION jev CASCADE` against it. `--build-arg PG_MAJOR=17` for
     another major.
3. Configure the API key (from https://console.typesafe.ai). Three options, pick what fits the deployment:
   `SET jev.api_key = '...'` (session), `ALTER ROLE analyst SET jev.api_key = '...'` (persistent per role), or
   `TYPESAFE_API_KEY` in the environment of the **server** process (not the psql client). Never paste a user's
   real key into files you commit; put it in a role setting or the server environment.
4. Verify: `psql -d mydb -f scripts/smoke_test.sql`. It creates a temp table, runs each function once, and
   prints `jev_stats()` so the user sees requests, tokens and estimated cost.

Details, per-platform package names and the troubleshooting list are in `references/install.md`.

## Write a query

Pick the function from the shape of the answer the user needs:

| Need | Function | Example |
| --- | --- | --- |
| yes/no filter | `jev(row, condition [, threshold])` → boolean | `WHERE jev(t, 'the customer is angry')` |
| ranking / a cutoff not chosen yet | `jev_prob(row, condition)` → 0..1 | `ORDER BY jev_prob(t, '…') DESC LIMIT 20` |
| one label from a closed set | `jev_choice(row, question, options text[])` → text | `jev_choice(t, 'which team?', ARRAY['billing','technical','sales'])` |
| position on an ordered rubric | `jev_score(row, question, levels text[])` → 0..n-1 (`jev_score_norm` → 0..1) | `jev_score(p, 'how luxurious?', ARRAY['budget','mid','premium','luxury'])` |
| how sure the model is | `jev_confidence(row, question, kind, options)` → 0..1 | with `'choice'` or `'score'` |
| everything (probabilities, legend) | `jev_eval(row, question, kind, options)` → jsonb | for debugging or custom logic |

`row` is the **table or view alias itself** (`jev(tickets, …)`, `jev(t, …)` after `FROM tickets t`), not a column.
Full signatures and the jsonb shape are in `references/functions.md`.

Rules that make the difference between a good query and an expensive, wrong one:

- **Cheap predicates first, `jev()` last.** Rows rejected by `status = 'open' AND created_at > …` before `jev()`
  runs are never sent to the API. Write the SQL so that happens; the planner does not reorder for cost of an
  external call.
- **Keep arithmetic, dates and exact matches in SQL.** Let the model judge meaning only ("sounds frustrated",
  "is a billing dispute"), never things SQL can compute (`age > 40`, `country = 'DE'`).
- **State the condition literally.** `'the customer threatens to leave, dispute a charge, or take legal action'`
  beats `'churn risk'`. Jev answers the question as written. Name `jev_choice` options the way you would brief a
  person, as a closed set without an `'other'` bucket.
- **Call it on a base table or a view, not on a subquery/CTE.** Tables and views are streamed ahead and batched
  20 rows per request; an anonymous `record` from a CTE is judged one request per row. To limit which columns the
  model sees (privacy, tokens), create a view with just those columns and call `jev(view_alias, …)`.
- **Look at the distribution before freezing a threshold.** Suggest `jev_prob()` + `width_bucket` or
  `ORDER BY p DESC LIMIT 20` first; ambiguous rows really land near 0.5. Re-running with another threshold is free
  because answers are cached per session.
- **Say what it will cost.** Every row reaching `jev()` goes to the API; ~175 input tokens per row in batches of 20,
  $0.042 per million input tokens (≈ $0.012 for 2,000 rows). On a large table propose an indexed pre-filter and,
  for shared servers, `SET jev.max_rows_per_statement = N` as a spend guard. Row contents leave the database, so
  ask before running it on data that may not be shared.

Worked examples for filter, rank, classify, score, joins, views, GROUP BY and thresholds are in
`references/query-patterns.md`. Read it when the request is more than a one-liner.

## Explain

When asked what pgjev is or can do, lead with the one-sentence version (plain-language predicate, ordinary SQL
function, composes with everything), show one filter and one classify example, and be straight about the three
things people most often get wrong:

1. It is a **full scan by design**: no index, every row that reaches `jev()` is judged (then cached per session).
2. It needs **self-hosted Postgres with `plpython3u` and superuser**: no Supabase/Neon/RDS.
3. **Data leaves Postgres** to TypeSafe's API.

Then link https://pgjev.com/docs. For the pipeline (streaming read-ahead, batches of 20, 2 × concurrency in
flight, keep-alive connections, per-session cache), measured numbers and why 20 rows per request, read
`references/how-it-works.md` instead of guessing.

## Troubleshoot

| Symptom | Cause / fix |
| --- | --- |
| `jev: no API key. SET jev.api_key = '...' or start the server with TYPESAFE_API_KEY set.` | Key not set for this session/role, and the **server** process has no `TYPESAFE_API_KEY`. Setting it in the client shell does nothing. |
| `jev: TypeSafe API error 401 …` | Wrong key. |
| `ERROR: could not open extension control file … jev.control` | `make install` copied into a different Postgres than the one you connect to. Use `make install PG_CONFIG=/path/to/that/pg_config`. |
| `ERROR: could not open extension control file … plpython3u.control` / `language "plpython3u" does not exist` | Install `postgresql-plpython3-NN` (Debian/Ubuntu) or a build that ships it; managed hosts cannot. |
| `required extension "plpython3u" is not installed` | `CREATE EXTENSION jev` without `CASCADE`. Use `CREATE EXTENSION jev CASCADE;`. |
| `permission denied to create extension "jev"` | Only superusers can create it (`plpython3u` is untrusted). |
| `jev: this statement would send N rows to the API, above jev.max_rows_per_statement = M` | Spend guard fired. Add a pre-filter or raise the guard on purpose. |
| Query is slow, one request per row in the `NOTICE`s | `jev()` is called on a CTE/subquery (`record`). Move it onto the base table or a view. |
| Nothing matches | Look at `jev_prob()`; reword the condition literally; lower the threshold. |
| Results differ from single-row checks | `jev.batch_size` was raised above ~20; the model locates `rows[i]` by position and accuracy drops. Set it back. |
| `statement_timeout` or Ctrl-C seems ignored | Fixed in 0.2.0 (waits are interruptible within 250 ms). `SELECT jev_version()`; upgrade with `ALTER EXTENSION jev UPDATE`. |

`SELECT jev_stats();` shows requests, tokens, estimated cost, cache hits, errors, retries, in-flight requests and
pooled connections for the session and is the first thing to look at.

## Files in this skill

- `scripts/check_server.sh` — preflight: version, `plpython3u`, superuser, jev installed, key configured.
- `scripts/install.sh` — `pgxn install jev` (`--pgxn`) or clone + `make install`, then `CREATE EXTENSION … CASCADE`.
- `scripts/smoke_test.sql` — one call per function on a temp table, then `jev_stats()`.
- `references/install.md` — requirements, PGXN/source/Docker details, API key placement, troubleshooting.
- `references/functions.md` — every function, argument, return type, the `jev_eval` jsonb shape.
- `references/settings.md` — every GUC with default and when to change it.
- `references/query-patterns.md` — worked SQL for filter, rank, classify, score, views, joins, thresholds, spend.
- `references/how-it-works.md` — pipeline, cache, cost model, measured numbers, caveats.
