# AGENTS.md

Guidance for AI coding agents (Claude Code, Codex, Cursor, Copilot, …) working in this repository.

`jev` is a PostgreSQL extension that adds plain-language predicates (`WHERE jev(people, 'the name is European')`).
Every row is judged by TypeSafe's Jev model over HTTPS. The whole extension is **one PL/Python function plus SQL
wrappers**; there is nothing to compile.

## Documentation

When a question is about *what jev does* or *how to use it* (functions, settings, install, conditions, caveats,
performance), consult the docs at **https://pgjev.com/docs** before answering from the code. Every docs page has a
Markdown twin: append `.md` to the path (`https://pgjev.com/docs.md`, `https://pgjev.com/docs/functions.md`,
`https://pgjev.com/docs/settings.md`, `https://pgjev.com/docs/how-it-works.md`, …). See
https://pgjev.com/docs/for-agents.md.

The docs source lives in the sibling repo `/Users/mahmoudalikhan/dev/pgjev-site` (`content/docs/*.mdx`). Any change
to the SQL API, a setting, a default or documented behaviour must be mirrored there **and** in `README.md` here.
When pointing users at docs, link pgjev.com/docs rather than paraphrasing at length.

`.agents/skills/pgjev/` (symlinked as `.claude/skills/pgjev`) is the **user-facing agent skill** shipped with the
repo and installable via `npx skills add realZachi/pg-jev`: how to install, configure, query and explain pgjev,
plus `scripts/check_server.sh`, `scripts/install.sh` and `scripts/smoke_test.sql`. It states defaults, function
signatures and error messages, so update it together with README and docs when those change. This AGENTS.md is
for working *on* the extension; the skill is for working *with* it.

## Commands

```bash
make docker-test                  # full regression run in a throwaway container (PG_MAJOR=16 default)
make docker-test PG_MAJOR=14      # oldest supported major; CI runs 14, 15, 16, 17
make install                      # copy control + SQL into the server's extension dir (needs pg_config on PATH)
make install PG_CONFIG=/path/to/pg_config
python3 test/mock_api.py &        # deterministic stand-in for the TypeSafe API on 127.0.0.1:8765
make installcheck                 # pg_regress against a running server; needs mock_api.py running
bash test/run.sh                  # what CI does: temp cluster (PGPORT=5499) + mock API + make installcheck
make dist                         # PGXN zip from git HEAD
```

Run a single test: `make installcheck REGRESS="01_basic 03_streaming"` (tests are `test/sql/<name>.sql`, expected
output in `test/expected/<name>.out`, failures land in `test/regression.diffs` and `test/results/`). Only
`01_basic.sql` runs `CREATE EXTENSION jev`, so it must be included, or pass `REGRESS_OPTS="... --load-extension=jev"`.

When a test's output changes intentionally, copy `test/results/<name>.out` over `test/expected/<name>.out` and
review the diff. Tests **never** call the live API; `test/run.sh` unsets `TYPESAFE_API_KEY`.

There is no linter. `.editorconfig` applies (4-space indent, tabs in the Makefile, 2 spaces in yml/json/md).

## Architecture

### Where the code is

- `sql/jev--<version>.sql` — the entire extension. `_jev_eval(rel_type, row_json, query, kind, options)` is a
  ~450-line `plpython3u` function; the public functions (`jev`, `jev_prob`, `jev_score`, `jev_score_norm`,
  `jev_choice`, `jev_confidence`, `jev_eval`) are thin SQL wrappers that call it with
  `pg_typeof(row)::text` and `to_json(row)::text`. `jev_stats`, `jev_cache_clear`, `jev_version` are separate.
- `sql/jev--<old>--<new>.sql` — upgrade scripts. Every object is `CREATE OR REPLACE`, so an upgrade script is a
  copy of the full script with the `\echo` guard changed to `ALTER EXTENSION jev UPDATE`.
- `jev.control` (`default_version`), `META.json` (PGXN), `CHANGELOG.md` — must all agree on the version; CI's
  `lint-meta` job checks `jev.control` == `META.json` and that `sql/jev--<version>.sql` exists.
- `test/mock_api.py` — the fake API. Its rules decide expected output: `noul` → 0.9 if the *last word* of the
  condition appears in the row JSON else 0.1; `score`/`choice` → index = `len(row_json) % n`; a condition
  containing `trigger422` returns HTTP 422; auth requires `Bearer test-key`.

### How one statement runs (the part that needs several files to understand)

1. The SQL wrapper serialises the row with `to_json` (column order preserved) and passes the relation type name.
2. `_jev_eval` keys everything on `cache_key = [rel_type, query, kind, options]` and `row_hash = sha1(row_json)`.
   Cache hit → return immediately (no SPI call).
3. On the first miss for a table + question it creates a **job**: a read-ahead that streams the relation in
   physical order via SPI — TID range scans (`WHERE ctid >= $1 AND ctid < $2`) for tables/matviews, `OFFSET/LIMIT`
   pages for views/partitioned/foreign tables, `PAGE_ROWS = 1000` per SPI query. Rows from a subquery/CTE
   (anonymous `record`) have no relation and are judged one request at a time.
4. Rows are packed `jev.batch_size` (20) per request into one shared `state` with one question per row
   (`build_question`, `request_body`), sent from a per-session `ThreadPoolExecutor` over pooled keep-alive
   `http.client` connections (`borrow_conn`/`release_conn`, retries honour `Retry-After`). Up to
   2 × `jev.concurrency` requests are in flight; `answer()` waits on the row's future in 250 ms slices so
   `statement_timeout`/cancel work.
5. Rows the executor never asks for (filtered by cheaper predicates, or cut off by `LIMIT`) are kept in
   `skipped`/`skipped_map` (bounded by `jev.max_prefetch_rows`) and batched with neighbours if requested later.
6. All state lives in PL/Python `GD["jev"]` for the backend session: cache, jobs, stats, prepared plans, thread
   pool, connection pool and the per-statement spend guard (`jev.max_rows_per_statement` /
   `jev.max_chars_per_statement`, keyed on `statement_timestamp()`). `STATE_VERSION` resets it on upgrade.
7. Settings are plain GUCs read in a single SPI query per cache miss (`load_cfg`); defaults live there and in
   the header comment of the SQL file, README and docs — keep all four in sync.

Threads must never touch `plpy`; only the main thread does SPI, `plpy.notice` and `plpy.error`.

## Rules for changes

- Every behaviour change needs a regression test in `test/sql/` with matching `test/expected/` output, written
  against the mock API's rules above.
- Keep the SQL API stable. New functions are fine; changing a signature needs a major version and an upgrade script.
- Changing the model prompt (`instructions`/`criteria` in `build_question`) changes results for every user: include
  what was measured on real data (see the "Why 20 rows per request" numbers in README/CHANGELOG for the bar).
- Don't raise `jev.batch_size` defaults above ~20: accuracy measurably drops because the model locates `rows[i]`
  by position.
- Release: bump `jev.control`, add `sql/jev--X.Y.Z.sql` and `sql/jev--OLD--X.Y.Z.sql`, update `jev_version()`,
  `META.json`, `CHANGELOG.md`, then tag `vX.Y.Z` (the release workflow builds the PGXN zip). Full checklist in
  `docs/PUBLISHING.md`.
- Supported: PostgreSQL 14–17 with `plpython3u`. Only superusers can `CREATE EXTENSION jev`.
