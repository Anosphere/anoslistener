#!/bin/sh
# Connects Barman on listener1 to validator 1's PostgreSQL through the line:
# the points C1 to C7, one line printed per point. Run on listener1 as root,
# from the clone, once the line is up:
#
#   sh /opt/listener/listenersoftware/scripts/connect-validator.sh
#
#   C1  look through the line: PostgreSQL answers as the user listener, and
#       says it is not a copy of another server
#   C2  Barman's file for the server, /etc/barman.d/validator1.conf
#   C3  the listener's unit is switched on and started; its first start
#       makes the slot listener1; then one WAL file is closed early
#   C4  Barman's check: every line OK but one, which fails until the full
#       copy is there
#   C5  the full copy, as three commands: barman backup, then
#       barman switch-wal --force --archive, then barman check-backup.
#       When a full copy is there already, it takes none and says "already"
#   C6  Barman's check: every line OK
#   C7  the two timers on. The last line is "validator1: the copy is running"
#
# It looks first and is safe to run again.
#
#   --full-copy   takes a new full copy now: C1, then C5 without the look
#                 for an older one, then C6. For the day a stored file is
#                 found damaged, and for a full copy that broke off. The
#                 older full copies stay.
#   --start-over  for the day PostgreSQL has let go of WAL that Barman had
#                 not fetched yet (the listener's journal then says
#                 "requested WAL segment ... has already been removed"). It
#                 stops the listener's unit, moves every unfinished file
#                 into the kept folder and leaves nothing in its place,
#                 drops the slot and makes it again, starts the unit, closes
#                 one WAL file early, and takes a new full copy. The full
#                 copy from before the hole stays, with its WAL.
#
# One more word names another Barman server than validator1: "rehearsal", in
# the rehearsal.
#
# Nothing here deletes a file of the copy. What is left of a full copy that
# broke off is moved into the kept folder, as failed-copy-<its id>. This
# script never runs "barman cron", "barman delete" or
# "barman receive-wal --reset".
#
# Everything the commands print goes to
# /opt/listener/logs/connect-validator.log.
set -eu

SCRIPT=connect-validator.sh
REPO=/opt/listener/listenersoftware
LOG_DIR=/opt/listener/logs
LOG=$LOG_DIR/connect-validator.log
STORE=/var/lib/barman
PSQL=/usr/lib/postgresql/17/bin/psql
SERVER_FILE=$REPO/listener/barman-server.conf

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sh $REPO/scripts/$SCRIPT" >&2
  exit 1
fi
if [ ! -f "$SERVER_FILE" ] || [ ! -f "$REPO/scripts/move-unfinished.sh" ]; then
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

# at POINT NAME: the point being done, for the failure line.
STEP=''
STEP_NAME=''
at() {
  STEP=$1
  STEP_NAME=$2
}

# fail REASON: the run ends, and the EXIT trap prints the failure line.
# Never called inside $(...).
REASON=''
fail() {
  REASON=$*
  exit 1
}

