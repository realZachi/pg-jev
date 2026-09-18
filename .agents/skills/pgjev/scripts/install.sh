#!/usr/bin/env bash
# Install the jev extension from source: clone (or use a checkout), `make install`, then CREATE EXTENSION.
#
#   bash install.sh [--source DIR] [--ref vX.Y.Z] [--pg-config PATH] [--db NAME] [--no-create] [--sudo]
#
#   --source DIR      use an existing pg-jev checkout instead of cloning (default: clone into a temp dir;
#                     if the current directory is a pg-jev checkout it is used automatically)
#   --ref REF         git tag/branch to check out after cloning (default: default branch)
#   --pg-config PATH  pg_config of the target server (default: pg_config on PATH)
#   --db NAME         database in which to CREATE EXTENSION (default: $PGDATABASE or the psql default)
#   --no-create       stop after `make install`; print the SQL to run instead
#   --sudo            run `make install` with sudo (needed when the extension dir is owned by root)
#
# psql connection details come from PGHOST/PGPORT/PGUSER/PGPASSWORD. Nothing here is compiled: make install
# copies jev.control and sql/jev--*.sql into `pg_config --sharedir`/extension.
set -euo pipefail

REPO=https://github.com/realZachi/pg-jev.git
source_dir="" ref="" pg_config="${PG_CONFIG:-pg_config}" db="${PGDATABASE:-}" create=1 use_sudo=0
while [ $# -gt 0 ]; do
  case "$1" in
    --source) source_dir=$2; shift 2 ;;
    --ref) ref=$2; shift 2 ;;
    --pg-config) pg_config=$2; shift 2 ;;
    --db) db=$2; shift 2 ;;
    --no-create) create=0; shift ;;
    --sudo) use_sudo=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! command -v "$pg_config" >/dev/null 2>&1; then
  echo "pg_config not found ($pg_config). Install the server dev package (postgresql-server-dev-NN / postgresqlNN-devel) or pass --pg-config." >&2
  exit 2
fi
command -v make >/dev/null 2>&1 || { echo "make not found. Install build-essential / make." >&2; exit 2; }

if [ -z "$source_dir" ] && [ -f jev.control ] && [ -d sql ]; then source_dir=$PWD; fi
if [ -z "$source_dir" ]; then
  command -v git >/dev/null 2>&1 || { echo "git not found." >&2; exit 2; }
  source_dir=$(mktemp -d "${TMPDIR:-/tmp}/pg-jev.XXXXXX")
  echo "Cloning $REPO into $source_dir"
  git clone --quiet --depth 1 ${ref:+--branch "$ref"} "$REPO" "$source_dir"
fi
[ -f "$source_dir/jev.control" ] || { echo "$source_dir is not a pg-jev checkout (no jev.control)." >&2; exit 2; }

version=$(sed -n "s/default_version *= *'\(.*\)'/\1/p" "$source_dir/jev.control")
extdir="$("$pg_config" --sharedir)/extension"
echo "Installing jev $version into $extdir (server: $("$pg_config" --version))"

install_cmd=(make -C "$source_dir" install "PG_CONFIG=$pg_config")
if [ "$use_sudo" -eq 1 ]; then sudo "${install_cmd[@]}"
elif [ -w "$extdir" ]; then "${install_cmd[@]}"
elif command -v sudo >/dev/null 2>&1; then
  echo "$extdir is not writable by $(whoami); running make install with sudo."
  sudo "${install_cmd[@]}"
else
  echo "$extdir is not writable by $(whoami) and sudo is not available. Run as a user that owns it:" >&2
  echo "  ${install_cmd[*]}" >&2
  exit 1
fi

sql="CREATE EXTENSION IF NOT EXISTS jev CASCADE; SELECT jev_version();"
if [ "$create" -eq 0 ]; then
  echo "Files installed. Now run as a superuser in each database that needs it:"; echo "  $sql"; exit 0
fi

command -v psql >/dev/null 2>&1 || { echo "psql not found; run this as a superuser in your database:"; echo "  $sql"; exit 0; }
echo "Creating the extension${db:+ in database $db}"
if psql ${db:+-d "$db"} -X -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS jev CASCADE" -c "SELECT jev_version()"; then
  echo "Done. Next: SET jev.api_key = '...' (or TYPESAFE_API_KEY in the server environment), then run scripts/smoke_test.sql."
else
  echo "CREATE EXTENSION failed. Common causes: not a superuser, plpython3u not installed for this server, or the" >&2
  echo "files went into a different Postgres than the one psql connects to (compare --pg-config with the server)." >&2
  exit 1
fi
