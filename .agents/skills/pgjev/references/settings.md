# Settings (GUCs)

Docs: https://pgjev.com/docs/settings.md

Every setting is a plain PostgreSQL custom GUC under the `jev.` prefix, so all the usual scopes apply:

```sql
SET jev.threshold = 0.7;                            -- this session
SET LOCAL jev.max_rows_per_statement = 500;         -- this transaction
ALTER ROLE analyst SET jev.api_key = '...';         -- persistent for one role
ALTER DATABASE app SET jev.concurrency = 8;         -- persistent for one database
-- postgresql.conf:  jev.notices = off
SHOW jev.batch_size;                                -- current value ('' if never set → default applies)
```

Settings are read once per cache miss (one SPI query), so changing one takes effect on the next uncached call.

| Setting | Default | Meaning | Change it when |
| --- | --- | --- | --- |
| `jev.api_key` | env `TYPESAFE_API_KEY` of the server | TypeSafe API key; optional when `jev.api_url` is not a `*.typesafe.ai` host | always for the TypeSafe API, unless the server env has it |
| `jev.model` | `jev-latest` | model name or pinned version such as `jev-1.13.0` | you need reproducible answers across model releases |
| `jev.threshold` | `0.5` | probability at which `jev()` returns true (the third argument of `jev()` overrides it) | you want stricter/looser matches without editing every query |
| `jev.batch_size` | `20` | rows per API request | rarely; accuracy drops measurably above ~20–25 because the model finds `rows[i]` by position. Lower it for very wide rows if you see drift |
| `jev.concurrency` | `16` | parallel API requests; up to 2× that many are queued ahead of the executor | lower on 429s or to be gentle on a shared key; raising it beyond 16 gives little |
| `jev.max_prefetch_rows` | `5000` | how far read-ahead searches and how many skipped rows it retains; not a bound on the per-session answer cache or total session memory | queries with index scans/joins that request rows far apart; tune skipped-row retention only |
| `jev.notices` | `on` | `NOTICE` per finished request plus a per-table summary (rows, requests, tokens, ≈cost, ms) | `off` in applications and tests |
| `jev.api_url` | `https://api.typesafe.ai/v1/systemone` | endpoint | proxies, the regression mock (`http://127.0.0.1:8765/v1/systemone`), local Jev-compatible servers such as [stuntd](https://github.com/bladedevoff/stuntd) (`http://127.0.0.1:8787/v1/systemone`) or laya-server: no external calls, no per-row billing |
| `jev.timeout` | `30` | seconds per API request. Waits are interruptible: `statement_timeout` and cancel apply within 250 ms | slow networks |
| `jev.keepalive` | `600` | seconds a pooled HTTPS connection may idle before it is reconnected | proxies that drop idle connections sooner |
| `jev.max_rows_per_statement` | `0` (off) | abort a statement that would send more rows than this to the API | shared servers, ad-hoc users, anything where a missing `WHERE` would be expensive |
| `jev.max_chars_per_statement` | `0` (off) | same, for characters of row data | wide rows / token budget |

The per-session answer cache can grow with unique row/question pairs until `jev_cache_clear()` clears it or the
backend session ends. `jev.max_prefetch_rows` does not limit that cache.

## Recommended baseline for a shared server

```sql
ALTER DATABASE app SET jev.max_rows_per_statement = 5000;
ALTER DATABASE app SET jev.max_chars_per_statement = 2000000;
ALTER ROLE analyst SET jev.api_key = '...';
ALTER ROLE analyst SET jev.model = 'jev-1.13.0';     -- pin if results feed a report
```

Guard errors read
`jev: this statement would send N rows to the API, above jev.max_rows_per_statement = M`, so users know why and
can add a filter or raise the limit with `SET LOCAL` for one statement.

## Where the API key comes from

Precedence: `jev.api_key` GUC (any scope) → `TYPESAFE_API_KEY` in the **server process** environment. The
client's shell does not count. Setting `jev.api_key = ''` disables the GUC and falls back to the environment.

A key is only required when `jev.api_url` is a `*.typesafe.ai` host. Against any other endpoint (a local
Jev-compatible server, a proxy that adds auth itself) requests go out without an `Authorization` header when no
key is set; a key that is set is still sent as `Bearer <key>`. An endpoint that rejects that surfaces as
`jev: TypeSafe API error 401 ...`. The token and cost figures in `jev_stats()` and notices assume TypeSafe's list
price regardless of the endpoint.