TMP=''
on_exit() {
  status=$?
  if [ -n "$TMP" ]; then
    rm -rf "$TMP"
  fi
  if [ "$status" -ne 0 ]; then
    if [ -z "$REASON" ]; then
      tail -n 5 "$LOG" >&3
      REASON="a command ended with an error; the lines above are the end of $LOG"
    fi
    if [ -n "$STEP" ]; then
      say "failed at $STEP ($STEP_NAME): $REASON"
    else
      say "failed at the arguments: $REASON"
    fi
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

# through_line SQL: one question to PostgreSQL through the line, as Barman
# asks: with the conninfo of the server's Barman file.
through_line() {
  "$PSQL" -X -At -q -v ON_ERROR_STOP=1 -c "$1" "$CONNINFO"
}

# streaming: how many listeners of Barman are streaming; 0 when PostgreSQL
# does not answer.
streaming() {
  through_line "select count(*) from pg_stat_replication where application_name = 'barman_receive_wal' and state = 'streaming'" 2>/dev/null || echo 0
}

# wait_streaming SECONDS: until one listener is streaming.
wait_streaming() {
  waited=0
  while [ "$(streaming)" != 1 ]; do
    [ "$waited" -lt "$1" ] || return 1
    sleep 2
    waited=$((waited + 2))
  done
}

# slot_in_use: 1 when the slot listener1 is there and something reads from
# it, 0 when it is free or gone.
slot_in_use() {
  through_line "select count(*) from pg_replication_slots where slot_name = 'listener1' and active"
}

# barman_check: Barman's own check of the server. Sets CHECK_STATE (0 when
# every line is OK) and NOT_OK (the lines that are not OK).
barman_check() {
  CHECK_STATE=0
  as_barman barman check "$SERVER" > "$TMP/check.out" 2>&1 || CHECK_STATE=$?
  cat "$TMP/check.out"
  NOT_OK=$(grep -E '^[[:space:]]' "$TMP/check.out" | grep -v ': OK' | sed 's/^[[:space:]]*//' | tr '\n' ';' | sed -e 's/;$//' -e 's/;/; /g')
  if [ "$CHECK_STATE" -ne 0 ] && [ -z "$NOT_OK" ]; then
    NOT_OK="barman check ended with $CHECK_STATE: $(tail -n 1 "$TMP/check.out")"
  fi
}

# list_copies: the full copies Barman lists for the server, into COPIES: one
# line each, "<id> <state>", the newest first. The states are Barman's own:
# DONE, WAITING_FOR_WALS, FAILED, STARTED, EMPTY, SYNCING.
list_copies() {
  as_barman barman list-backups "$SERVER" > "$TMP/copies.out" || fail "barman list-backups ended with an error"
  while read -r copy_server copy_id copy_rest; do
    [ "$copy_server" = "$SERVER" ] || continue
    case $copy_id in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    case $copy_rest in
      *' - WAITING_FOR_WALS'*) echo "$copy_id WAITING_FOR_WALS" ;;
      *'Size: '*) echo "$copy_id DONE" ;;
      *) echo "$copy_id ${copy_rest##* }" ;;
    esac
  done < "$TMP/copies.out" > "$TMP/copies.list"
  COPIES=$(cat "$TMP/copies.list")
}

# copies_in STATE: how many full copies of COPIES are in that state.
copies_in() {
  printf '%s\n' "$COPIES" | awk -v state="$1" '$2 == state { n++ } END { print n + 0 }'
}

# copy_is_running: a full copy of this server is being taken right now:
# Barman holds its lock for one, or PostgreSQL's copy tool runs as barman.
copy_is_running() {
  copy_lock=$STORE/.$SERVER-backup.lock
  if [ -e "$copy_lock" ] && ! flock -n "$copy_lock" true; then
    return 0
  fi
  if pgrep -u barman -x pg_basebackup >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# move_failed_aside: what is left of every full copy that broke off, its
# folder and its note file, is moved into the kept folder, as
# failed-copy-<its id>. Nothing is deleted. Sets MOVED to the ids. A copy
# broke off when Barman lists it as FAILED; or as STARTED or EMPTY while no
# full copy is being taken, which is what a cut session or a restart of
# listener1 in the middle of a copy leaves.
move_failed_aside() {
  MOVED=''
  BROKEN=$(printf '%s\n' "$COPIES" | awk '$2 == "FAILED" || $2 == "STARTED" || $2 == "EMPTY" { print $1 }')
  if [ -z "$BROKEN" ]; then
    return 0
  fi
  if copy_is_running; then
    fail "a full copy of $SERVER is being taken right now, by another run of this script. Nothing was moved. Wait until it has ended, then run this again"
  fi
  for failed_id in $BROKEN; do
    aside=$KEPT/failed-copy-$failed_id
    [ ! -e "$aside" ] || fail "$aside is there already, and Barman still lists the full copy $failed_id as broken off. Nothing was moved"
    install -d -o barman -g barman -m 700 "$KEPT" "$aside"
    if [ -e "$SDIR/base/$failed_id" ]; then
      mv -n "$SDIR/base/$failed_id" "$aside/base"
    fi
    if [ -e "$SDIR/meta/$failed_id-backup.info" ]; then
      mv -n "$SDIR/meta/$failed_id-backup.info" "$aside/"
    fi
    if [ -e "$SDIR/base/$failed_id" ] || [ -e "$SDIR/meta/$failed_id-backup.info" ]; then
      fail "what is left of the full copy $failed_id could not be moved into $aside"
    fi
    MOVED="$MOVED $failed_id"
  done
}

# finish_copy: the second and third command of a full copy. On a quiet
# database a full copy waits for a WAL file that only new writes close, so
# one is closed early; then Barman looks at the copy again.
finish_copy() {
  as_barman barman switch-wal --force --archive "$SERVER" || fail "barman switch-wal --force --archive ended with an error: the WAL file that the full copy waits for did not arrive within 30 seconds. The same line again goes on from here"
  as_barman barman check-backup "$SERVER" latest || fail "barman check-backup ended with an error"
  list_copies
  NEWEST=$(printf '%s\n' "$COPIES" | head -n 1)
  case $NEWEST in
    *' DONE') ;;
    *) fail "the newest full copy is not whole after the three commands: Barman lists it as \"$NEWEST\"" ;;
  esac
}

