#!/usr/bin/env bash
# Preflight for pgjev: can this PostgreSQL server run the jev extension, and is it set up?
#
#   bash check_server.sh [psql connection args]        e.g.  bash check_server.sh -h db.example.com -U postgres -d app
#
# Uses PGHOST / PGPORT / PGUSER / PGDATABASE / PGPASSWORD like psql. Exit code 0 = ready to CREATE EXTENSION or
# already installed, 1 = something blocks it (the report says what), 2 = could not connect.
set -uo pipefail

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not found on PATH. Install the PostgreSQL client tools first." >&2; exit 2
fi

q() { psql "$@" -X -A -t -v ON_ERROR_STOP=1 2>&1; }

if ! out=$(q "$@" -c "SELECT 1"); then
  echo "Cannot connect: $out" >&2; exit 2
fi

version=$(q "$@" -c "SELECT split_part(current_setting('server_version'), ' ', 1)")
major=$(q "$@" -c "SELECT current_setting('server_version_num')::int / 10000")
superuser=$(q "$@" -c "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
dbname=$(q "$@" -c "SELECT current_database()")
plpy_avail=$(q "$@" -c "SELECT count(*) FROM pg_available_extensions WHERE name = 'plpython3u'")
plpy_inst=$(q "$@" -c "SELECT count(*) FROM pg_extension WHERE extname = 'plpython3u'")
jev_avail=$(q "$@" -c "SELECT coalesce(max(default_version), '') FROM pg_available_extensions WHERE name = 'jev'")
jev_inst=$(q "$@" -c "SELECT coalesce(max(extversion), '') FROM pg_extension WHERE extname = 'jev'")
key_guc=$(q "$@" -c "SELECT CASE WHEN coalesce(current_setting('jev.api_key', true), '') <> '' THEN 'set' ELSE '' END")

blockers=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [warn] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; blockers=$((blockers + 1)); }

echo "pgjev preflight on database '$dbname'"
if [ "$major" -ge 14 ] && [ "$major" -le 17 ]; then ok "PostgreSQL $version (supported: 14-17)"
elif [ "$major" -gt 17 ]; then warn "PostgreSQL $version is newer than the tested majors (14-17); it will probably work"
else bad "PostgreSQL $version is too old; pgjev needs 14 or newer"; fi

if [ "$plpy_avail" = "1" ]; then ok "plpython3u is available$( [ "$plpy_inst" = "1" ] && echo ' (and already created in this database)')"
else bad "plpython3u is not available. Install postgresql-plpython3-$major (Debian/Ubuntu) or postgresql$major-plpython3 (RHEL). Managed hosts (Supabase, Neon, RDS...) cannot add it."; fi

if [ "$superuser" = "t" ]; then ok "connected as a superuser ($(q "$@" -c 'SELECT current_user'))"
else
  if [ -n "$jev_inst" ]; then warn "not a superuser; fine for using jev, but CREATE/ALTER EXTENSION needs one"
  else bad "not a superuser; CREATE EXTENSION jev requires one because plpython3u is untrusted"; fi
fi

if [ -n "$jev_inst" ]; then
  if [ -n "$jev_avail" ] && [ "$jev_avail" != "$jev_inst" ]; then
    warn "jev $jev_inst is installed; version $jev_avail is on disk. Run: ALTER EXTENSION jev UPDATE;"
  else ok "jev $jev_inst is installed in this database"; fi
elif [ -n "$jev_avail" ]; then
  ok "jev $jev_avail files are on disk; run CREATE EXTENSION jev CASCADE; in this database"
else
  echo "  [todo] jev files are not installed for this server: run scripts/install.sh (make install), then CREATE EXTENSION jev CASCADE"
fi

if [ "$key_guc" = "set" ]; then ok "jev.api_key is set for this session/role/database"
else warn "jev.api_key is not set in the GUC; the server falls back to TYPESAFE_API_KEY in *its* environment (cannot be checked from SQL). Set it with SET jev.api_key = '...' or ALTER ROLE ... SET jev.api_key = '...' if the first query fails with 'jev: no API key'."; fi

echo
if [ "$blockers" -eq 0 ]; then echo "Verdict: this server can run pgjev."; exit 0
else echo "Verdict: $blockers blocker(s) above must be resolved first."; exit 1; fi
