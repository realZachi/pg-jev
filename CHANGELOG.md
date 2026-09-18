# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-09-18

Measured against the live API on a 2,000-row table (from Europe, ~190 ms RTT to the API): first run
8.5 s → 3.5 s, `LIMIT 3` on a fresh condition 8.4 s → 0.6 s, 12 % fewer input tokens, and answers that
match single-row evaluation instead of drifting.

### Changed
- **Streaming read-ahead.** A table is no longer read whole (up to `jev.max_prefetch_rows`) before the first
  answer. It is streamed in physical order (TID range scans for tables, `OFFSET` pages for views), judged in
  batches with up to 2 × `jev.concurrency` requests in flight, and each row is answered as soon as its batch
  returns. Memory is constant whatever the table size; rows beyond the old 5,000-row limit were previously
  judged one request at a time. A `LIMIT` stops the read-ahead after the in-flight window. Rows that cheaper
  predicates filter out before `jev()` runs are skipped instead of judged. Rows requested out of physical
  order (backward index scans, joins) are batched with their neighbours instead of judged one by one.
- **Persistent HTTPS connections.** Requests reuse keep-alive connections across batches and statements
  (one TLS handshake per connection instead of one per request: 880 ms → 300 ms per request from Europe).
- **`jev.batch_size` default 40 → 20.** Ground-truth tests (job title, EU membership, a phrase in a free-text
  field) are 100 % correct up to 20 rows per request and fall to 92–98 % at 40 and to 77–94 % at 80: the model
  has to find `rows[i]` by position, and that gets unreliable in long arrays. The cost is +4 % input tokens.
- **Noul questions no longer carry the generic `criteria`** ("the record satisfies the condition"): they cost
  16 % of all input tokens and changed no answers.
- **`jev.concurrency` default 6 → 16.** The API handles 16 parallel requests without queueing.
- **`jev.timeout` default 90 → 30 seconds.** Waits are also interruptible now: `statement_timeout` and
  cancel requests take effect within 250 ms instead of after the HTTP timeout.
- `429`/`529`/`5xx` retries honour `Retry-After`. Pooled connections are checked before reuse (closed by the
  server, or idle for more than `jev.keepalive` = 600 s) and carry TCP keepalive probes, so a request is never
  sent into a dead socket; a connection that still fails is retried at once on a fresh one. Keeping connections
  matters: the first request on a fresh connection was measured at 0.9–1.9 s against 0.3 s afterwards.
- `jev.max_prefetch_rows` now bounds how far the read-ahead scans past a cache miss (and how many skipped
  rows it remembers), not the size of the table it can handle.
- Rows are serialised with `to_json` (column order preserved) instead of `to_jsonb` (keys sorted by length).
- A cache hit costs no SPI call at all; settings are read in one query per cache miss.
- `jev_stats()` gains `retries`, `in_flight` and `connections` (idle, pooled).

### Added
- With `jev.notices` on, one `NOTICE` per finished API request while a table is being judged
  (`jev: progress 12/50 requests, 480/2000 rows`), so clients that stream notices can show a live progress bar.
- Setting `jev.keepalive` (default 600 s): how long an idle pooled API connection is kept before it is
  reconnected. Measured: connections stay usable for at least 10–15 minutes of idle time.
- Upgrade script `jev--0.1.0--0.2.0.sql` (`ALTER EXTENSION jev UPDATE`).
- Regression tests for streaming, `LIMIT`, filtered scans, backward index scans and views.

## [0.1.0] - 2026-09-17

### Added
- `jev()`, `jev_prob()`, `jev_score()`, `jev_score_norm()`, `jev_choice()`, `jev_confidence()`, `jev_eval()`.
- Whole-table read-ahead with batched, concurrent requests and a per-session answer cache.
- `jev_stats()` and `jev_cache_clear()`.
- Settings: `jev.api_key`, `jev.model`, `jev.threshold`, `jev.batch_size`, `jev.concurrency`,
  `jev.max_prefetch_rows`, `jev.notices`, `jev.api_url`, `jev.timeout`, and the spend guards
  `jev.max_rows_per_statement`, `jev.max_chars_per_statement`.
- Regression suite against a deterministic mock API; CI for PostgreSQL 14–17.
