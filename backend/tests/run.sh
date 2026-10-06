#!/usr/bin/env bash
# Spins up a throwaway Postgres, applies the migrations + seed on top of a
# Supabase stand-in, and runs each tests/*_test.sql in its own fresh copy of
# that database.
#
#   backend/tests/run.sh               # every test
#   backend/tests/run.sh invites admin # just these (names without _test.sql)
#
#   PG_BIN     Postgres binary directory (default: newest /usr/lib/postgresql/*/bin)
#   PGPORT     server port (default: first free one from 5499)
#   VERBOSE=1  print each test's output, not only failures
#
# Runs as a normal user, or as root when a `postgres` OS user exists.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
supa="$here/../supabase"

# Migrations that need Supabase itself (storage, realtime). The plain run
# skips them; the tests in supabase_tests get them on top of stub_storage.sql.
supabase_only=(20261006000002_storage_realtime.sql 20261007000005_storage_avatars.sql)
supabase_tests=(storage_test)

PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
if [ ! -x "$PG_BIN/initdb" ]; then
  echo "PostgreSQL server binaries not found; install postgresql or set PG_BIN" >&2
  exit 1
fi

port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
port="${PGPORT:-}"
if [ -z "$port" ]; then
  for p in $(seq 5499 5599); do
    if ! port_in_use "$p"; then port=$p; break; fi
  done
  port="${port:-5499}"
fi

tmp="$(mktemp -d /tmp/homeos-pg.XXXXXX)"
if [ "$(id -u)" = 0 ]; then
  id postgres >/dev/null 2>&1 || { echo "running as root needs a 'postgres' OS user" >&2; exit 1; }
  chown postgres "$tmp"
  as_pg() { (cd "$tmp" && su postgres -c "$*"); }
else
  as_pg() { bash -c "$*"; }
fi
cleanup() { as_pg "$PG_BIN/pg_ctl -D $tmp/data stop -m fast" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

as_pg "$PG_BIN/initdb -D $tmp/data -A trust -U postgres" >/dev/null
# TCP stays off: the server only listens on a socket inside $tmp.
if ! as_pg "$PG_BIN/pg_ctl -D $tmp/data -o \"-p $port -k $tmp -c listen_addresses=''\" -l $tmp/pg.log -w start" >/dev/null; then
  cat "$tmp/pg.log" >&2
  exit 1
fi

psql=(psql -X -h "$tmp" -p "$port" -U postgres -q -v ON_ERROR_STOP=1)

is_supabase_only() { local s; for s in "${supabase_only[@]}"; do [ "$1" = "$s" ] && return 0; done; return 1; }

# build_template <db> <with Supabase-only migrations: yes|no>
build_template() {
  local db=$1 full=$2 m args=(-f "$here/stub_auth.sql")
  [ "$full" = yes ] && args+=(-f "$here/stub_storage.sql")
  for m in "$supa"/migrations/*.sql; do
    if [ "$full" = no ] && is_supabase_only "$(basename "$m")"; then continue; fi
    args+=(-f "$m")
  done
  args+=(-f "$supa/seed.sql" -f "$here/helpers.sql")
  "${psql[@]}" -d postgres -c "create database $db"
  if ! "${psql[@]}" -d "$db" "${args[@]}" >"$tmp/$db.log" 2>&1; then
    echo "FAIL setting up $db:" >&2
    cat "$tmp/$db.log" >&2
    exit 1
  fi
}

build_template homeos_plain no
build_template homeos_supabase yes

if [ $# -gt 0 ]; then
  tests=(); for n in "$@"; do tests+=("$here/${n%_test.sql}_test.sql"); done
else
  tests=("$here"/*_test.sql)
fi

failed=0
for t in "${tests[@]}"; do
  name="$(basename "$t" .sql)"
  template=homeos_plain
  for s in "${supabase_tests[@]}"; do [ "$name" = "$s" ] && template=homeos_supabase; done
  "${psql[@]}" -d postgres -c "create database \"$name\" template $template"
  if "${psql[@]}" -d "$name" -f "$t" >"$tmp/$name.log" 2>&1; then
    echo "ok    $name"
    [ "${VERBOSE:-0}" = 1 ] && cat "$tmp/$name.log"
  else
    echo "FAIL  $name"
    cat "$tmp/$name.log"
    failed=1
  fi
done

if [ "$failed" = 0 ]; then
  echo "All database tests passed"
else
  exit 1
fi