# full_copy: a full copy, as the three commands.
full_copy() {
  as_barman barman backup "$SERVER" || fail "barman backup ended with an error: the full copy broke off. scripts/connect-validator.sh --full-copy moves what is left of it into the kept folder and takes it again"
  finish_copy
}

# The arguments.
MODE=connect
SERVER=''
while [ $# -gt 0 ]; do
  case $1 in
    --full-copy|--start-over)
      [ "$MODE" = connect ] || fail 'only one of --full-copy and --start-over, and only once'
      MODE=${1#--}
      ;;
    validator1|rehearsal)
      [ -z "$SERVER" ] || fail 'only one server name'
      SERVER=$1
      ;;
    *) fail "unknown word \"$1\"; the flags are --full-copy and --start-over, and the one name beside validator1 is rehearsal" ;;
  esac
  shift
done
if [ -z "$SERVER" ]; then
  SERVER=validator1
fi
SDIR=$STORE/$SERVER
KEPT=$SDIR/kept
CONF=/etc/barman.d/$SERVER.conf
RECEIVE=listener-receive@$SERVER.service
ARCHIVE_TIMER=listener-archive@$SERVER.timer

[ -x /usr/bin/barman ] || fail 'Barman is not installed: scripts/set-up-listener.sh first'
[ -f /etc/systemd/system/listener-receive@.service ] || fail "the listener's units are not installed: scripts/set-up-listener.sh first"
mountpoint -q "$STORE" || fail "$STORE is not a mount: the Volume is not attached, and nothing may be written to the system disk in its place"
CONNINFO=$(sed -n 's/^conninfo = //p' "$SERVER_FILE" | head -n 1)
[ -n "$CONNINFO" ] || fail "$SERVER_FILE has no conninfo line"
if [ "$MODE" != connect ] && [ ! -f "$CONF" ]; then
  fail "$CONF is not there: Barman is not connected to $SERVER yet. Run this script without --$MODE first"
fi
TMP=$(mktemp -d)

# C1. Look through the line.
at C1 look
LOOK=$(through_line "select current_user || '|' || pg_is_in_recovery()::text || '|' || current_setting('server_version')") || fail 'PostgreSQL does not answer through the line, on 127.0.0.1:5433. Is the line up? On the worker: systemctl is-active listener-line'
case $LOOK in
  'listener|false|'*) ;;
  'listener|true|'*) fail 'PostgreSQL says it is a copy of another server (it is in recovery). Barman must listen to validator 1 itself. Nothing was changed' ;;
  *) fail "PostgreSQL answers as the user \"${LOOK%%|*}\", not as listener. Nothing was changed" ;;
esac
say "C1 look through the line: PostgreSQL ${LOOK##*|} answers as the user listener, and says it is not a copy of another server"

