# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- With `jev.notices` on, one `NOTICE` per finished API request while a table is being judged
  (`jev: progress 12/50 requests, 480/2000 rows`), so clients that stream notices can show a live progress bar.

## [0.1.0] - 2026-09-17

### Added
- `jev()`, `jev_prob()`, `jev_score()`, `jev_score_norm()`, `jev_choice()`, `jev_confidence()`, `jev_eval()`.
- Whole-table read-ahead with batched, concurrent requests and a per-session answer cache.
- `jev_stats()` and `jev_cache_clear()`.
- Settings: `jev.api_key`, `jev.model`, `jev.threshold`, `jev.batch_size`, `jev.concurrency`,
  `jev.max_prefetch_rows`, `jev.notices`, `jev.api_url`, `jev.timeout`, and the spend guards
  `jev.max_rows_per_statement`, `jev.max_chars_per_statement`.
- Regression suite against a deterministic mock API; CI for PostgreSQL 14–17.
