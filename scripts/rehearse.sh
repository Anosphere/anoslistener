#!/bin/sh
# The rehearsal: listener1 plays both parts, with a throwaway PostgreSQL, and
# runs the scripts of this repository as the points R1 to R10 list them,
# before validator 1's worker is touched. Run on listener1 as root, from the
# clone, after scripts/set-up-listener.sh:
#
#   sh /opt/listener/listenersoftware/scripts/rehearse.sh
#
#   R1   a throwaway PostgreSQL 17 on port 5440, made the Debian way, with a
#        database anos that holds one small table and its first row
#   R2   the worker's own script against it (set-up-worker.sh)
#   R3   the worker's key is accepted (add-worker-key.sh), and the line is
#        started
#   R4   the guard: with a wrong id written down, the line must stay down
#   R5   connect-validator.sh for a Barman server named rehearsal
#   R6   a second row, written after the full copy, with no WAL file closed:
#        it lives only in the unfinished WAL file
#   R7   practice-restore.sh rehearsal must find both rows
#   R8   the proof that nothing is deleted or written over: every file of
#        the server's folder is listed with its SHA-256, the line is broken
#        and mended, and the list is taken again
#   R9   clean up: remove-from-worker.sh, the units of the server rehearsal,
#        the throwaway PostgreSQL, Barman's server rehearsal and its files
#   R10  the last line: "REHEARSAL PASSED", or "REHEARSAL FAILED at R<n>:"
#        and why
#
# It refuses to run when a Barman server validator1 exists, when the key
# file of the user line holds the worker's key, or when port 5433 is in use.
# After a failure it leaves everything as it stands, for a look; a second
# run cleans up first.
#
# What it removes at R9 are the rehearsal's own files; nothing of validator 1
# exists yet. A fault the rehearsal finds is a change in the repository,
# never a fix by hand on listener1.
#
# Everything the commands print, and every line of the scripts it runs, goes
# to /opt/listener/logs/rehearse.log.
set -eu

SCRIPT=rehearse.sh
REPO=/opt/listener/listenersoftware
S=$REPO/scripts
LOG_DIR=/opt/listener/logs
LOG=$LOG_DIR/rehearse.log
STORE=/var/lib/barman
SERVER=rehearsal
SDIR=$STORE/$SERVER
KEPT=$SDIR/kept
PG_PORT=5440
ETC=/etc/listener
KEYS=$ETC/line.authorized_keys
PG_BIN=/usr/lib/postgresql/17/bin
RECEIVE=listener-receive@$SERVER.service
ARCHIVE_TIMER=listener-archive@$SERVER.timer
ARCHIVE_SERVICE=listener-archive@$SERVER.service
ROW_ONE='REHEARSAL-ROW-ONE: written before the full copy'
ROW_TWO='REHEARSAL-ROW-TWO: written after the full copy, in the unfinished WAL file only'

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sh $REPO/scripts/$SCRIPT" >&2
  exit 1
fi
if [ ! -f "$S/$SCRIPT" ] || [ ! -f "$REPO/listener/barman-server.conf" ]; then
  echo "failed at the start: the clone must be at $REPO; the units run its scripts" >&2
  exit 1
fi
cd /
umask 022

# The log holds everything a command prints. The screen, kept on fd 3, gets
# only what say() sends it.
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG"
chmod 600 "$LOG"
exec 3>&1
exec >>"$LOG" 2>&1
printf '=== %s %s %s ===\n' "$SCRIPT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"

# say LINE: to the screen and to the log.
say() {
  printf '%s\n' "$*" >&3 || true
  printf '%s\n' "$*"
}

# fail REASON: the rehearsal ends here, and the EXIT trap prints the last
# line. Never called inside $(...).
STEP=R0
REASON=''
SHOW_LOG=0
fail() {
  REASON=$*
  exit 1
}

# script_failed NAME: a script of this repository ended with an error. Its
# own last lines are in the log, and the EXIT trap shows them.
script_failed() {
  SHOW_LOG=1
  fail "scripts/$1 ended with an error; its own lines are above"
}