if [ "$MODE" = connect ]; then
  # C2. Barman's file for the server: listener/barman-server.conf, with the
  #     server's name filled in.
  at C2 "Barman's file for the server"
  if [ "$SERVER" = validator1 ]; then
    cp "$SERVER_FILE" "$TMP/server.conf"
  else
    sed -e "s/^\[validator1\]\$/[$SERVER]/" -e 's/^description = .*$/description = "the rehearsal: a throwaway PostgreSQL on listener1, not validator 1"/' "$SERVER_FILE" > "$TMP/server.conf"
  fi
  grep -qx "\[$SERVER\]" "$TMP/server.conf" || fail "the server's name could not be filled into $SERVER_FILE"
  if cmp -s "$TMP/server.conf" "$CONF"; then
    CONF_LINE=already
  elif [ -f "$CONF" ]; then
    fail "$CONF is there and differs from the file in the clone ($SERVER_FILE). It was left as it is: Barman's settings for a server that is connected are not changed by this script"
  else
    install -o root -g root -m 644 "$TMP/server.conf" "$CONF"
    CONF_LINE=installed
  fi
  say "C2 Barman's file for the server, $CONF: $CONF_LINE"

  # C3. The listener's unit, switched on and started. Its first start makes
  #     the slot (create_slot = auto). Then one WAL file is closed early:
  #     Barman takes no copy before one whole file has arrived.
  at C3 "the listener's unit"
  if [ "$(systemctl is-active "$RECEIVE" || true)" = active ] && [ "$(streaming)" = 1 ]; then
    UNIT_LINE='already switched on, and its listener is streaming'
  else
    systemctl enable "$RECEIVE"
    systemctl start "$RECEIVE" || true
    wait_streaming 90 || fail "the listener is not streaming 90 seconds after its unit was started. The unit's last lines: $(journalctl -u "$RECEIVE" -n 6 --no-pager -o cat | tr '\n' ' ')"
    UNIT_LINE='switched on and started, and its listener is streaming'
  fi
  [ "$(slot_in_use)" = 1 ] || fail 'the slot listener1 is not there, or nothing reads from it, although a listener is streaming'
  list_copies
  # Barman's own list of the finished WAL files it holds is
  # wals/<server>-xlog.db; it is empty until the first one has arrived.
  if [ "$(copies_in DONE)" -ge 1 ] || [ "$(copies_in WAITING_FOR_WALS)" -ge 1 ] || [ -s "$SDIR/wals/$SERVER-xlog.db" ]; then
    EARLY_LINE='no WAL file closed early, because a finished one has arrived already'
  else
    as_barman barman switch-wal --force --archive "$SERVER" || fail 'barman switch-wal --force --archive ended with an error: the WAL file closed early did not arrive within 30 seconds. The same line again goes on from here'
    EARLY_LINE='one WAL file closed early, and it has arrived'
  fi
  say "C3 the listener's unit $RECEIVE: $UNIT_LINE; the slot listener1 is there; $EARLY_LINE"

  # C4. Barman's check before the full copy. One line may fail: minimum
  #     redundancy requirements, until the full copy is there. After an
  #     earlier try that broke off, failed backups fails too, until C5 has
  #     moved what is left of that try aside.
  at C4 "Barman's check before the full copy"
  barman_check
  UNEXPECTED=$(grep -E '^[[:space:]]' "$TMP/check.out" | grep -v ': OK' | sed 's/^[[:space:]]*//' | grep -Ev '^(minimum redundancy requirements|failed backups):' | tr '\n' ';' | sed -e 's/;$//' -e 's/;/; /g')
  if [ "$CHECK_STATE" -eq 0 ]; then
    CHECK_LINE='every line OK'
  elif [ -n "$UNEXPECTED" ] || [ -z "$(grep -E '^[[:space:]]' "$TMP/check.out" | grep -v ': OK')" ]; then
    fail "barman check fails on more than a missing full copy: ${UNEXPECTED:-$NOT_OK}"
  else
    CHECK_LINE="every line OK but: $NOT_OK"
  fi
  say "C4 Barman's check of $SERVER: $CHECK_LINE"
fi

if [ "$MODE" = start-over ]; then
  # The start-over. The slot has lost its place, so it is dropped and made
  # again, and the listener begins at the WAL file PostgreSQL is writing
  # now. Every unfinished file goes into the kept folder first, the empty
  # one too, so that the new start finds none. No "barman receive-wal
  # --reset": after a new slot it deletes the unfinished file.
  at start-over "the listener's unit stopped, the unfinished files moved, a new slot"
  systemctl stop "$RECEIVE" || true
  waited=0
  while [ "$(slot_in_use)" != 0 ]; do
    [ "$waited" -lt 30 ] || fail "the slot listener1 is still in use 30 seconds after the listener's unit was stopped. Nothing was moved"
    sleep 1
    waited=$((waited + 1))
  done
  as_barman sh "$REPO/scripts/move-unfinished.sh" "$SERVER" start-over || fail 'scripts/move-unfinished.sh could not move the unfinished files into the kept folder. The slot was left as it is'
  LEFT=$(find "$SDIR/streaming" -name '*.partial' 2>/dev/null | wc -l)
  [ "$LEFT" -eq 0 ] || fail "$LEFT unfinished files are still in the streaming folder after the move. The slot was left as it is"
  if [ "$(through_line "select count(*) from pg_replication_slots where slot_name = 'listener1'")" = 1 ]; then
    as_barman barman receive-wal --drop-slot "$SERVER" || fail 'barman receive-wal --drop-slot ended with an error'
  fi
  as_barman barman receive-wal --create-slot "$SERVER" || fail 'barman receive-wal --create-slot ended with an error'
  systemctl start "$RECEIVE" || true
  wait_streaming 90 || fail "the listener is not streaming 90 seconds after its unit was started again. The unit's last lines: $(journalctl -u "$RECEIVE" -n 6 --no-pager -o cat | tr '\n' ' ')"
  as_barman barman switch-wal --force --archive "$SERVER" || fail 'barman switch-wal --force --archive ended with an error: the WAL file closed early did not arrive within 30 seconds'
  say "start-over: the listener's unit stopped; every unfinished file moved into $KEPT; the slot listener1 dropped and made again; the unit started, and its listener is streaming from the WAL file PostgreSQL is writing now; one WAL file closed early"
