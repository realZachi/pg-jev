#!/usr/bin/env bash
# Starts a temporary cluster + the mock API, then runs `make installcheck`.
# Used by test/Dockerfile and CI; works locally too if pg_ctl/initdb are on PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
PGBIN="$(pg_config --bindir)"
export PGDATA="${PGDATA:-/tmp/pg-jev-data}"
export PGPORT="${PGPORT:-5499}"
export PGHOST=/tmp
export PGUSER="${PGUSER:-$(whoami)}"
unset TYPESAFE_API_KEY

if [ ! -f "$PGDATA/PG_VERSION" ]; then "$PGBIN/initdb" -D "$PGDATA" -U "$PGUSER" --auth=trust >/dev/null; fi
"$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k /tmp -c listen_addresses=''" -l "$PGDATA/log" -w start >/dev/null
python3 test/mock_api.py 8765 & MOCK=$!
trap '"$PGBIN/pg_ctl" -D "$PGDATA" -m fast stop >/dev/null; kill $MOCK 2>/dev/null' EXIT
sleep 1

if make installcheck; then
  echo "jev: all regression tests passed"
else
  echo "jev: regression tests FAILED"; cat test/regression.diffs 2>/dev/null || true; exit 1
fi