TMP=''
on_exit() {
  status=$?
  if [ -n "$TMP" ]; then
    rm -rf "$TMP"
  fi
  if [ "$status" -ne 0 ]; then
    if [ -z "$REASON" ]; then
      SHOW_LOG=1
      REASON="a command ended with an error; the lines above are the end of $LOG"
    fi
    if [ "$SHOW_LOG" -eq 1 ]; then
      tail -n 8 "$LOG" >&3
    fi
    say "REHEARSAL FAILED at $STEP: $REASON"
  fi
}
trap on_exit EXIT
# A Ctrl-C or a lost session ends the script like any other failure, so that
# its last line is still written: the shell would otherwise end without it.
trap 'REASON="the script was stopped from outside (the session was lost)"; exit 129' HUP
trap 'REASON="the script was stopped from outside (Ctrl-C)"; exit 130' INT
trap 'REASON="the script was stopped from outside (a TERM signal)"; exit 143' TERM

# as_barman COMMAND: as the user barman.
as_barman() {
  runuser -u barman -- "$@"
}

# rehearsal_sql DATABASE SQL: one question to the throwaway PostgreSQL, as
# its local user postgres.
rehearsal_sql() {
  runuser -u postgres -- "$PG_BIN/psql" -X -At -q -v ON_ERROR_STOP=1 -p "$PG_PORT" -d "$1" -c "$2"
}

# through_line SQL: one question through the line, as Barman asks.
through_line() {
  "$PG_BIN/psql" -X -At -q -v ON_ERROR_STOP=1 -c "$1" "$CONNINFO"
}

# cluster_there: the throwaway PostgreSQL exists.
cluster_there() {
  pg_lsclusters -h | awk '$1 == "17" && $2 == "rehearsal"' | grep -q .
}

# port_in_use PORT: something on this server listens on that TCP port.
port_in_use() {
  [ -n "$(ss -H -ltn "sport = :$1")" ]
}

# line_is_up: the unit runs, and PostgreSQL answers through the line as the
# user listener.
line_is_up() {
  [ "$(systemctl is-active listener-line.service || true)" = active ] && [ "$(through_line 'select current_user' 2>/dev/null || true)" = listener ]
}

# listener_streams: the throwaway PostgreSQL has one listener of Barman's
# that is streaming.
listener_streams() {
  [ "$(rehearsal_sql postgres "select count(*) from pg_stat_replication where application_name = 'barman_receive_wal' and state = 'streaming'" 2>/dev/null || true)" = 1 ]
}

# listener_has_all: and that listener has been sent everything written so
# far.
listener_has_all() {
  [ "$(rehearsal_sql postgres "select count(*) from pg_stat_replication where application_name = 'barman_receive_wal' and state = 'streaming' and sent_lsn = pg_current_wal_lsn()" 2>/dev/null || true)" = 1 ]
}

