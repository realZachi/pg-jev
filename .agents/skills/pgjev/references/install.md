# Installing pgjev

Docs: https://pgjev.com/docs/getting-started/where-it-runs.md,
https://pgjev.com/docs/getting-started/installation.md, https://pgjev.com/docs/getting-started/docker.md,
https://pgjev.com/docs/getting-started/quick-start.md

## Requirements (check before anything else)

| Requirement | Why | How to check |
| --- | --- | --- |
| PostgreSQL 14, 15, 16 or 17 | tested majors (CI runs all four) | `SHOW server_version;` |
| `plpython3u` available | the extension is one PL/Python function | `SELECT * FROM pg_available_extensions WHERE name = 'plpython3u';` |
| superuser | `plpython3u` is an untrusted language; only superusers may `CREATE EXTENSION jev` | `SELECT rolsuper FROM pg_roles WHERE rolname = current_user;` |
| outbound HTTPS from the **server** to `api.typesafe.ai:443` | the database process makes the API calls | firewall / egress rules |
| a TypeSafe API key | https://console.typesafe.ai | — |

`scripts/check_server.sh` runs the SQL checks and prints a verdict. It accepts the same connection arguments as
`psql` (`-h`, `-p`, `-U`, `-d`, or a URI) and honours `PGHOST`/`PGUSER`/`PGDATABASE`/`PGPASSWORD`.

### Hosts where it cannot run

Supabase, Neon, Crunchy Bridge, most Cloud SQL / RDS / Aurora / Azure Database setups: they withhold superuser
or do not ship `plpython3u`. There is no workaround short of running your own Postgres (VM, bare metal, Docker,
Kubernetes). Say so up front; do not send users down a build path that ends at `permission denied`.

### Getting `plpython3u`

| Platform | Package / note |
| --- | --- |
| Debian / Ubuntu (PGDG or distro packages) | `apt install postgresql-plpython3-NN` (NN = major, e.g. `16`) |
| RHEL / Fedora / Rocky (PGDG) | `dnf install postgresqlNN-plpython3` |
| macOS Postgres.app | included |
| EDB installers (Windows, macOS, Linux) | included (choose the language pack if asked) |
| Homebrew `postgresql@NN` | built with Python; `plpython3u` is available |
| Official `postgres:NN` Docker image | not included; the repo `Dockerfile` adds `postgresql-plpython3-NN` |

`jev.control` lists `plpython3u` in `requires`, but Postgres only creates a required extension for you with
`CASCADE`. Without it a fresh database fails with `required extension "plpython3u" is not installed`, so always
write `CREATE EXTENSION jev CASCADE` (or create `plpython3u` first).

## Install from PGXN

