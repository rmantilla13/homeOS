#!/usr/bin/env bash
# Spins up a throwaway Postgres, applies the core migration + seed, and runs
# the RLS/points tests. Usage: backend/tests/run.sh  (PG_BIN overrides the
# Postgres binary directory; run as a non-root user or as root with `postgres` present).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
supa="$here/../supabase"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
tmp="$(mktemp -d /tmp/homeos-pg.XXXX)"
port=5499

as_pg() { if [ "$(id -u)" = 0 ]; then su postgres -c "$*"; else bash -c "$*"; fi; }
[ "$(id -u)" = 0 ] && chown postgres "$tmp"
cleanup() { as_pg "$PG_BIN/pg_ctl -D $tmp/data stop -m fast" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

as_pg "$PG_BIN/initdb -D $tmp/data -A trust -U postgres" >/dev/null
as_pg "$PG_BIN/pg_ctl -D $tmp/data -o '-p $port -k $tmp' -l $tmp/pg.log -w start" >/dev/null

psql=(psql -h "$tmp" -p "$port" -U postgres -q -v ON_ERROR_STOP=1)
"${psql[@]}" -d postgres -c 'create database homeos'
"${psql[@]}" -d homeos -f "$here/stub_auth.sql" \
  -f "$supa/migrations/20261006000001_core_schema.sql" \
  -f "$supa/migrations/20261006000003_family_memories.sql" -f "$supa/seed.sql"
"${psql[@]}" -d homeos -f "$here/rls_test.sql"
echo "RLS tests passed"