# wait_until SECONDS COMMAND: the command once a second, until it holds.
wait_until() {
  limit=$1
  shift
  waited=0
  until "$@"; do
    [ "$waited" -lt "$limit" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
}

# sum_of FILE: its SHA-256.
sum_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# clean_up: takes off everything a rehearsal made. Safe when part of it is
# not there. Used at R9, and first of all in a run after a failure.
clean_up() {
  # The worker's parts, by the worker's own script. It needs the throwaway
  # PostgreSQL to answer; one that does not answer any more is dropped
  # first, and the slot and the PostgreSQL user go with it.
  if cluster_there; then
    pg_ctlcluster 17 rehearsal start 2>/dev/null || true
    if ! wait_until 20 rehearsal_sql postgres 'select 1'; then
      pg_dropcluster --stop 17 rehearsal
    fi
  fi
  sh "$S/remove-from-worker.sh" --pg-port "$PG_PORT" || script_failed remove-from-worker.sh
  # The two units of the server rehearsal: stopped and switched off.
  systemctl stop "$RECEIVE" "$ARCHIVE_TIMER" "$ARCHIVE_SERVICE" 2>/dev/null || true
  systemctl disable "$RECEIVE" "$ARCHIVE_TIMER" 2>/dev/null || true
  systemctl reset-failed "$RECEIVE" "$ARCHIVE_SERVICE" 2>/dev/null || true
  # The throwaway PostgreSQL: dropped.
  if cluster_there; then
    pg_dropcluster --stop 17 rehearsal
  fi
  # A practice restore that was cut short.
  if [ -e /var/lib/barman/practice ]; then
    if [ -f /var/lib/barman/practice/data/postmaster.pid ]; then
      as_barman "$PG_BIN/pg_ctl" -D /var/lib/barman/practice/data -m immediate -w -t 60 stop || true
    fi
    rm -rf /var/lib/barman/practice
  fi
  # Barman's server rehearsal and its files. These are the rehearsal's own.
  rm -f /etc/barman.d/rehearsal.conf
  rm -rf /var/lib/barman/rehearsal
  rm -f /var/lib/barman/.rehearsal-*.lock
  # The rehearsal's key, out of the key file of the user line.
  if [ -f "$KEYS" ] && grep -q '^from="127\.0\.0\.1",' "$KEYS"; then
    install -o root -g root -m 644 /dev/null "$KEYS"
  fi
}

# leftovers: something of an earlier rehearsal is still there.
leftovers() {
  cluster_there || [ -f "$ETC/line.env" ] || [ -f "$ETC/worker-id" ] || id listener >/dev/null 2>&1 || [ -f /etc/systemd/system/listener-line.service ] || [ -e /etc/barman.d/rehearsal.conf ] || [ -e "$SDIR" ] || [ -e /var/lib/barman/practice ] || { [ -f "$KEYS" ] && grep -q '^from="127\.0\.0\.1",' "$KEYS"; }
}

if [ $# -gt 0 ]; then
  fail "this script takes no word after its name, got \"$1\""
fi

# Before anything: is this listener1, set up, with nothing of validator 1 on
# it yet?
[ -x /usr/bin/barman ] || fail 'Barman is not installed: scripts/set-up-listener.sh first. This script is for listener1, never for the worker'
id line >/dev/null 2>&1 || fail 'the user line is not there: scripts/set-up-listener.sh first. This script is for listener1, never for the worker'
[ -f /etc/systemd/system/listener-receive@.service ] || fail "the listener's units are not installed: scripts/set-up-listener.sh first"
[ -f "$KEYS" ] || fail "$KEYS is not there: scripts/set-up-listener.sh first"
command -v pg_createcluster >/dev/null 2>&1 || fail 'pg_createcluster is not there: scripts/set-up-listener.sh first'
mountpoint -q "$STORE" || fail "$STORE is not a mount: the Volume is not attached"
if [ -e /etc/barman.d/validator1.conf ] || [ -e "$STORE/validator1" ]; then
  fail 'a Barman server validator1 exists. The rehearsal runs before validator 1 is connected, never after. Nothing was changed'
fi
if [ -s "$KEYS" ] && ! grep -q '^from="127\.0\.0\.1",' "$KEYS"; then
  fail "$KEYS holds a key that is not the rehearsal's: the worker's key was accepted already, and the rehearsal would take it out. Nothing was changed"
fi
CONNINFO=$(sed -n 's/^conninfo = //p' "$REPO/listener/barman-server.conf" | head -n 1)
[ -n "$CONNINFO" ] || fail "$REPO/listener/barman-server.conf has no conninfo line"
TMP=$(mktemp -d)

# A second run cleans up first.
if leftovers; then
  clean_up
  say 'R0 what an earlier rehearsal left: cleaned up'
fi
if port_in_use 5433; then
  fail 'port 5433 is in use on this server, and the line needs it. Nothing was changed'
fi
if port_in_use "$PG_PORT"; then
  fail "port $PG_PORT is in use on this server, and the throwaway PostgreSQL needs it. Nothing was changed"
fi

# R1. A throwaway PostgreSQL 17, made the Debian way, so that its login
#     rules are the ones a worker has.
STEP=R1
pg_createcluster --locale C.UTF-8 --port "$PG_PORT" --start 17 rehearsal
wait_until 30 rehearsal_sql postgres 'select 1' || fail "the throwaway PostgreSQL does not answer on port $PG_PORT 30 seconds after it was made"
rehearsal_sql postgres 'CREATE DATABASE anos'
rehearsal_sql anos 'CREATE TABLE rehearsal_rows (id integer PRIMARY KEY, note text NOT NULL)'
rehearsal_sql anos "INSERT INTO rehearsal_rows (id, note) VALUES (1, '$ROW_ONE')"
say "R1 a throwaway PostgreSQL 17 on port $PG_PORT (pg_createcluster 17 rehearsal): made; its database anos holds one small table and its first row"

# R2. The worker's own script against it, with listener1's own host key.
STEP=R2
HOST_KEY_LINE=$(awk 'NR == 1 { print $1 " " $2 }' /etc/ssh/ssh_host_ed25519_key.pub)
sh "$S/set-up-worker.sh" --listener 127.0.0.1 --pg-port "$PG_PORT" --host-key "$HOST_KEY_LINE" || script_failed set-up-worker.sh
say "R2 the worker's own script against it (set-up-worker.sh --listener 127.0.0.1 --pg-port $PG_PORT): W1 to W8 done"

# R3. The worker's key is accepted from 127.0.0.1, and the line is started.
STEP=R3
PUBLIC_LINE=$(awk 'NR == 1 { print $1 " " $2 }' /var/lib/listener/line.key.pub)
sh "$S/add-worker-key.sh" --from 127.0.0.1 "$PUBLIC_LINE" || script_failed add-worker-key.sh
systemctl start listener-line.service
wait_until 30 line_is_up || fail "the line is not up 30 seconds after the unit listener-line was started. Its last lines: $(journalctl -u listener-line.service -n 5 --no-pager -o cat | tr '\n' ' ')"
port_in_use 5433 || fail 'the unit listener-line runs, and nothing listens on port 5433'
say 'R3 add-worker-key.sh --from 127.0.0.1, then the unit listener-line started: the line is up, and PostgreSQL answers through it as the user listener'

# R4. The guard. With a wrong id written down the unit must stay down, and
#     not try again. With the right id back it must come up.
STEP=R4
systemctl stop listener-line.service
RIGHT_ID=$(cat "$ETC/worker-id")
printf '%s\n' 'not-the-id-of-this-machine' > "$ETC/worker-id"
systemctl start listener-line.service || true
# Longer than the ten seconds after which the unit would try again.
sleep 15
GUARD_STATE=$(systemctl is-active listener-line.service || true)
GUARD_CODE=$(systemctl show -p ExecMainStatus --value listener-line.service)
GUARD_PORT=free
if port_in_use 5433; then
  GUARD_PORT='in use'
fi
printf '%s\n' "$RIGHT_ID" > "$ETC/worker-id"
if [ "$GUARD_STATE" != failed ] || [ "$GUARD_CODE" != 3 ] || [ "$GUARD_PORT" != free ]; then
  fail "with a wrong id in $ETC/worker-id the unit listener-line must stay down: it is \"$GUARD_STATE\", its script ended with $GUARD_CODE (3 is the guard's), and port 5433 is $GUARD_PORT. The right id is back in the file"
fi
systemctl reset-failed listener-line.service
systemctl start listener-line.service
wait_until 30 line_is_up || fail 'with the right id back in the file, the line did not come up within 30 seconds'
say 'R4 the guard: with a wrong id written down the unit stayed down (its script ended with 3, and it did not try again); with the right id back the line came up'

# R5. Barman connects, for a server named rehearsal: the listener's unit,
#     the slot, the early file, the full copy, every check OK.
STEP=R5
sh "$S/connect-validator.sh" rehearsal || script_failed connect-validator.sh
[ "$(systemctl is-active "$RECEIVE" || true)" = active ] || fail "connect-validator.sh ended well, and the unit $RECEIVE is not active"
say "R5 connect-validator.sh rehearsal: C1 to C7 done, with the real units ($RECEIVE and $ARCHIVE_TIMER)"

# R6. A second row after the full copy, and no WAL file is closed. That row
#     now lives only in the unfinished WAL file.
STEP=R6
rehearsal_sql anos "INSERT INTO rehearsal_rows (id, note) VALUES (2, '$ROW_TWO')"
wait_until 30 listener_has_all || fail 'the listener has not been sent the second row 30 seconds after it was written'
sleep 2
[ "$(find "$SDIR/streaming" -name '*.partial' | wc -l)" -eq 1 ] || fail "the streaming folder must hold one unfinished file; it holds: $(ls "$SDIR/streaming" | tr '\n' ' ')"
PARTIAL=$(find "$SDIR/streaming" -name '*.partial')
# The second row's note is looked for by three pieces that only it has. A
# WAL file is made of pages, and the border of two pages can cut through one
# piece, never through all three.
grep -a -q -e 'REHEARSAL-ROW-TWO' -e 'written after the full copy' -e 'in the unfinished WAL file only' "$PARTIAL" || fail "the second row is not in the unfinished file ${PARTIAL##*/}"
FINISHED_WITH_ROW=$(grep -a -l -e 'REHEARSAL-ROW-TWO' -e 'written after the full copy' -e 'in the unfinished WAL file only' "$SDIR"/wals/*/* 2>/dev/null || true)
[ -z "$FINISHED_WITH_ROW" ] || fail "a finished WAL file holds the second row, so a WAL file was closed after it was written: $FINISHED_WITH_ROW"
say "R6 a second row written after the full copy, no WAL file closed: it is in the unfinished file ${PARTIAL##*/} and in no finished one"

# R7. The practice restore must find both rows: the proof that a restore
#     brings the last second back.
STEP=R7
sh "$S/practice-restore.sh" rehearsal || script_failed practice-restore.sh
say 'R7 practice-restore.sh rehearsal: PASSED, both rows are in the restored copy'

# R8. The proof that nothing is deleted or written over, on Debian, with the
#     real units.
STEP=R8
# First the throwaway PostgreSQL is made quiet, so that it does not write a
# checkpoint of its own into the unfinished file in the middle of the proof:
# one checkpoint now, then its WAL position must stand still for 20 seconds.
rehearsal_sql postgres CHECKPOINT
rounds=0
while :; do
  POSITION_BEFORE=$(rehearsal_sql postgres 'select pg_current_wal_insert_lsn()')
  sleep 20
  POSITION_AFTER=$(rehearsal_sql postgres 'select pg_current_wal_insert_lsn()')
  if [ "$POSITION_BEFORE" = "$POSITION_AFTER" ]; then
    break
  fi
  rounds=$((rounds + 1))
  [ "$rounds" -lt 9 ] || fail 'the throwaway PostgreSQL kept writing WAL for three minutes, so the proof cannot be made on a file that stands still'
done
wait_until 30 listener_has_all || fail 'the listener has not been sent everything 30 seconds after the throwaway PostgreSQL went quiet'
sleep 2
GOOD_LINE=$(as_barman sh "$S/check.sh" rehearsal) || fail "check.sh rehearsal must say good, and it says: $GOOD_LINE"
printf '%s\n' "$GOOD_LINE"
[ "$(find "$SDIR/streaming" -name '*.partial' | wc -l)" -eq 1 ] || fail "the streaming folder must hold one unfinished file; it holds: $(ls "$SDIR/streaming" | tr '\n' ' ')"
PARTIAL=$(find "$SDIR/streaming" -name '*.partial')
[ -s "$PARTIAL" ] || fail "the unfinished file ${PARTIAL##*/} is empty before the break of the line"
find "$SDIR" -type f -exec sha256sum {} + | sort > "$TMP/before.list"
PARTIAL_SUM=$(sum_of "$PARTIAL")
KEPT_BEFORE=$(find "$KEPT" -type f 2>/dev/null | wc -l)

# The line is stopped. The check must say not good within two runs.
systemctl stop listener-line.service
NOT_GOOD=0
for run in 1 2; do
  if as_barman sh "$S/check.sh" rehearsal > "$TMP/check.line" 2>&1; then
    sleep 5
  else
    NOT_GOOD=1
    break
  fi
done
cat "$TMP/check.line"
[ "$NOT_GOOD" -eq 1 ] || fail 'with the line stopped, check.sh rehearsal still said good after two runs'
# The listener's unit tries again every ten seconds. Two rounds of it: while
# PostgreSQL does not answer, nothing may be moved and nothing may change.
sleep 25
[ -f "$PARTIAL" ] || fail "the unfinished file ${PARTIAL##*/} left the streaming folder while the line was down"
[ "$(sum_of "$PARTIAL")" = "$PARTIAL_SUM" ] || fail "the unfinished file ${PARTIAL##*/} changed while the line was down"
[ "$(find "$KEPT" -type f 2>/dev/null | wc -l)" -eq "$KEPT_BEFORE" ] || fail 'a file was moved into the kept folder while the line was down'

# The line is started again. Within a minute the listener must be
# streaming, and the unfinished file from before must be in the kept folder
# with the SHA-256 it had.
systemctl start listener-line.service
wait_until 60 listener_streams || fail "the listener is not streaming a minute after the line was started again. The unit's last lines: $(journalctl -u "$RECEIVE" -n 6 --no-pager -o cat | tr '\n' ' ')"
KEPT_FILE=''
for kept_file in "$KEPT/${PARTIAL##*/}".*; do
  [ -f "$kept_file" ] || continue
  if [ "$(sum_of "$kept_file")" = "$PARTIAL_SUM" ]; then
    KEPT_FILE=$kept_file
  fi
done
[ -n "$KEPT_FILE" ] || fail "the unfinished file from before the break is not in the kept folder with the SHA-256 it had ($PARTIAL_SUM). The kept folder holds: $(ls "$KEPT" 2>/dev/null | tr '\n' ' ')"

# Every other file of the list must be there as it was. Only Barman's own
# list file may differ (Barman 3.13.3 names it wals/<server>-xlog.db); the
# unfinished file's name now belongs to a new file.
find "$SDIR" -type f -exec sha256sum {} + | sort > "$TMP/after.list"
awk -v partial="$PARTIAL" '{ path = substr($0, 67) } path != partial && path !~ /xlog\.db$/' "$TMP/before.list" > "$TMP/before.rest"
comm -23 "$TMP/before.rest" "$TMP/after.list" > "$TMP/changed.list"
FILES_REST=$(wc -l < "$TMP/before.rest" | tr -d ' ')
if [ -s "$TMP/changed.list" ]; then
  echo '--- files that are gone or changed after the break of the line:'
  cat "$TMP/changed.list"
  fail "$(wc -l < "$TMP/changed.list") files of $SDIR are gone or changed after a break of the line. The first: $(head -n 1 "$TMP/changed.list" | cut -c67-)"
fi
say "R8 nothing deleted, nothing written over: check.sh said good; with the line stopped it said not good, and the unfinished file stayed in the streaming folder, unchanged; with the line back the listener was streaming within a minute, and that file is in the kept folder with the SHA-256 it had (kept/${KEPT_FILE##*/}); the other $FILES_REST files of the list are there as they were (Barman's own list file, $SERVER-xlog.db, left out)"

# R9. Clean up. The worker's own removal script runs here, so it is proven
#     before validator 1 ever needs it.
STEP=R9
clean_up
if leftovers; then
  fail 'something of the rehearsal is still there after the clean-up'
fi
if port_in_use 5433 || port_in_use "$PG_PORT"; then
  fail "port 5433 or port $PG_PORT is still in use after the clean-up"
fi
[ ! -s "$KEYS" ] || fail "$KEYS still holds a key after the clean-up"
say "R9 clean up: remove-from-worker.sh took the worker's parts off; the two units of the server rehearsal stopped and switched off; the throwaway PostgreSQL dropped; Barman's server rehearsal and its files removed; the key file of the user line empty again"

# R10. The last line.
STEP=R10
say 'REHEARSAL PASSED'
