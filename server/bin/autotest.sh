#!/usr/bin/env bash
#==============================================================================
# Play the game against an isolated server and write a report (server/autotest).
#   bin/autotest.sh            every scenario
#   bin/autotest.sh smoke      the scenarios whose name or file matches
# Uses its own database (pemk_autotest, created and migrated here) and port 9997
# (AUTOTEST_PORT): the dev database and the dev server are never touched. Game
# windows open minimized; reports land in autotest-reports/<run>/report.md.
#==============================================================================
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HOME/pemk-env.sh" ] && source "$HOME/pemk-env.sh"
: "${PGBIN:=/usr/lib/postgresql/15/bin}"
: "${PGPORT:=55432}"
PGUSER="$(id -un)"

cd "$SERVER_DIR"

if [ -x "$PGBIN/pg_isready" ] && ! "$PGBIN/pg_isready" -h 127.0.0.1 -p "$PGPORT" >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$HOME/pemk-pgdata" \
    -o "-p $PGPORT -k /tmp -c listen_addresses=127.0.0.1" \
    -l "$HOME/pemk-pgdata/server.log" -w start
fi

"$PGBIN/createdb" -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER" pemk_autotest 2>/dev/null || true
export DATABASE_URL="postgres://$PGUSER@127.0.0.1:$PGPORT/pemk_autotest"
bundle exec rake db:migrate >/dev/null

exec bundle exec ruby autotest/run.rb "$@"