fi

# C5. The full copy.
at C5 'the full copy'
list_copies
move_failed_aside
if [ -n "$MOVED" ]; then
  MOVED_LINE=" What was left of a full copy that broke off was moved into the kept folder first, as failed-copy-<its id>:$MOVED."
  list_copies
else
  MOVED_LINE=''
fi
# A copy that Barman lists as waiting for its WAL is looked at again first:
# the WAL may have arrived since. This closes no WAL file.
if [ "$(copies_in WAITING_FOR_WALS)" -ge 1 ]; then
  for waiting_id in $(printf '%s\n' "$COPIES" | awk '$2 == "WAITING_FOR_WALS" { print $1 }'); do
    as_barman barman check-backup "$SERVER" "$waiting_id" || true
  done
  list_copies
fi
NEWEST=$(printf '%s\n' "$COPIES" | head -n 1)
if [ "$MODE" = connect ] && [ "${NEWEST#* }" = WAITING_FOR_WALS ]; then
  # The newest copy still waits: a run was cut short after the first of the
  # three commands, and the copy's last WAL file is the one PostgreSQL is
  # writing now. The other two commands make it whole.
  WAITING_ID=${NEWEST%% *}
  finish_copy
  COPY_LINE="the full copy $WAITING_ID was waiting for its WAL, from a run that was cut short; the second and third command made it whole. Barman now holds $(copies_in DONE). None was taken anew."
elif [ "$MODE" = connect ] && [ "$(copies_in DONE)" -ge 1 ]; then
  COPY_LINE="already: Barman holds $(copies_in DONE), the newest is $(printf '%s\n' "$COPIES" | awk '$2 == "DONE" { print $1; exit }'). None was taken."
else
  full_copy
  if [ "$(copies_in DONE)" -eq 1 ]; then
    COPY_LINE="taken, as the three commands: ${NEWEST%% *}. It is the first one Barman holds."
  else
    COPY_LINE="taken, as the three commands: ${NEWEST%% *}. Barman now holds $(copies_in DONE); the older ones stay."
  fi
fi
OTHER=$(printf '%s\n' "$COPIES" | awk '$2 != "DONE" && $2 != "" { printf "%s%s is %s", sep, $1, $2; sep = ", " }')
if [ -n "$OTHER" ]; then
  COPY_LINE="$COPY_LINE Barman also lists, and they were left as they are: $OTHER."
fi
say "C5 the full copy: $COPY_LINE$MOVED_LINE"

# C6. Barman's check: every line OK.
at C6 "Barman's check"
barman_check
[ "$CHECK_STATE" -eq 0 ] || fail "barman check does not pass: $NOT_OK"
say "C6 Barman's check of $SERVER: every line OK"

if [ "$MODE" = connect ]; then
  # C7. The two timers on: the archive timer of this server and, for
  #     validator1, the check's timer.
  at C7 'the timers'
  if [ "$(systemctl is-active "$ARCHIVE_TIMER" || true)" = active ] && [ "$(systemctl is-enabled "$ARCHIVE_TIMER" 2>/dev/null || true)" = enabled ]; then
    TIMERS_LINE="$ARCHIVE_TIMER already on"
  else
    systemctl enable "$ARCHIVE_TIMER"
    systemctl start "$ARCHIVE_TIMER"
    TIMERS_LINE="$ARCHIVE_TIMER on"
  fi
  if [ "$SERVER" = validator1 ]; then
    if [ "$(systemctl is-active listener-check.timer || true)" = active ] && [ "$(systemctl is-enabled listener-check.timer 2>/dev/null || true)" = enabled ]; then
      TIMERS_LINE="$TIMERS_LINE, listener-check.timer already on"
    else
      systemctl enable listener-check.timer
      systemctl start listener-check.timer
      TIMERS_LINE="$TIMERS_LINE, listener-check.timer on"
    fi
  else
    TIMERS_LINE="$TIMERS_LINE; the check's timer is for validator1 only"
  fi
  say "C7 the timers: $TIMERS_LINE"
  say "$SERVER: the copy is running"
elif [ "$MODE" = full-copy ]; then
  say "$SERVER: a new full copy is there, and the older ones stay"
else
  say "$SERVER: started over; a new full copy is there, and the full copy from before the hole stays, with its WAL"
fi
