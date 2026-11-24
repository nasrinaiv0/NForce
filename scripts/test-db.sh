#!/usr/bin/env bash
# Run the Supabase migrations and SQL tests against a throwaway local
# PostgreSQL (15+) cluster. Requires initdb/pg_ctl/psql on PATH or in
# /usr/lib/postgresql/<version>/bin. Leaves nothing behind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-$(dirname "$(command -v initdb 2>/dev/null || ls -d /usr/lib/postgresql/*/bin/initdb | sort -V | tail -1)")}"
PORT="${PGPORT_TEST:-54329}"
WORK="$(mktemp -d)"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then
  chown postgres "$WORK"
  RUN_AS=(runuser -u postgres --)
fi
cleanup() { "${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

"${RUN_AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres --auth=trust >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/log" -w start >/dev/null
PSQL=("${RUN_AS[@]}" "$PGBIN/psql" -h "$WORK" -p "$PORT" -U postgres -d postgres -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -f "$ROOT/supabase/tests/local_auth_shim.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "applying $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done
for f in "$ROOT"/supabase/tests/*.test.sql; do
  echo "running $(basename "$f")"
  "${PSQL[@]}" -f "$f" 2>&1 | sed -n 's/.*NOTICE:  //p; /ERROR/p'
done

# P0.3 two-connection contention test. Same throwaway socket only; no remote URL.
echo "running P0.3 independent-connection contention"
"${PSQL[@]}" -f "$ROOT/supabase/tests/p0_3_fixture.sql" >/dev/null
"${PSQL[@]}" -f "$ROOT/supabase/tests/p0_3_race.sql" >"$WORK/race-a.log" 2>&1 & A=$!
"${PSQL[@]}" -f "$ROOT/supabase/tests/p0_3_race.sql" >"$WORK/race-b.log" 2>&1 & B=$!
FAIL=0
wait "$A" || FAIL=1
wait "$B" || FAIL=1
cat "$WORK/race-a.log" "$WORK/race-b.log"
test "$FAIL" -eq 0
test "$(grep -h -c 'P03_RACE_WIN' "$WORK"/race-*.log | awk '{n+=$1} END{print n}')" -eq 1
test "$(grep -h -c 'P03_RACE_ALREADY_LOCKED' "$WORK"/race-*.log | awk '{n+=$1} END{print n}')" -eq 1
"${PSQL[@]}" -f "$ROOT/supabase/tests/p0_3_race_verify.sql"


# P0.4 independent tenant regression.
"${PSQL[@]}" -f "$ROOT/supabase/tests/p0_4_hold.sql" >"$WORK/p04-hold.log" 2>&1 & H=$!
READY=0
for i in $(seq 1 40); do
  if grep -q P04_LOCK_HELD "$WORK/p04-hold.log"; then READY=1; break; fi
  sleep 0.1
done
test "$READY" -eq 1
"${PSQL[@]}" -f "$ROOT/supabase/tests/p0_4_tenant_race.sql"
wait "$H"
echo "database tests passed"