The release is published on the PostgreSQL Extension Network (https://pgxn.org/dist/jev/). `pgxn install`
downloads the distribution and runs the same `make install` as the source path, so it needs `make` and the
target server's `pg_config` too, but no git clone and no checkout to keep around.

```bash
pip install pgxnclient                   # once; also `apt install pgxn-client` / `brew install pgxnclient`
pgxn install jev                         # latest release, pg_config from PATH
pgxn install jev --pg_config=/usr/lib/postgresql/16/bin/pg_config
sudo pgxn install jev                    # when the extension directory is root-owned
pgxn install 'jev=0.2.0'                 # pin a version
```

Then `CREATE EXTENSION jev CASCADE;` as a superuser (see below). `scripts/install.sh --pgxn` does both steps and
maps `--pg-config`, `--ref` and `--sudo` onto the `pgxn` flags. If `pgxn install jev` reports that the
distribution is not found, the release is not on PGXN yet: fall back to source.

## Install from source (PGXS)

There is nothing to compile: `make install` copies `jev.control` and `sql/jev--*.sql` into the extension
directory of the Postgres that `pg_config` points at. You need `make` and `pg_config` (package
`postgresql-server-dev-NN` on Debian/Ubuntu, `postgresqlNN-devel` on RHEL; included in Postgres.app/EDB/Homebrew).

```bash
git clone https://github.com/realZachi/pg-jev.git && cd pg-jev
make install                                   # pg_config from PATH
make install PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config   # or a specific server
```

`make install` may need `sudo` when the extension directory is owned by root (typical for distro packages):
`sudo make install PG_CONFIG=...`.

Then, connected as a superuser to the target database:

```sql
CREATE EXTENSION jev CASCADE;    -- CASCADE also creates plpython3u
SELECT jev_version();
```

`scripts/install.sh` automates this: it clones (or uses `--source DIR`, or `pgxn install` with `--pgxn`), runs `make install` with the chosen
`pg_config`, and runs `CREATE EXTENSION IF NOT EXISTS jev CASCADE` in `--db`. Use `--ref vX.Y.Z` to pin a release and
`--no-create` to skip the SQL step (e.g. when the SQL must run as a different user).

The extension is created per database. Repeat `CREATE EXTENSION jev CASCADE` in every database that needs it.

### Upgrading

```bash
git pull && make install PG_CONFIG=...
```

```sql
ALTER EXTENSION jev UPDATE;      -- runs sql/jev--OLD--NEW.sql
SELECT jev_version();
```

Session state (`GD`) is versioned, so already-connected sessions pick up the new code on their next call.

## Docker

For trying it out, or when the host Postgres cannot take `plpython3u`:

```bash
git clone https://github.com/realZachi/pg-jev.git && cd pg-jev
docker build -t pg-jev .                          # postgres:16 + plpython3u + jev files
docker build --build-arg PG_MAJOR=17 -t pg-jev .  # another major
docker run -d --name pg-jev -p 5432:5432 -e POSTGRES_PASSWORD=pw -e TYPESAFE_API_KEY=your-key pg-jev
psql postgres://postgres:pw@localhost/postgres -c "CREATE EXTENSION jev CASCADE"
```

The image does not create the extension automatically. To have it created on first start, mount an init script:
`echo 'CREATE EXTENSION jev CASCADE;' > init.sql` and add `-v $PWD/init.sql:/docker-entrypoint-initdb.d/jev.sql`.

## API key placement

`jev.api_key` is read on every cache miss with this precedence: GUC (`SET`, role, database, `postgresql.conf`)
→ `TYPESAFE_API_KEY` in the environment of the **postgres server process**. The client's shell environment is
irrelevant.

| Scope | How | Use when |
| --- | --- | --- |
| this session | `SET jev.api_key = '...';` | trying it out, notebooks |
| one role, persistent | `ALTER ROLE analyst SET jev.api_key = '...';` | per-team keys, shared server |
| one database | `ALTER DATABASE app SET jev.api_key = '...';` | one key per app |
| whole server | `TYPESAFE_API_KEY` in the service environment (systemd `Environment=`, Docker `-e`) | single-tenant server |

Role/database settings are visible to that role via `SHOW jev.api_key`; keep keys out of committed SQL files and
dashboards. `scripts/smoke_test.sql` never prints the key.

## Verify

```bash
psql -d mydb -f scripts/smoke_test.sql
```

Expected: a temp table of five rows, one result per function, a `NOTICE` like
`jev: noul → judged 5 rows of jev_smoke in 1 request, ~300 input tokens (≈$0.0000), … ms` and a `jev_stats()`
row with `requests ≥ 1` and `errors = 0`.

## Troubleshooting

| Message / symptom | What it means | Fix |
| --- | --- | --- |
| `could not open extension control file ".../jev.control"` | files were installed into another Postgres | `make install PG_CONFIG=<pg_config of the server you connect to>`; compare `pg_config --sharedir` with `SHOW data_directory`/version |
| `could not open extension control file ".../plpython3u.control"` | PL/Python not installed | install `postgresql-plpython3-NN`; on managed hosts: not possible |
| `required extension "plpython3u" is not installed` | `CREATE EXTENSION jev` without `CASCADE` on a database where PL/Python was never created | `CREATE EXTENSION jev CASCADE;` |
| `pgxn: command not found` | pgxnclient not installed | `pip install pgxnclient` (or the distro package), or use the source path |
| `pgxn install jev` → distribution not found / no release | not on PGXN (yet), or a typo in the pin | check https://pgxn.org/dist/jev/; install from source |
| `permission denied to create extension "jev"` / `must be superuser` | not a superuser | connect as one (`postgres`) or ask the DBA |
| `jev: no API key. SET jev.api_key = '...' or start the server with TYPESAFE_API_KEY set.` | no GUC and no server env | see API key placement; `TYPESAFE_API_KEY` in your shell is not the server's |
| `jev: TypeSafe API error 401 {...}` | invalid key | check the key in console.typesafe.ai |
| `jev: TypeSafe API error 422 {...}` | request rejected (bad model name, malformed options) | check `jev.model`, options arrays |
| `jev: TypeSafe API error 429/5xx` after retries | rate limit / outage; the extension retries with `Retry-After` | lower `jev.concurrency`, retry later |
| connection errors / timeouts, `jev.timeout` reached | server cannot reach `api.typesafe.ai:443` | egress firewall, proxy (`jev.api_url` can point at a proxy) |
| `jev: this statement would send N rows … above jev.max_rows_per_statement` | spend guard | pre-filter in SQL, or raise the guard deliberately |
| `NOTICE`s show one request per row | `jev()` on a CTE/subquery (`record`) | call it on the base table or a view |
| `CREATE EXTENSION` works but functions are missing in another database | extensions are per database | `CREATE EXTENSION jev CASCADE` there too |
| a `LIMIT 1` query still takes seconds | the first request on a fresh connection pays TLS + server setup (up to ~1.5 s); after that ~0.3 s | keep sessions alive; `jev.keepalive` (600 s) keeps pooled connections |

`SELECT jev_stats();` (`errors`, `retries`, `requests`, `api_ms`) tells you whether calls are reaching the API.
`SET jev.notices = on;` (default) prints progress per request.
