#!/bin/sh
# Takes everything scripts/set-up-worker.sh added off the worker again. Run
# on the worker as root, from the clone:
#
#   sudo sh /opt/listener/listenersoftware/scripts/remove-from-worker.sh
#
#   --pg-port   PostgreSQL's port. When left out: the port in
#               /etc/listener/line.env, and 5432 when that file is gone.
#
# In this order:
#   1. the unit listener-line is stopped and removed;
#   2. in PostgreSQL: the slot listener1 is dropped, the grants are taken
#      back and the user listener is dropped, and max_slot_wal_keep_size is
#      set back, with a reload and no restart;
#   3. the system user listener and /var/lib/listener, with the line's key;
#   4. the three files of /etc/listener, and the folder when it is empty
#      after that.
#
# It leaves the clone, /opt/listener, with the scripts' logs.
#
# It looks first at every point and is safe to run again: what is gone
# already is said to be gone. When PostgreSQL does not answer, it stops at
# point 2 and takes nothing more off; the same line again finishes the work
# once PostgreSQL is up. The rehearsal on listener1 runs this script, so it
# is proven before validator 1 ever needs it.
#
# Everything the commands print goes to
# /opt/listener/logs/remove-from-worker.log.
set -eu

SCRIPT=remove-from-worker.sh
REPO=/opt/listener/listenersoftware
LOG_DIR=/opt/listener/logs
LOG=$LOG_DIR/remove-from-worker.log
ETC=/etc/listener
HOME_DIR=/var/lib/listener
UNIT_FILE=/etc/systemd/system/listener-line.service

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sudo sh $REPO/scripts/$SCRIPT" >&2
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

on_exit() {
  status=$?
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

# pg ARGS: psql as the local user postgres, in the database postgres.
pg() {
  runuser -u postgres -- psql -X -At -q -v ON_ERROR_STOP=1 -p "$PG_PORT" -d postgres "$@"
}

# The arguments.
PG_PORT=''
while [ $# -gt 0 ]; do
  case $1 in
    --pg-port)
      [ $# -ge 2 ] || fail '--pg-port needs a value'
      [ -z "$PG_PORT" ] || fail '--pg-port given twice'
      PG_PORT=$2
      shift 2
      ;;
    *) fail "unknown word \"$1\"; the one flag is --pg-port" ;;
  esac
done
if [ -z "$PG_PORT" ] && [ -f "$ETC/line.env" ]; then
  PG_PORT=$(sed -n 's/^PG_PORT=//p' "$ETC/line.env" | head -n 1)
fi
if [ -z "$PG_PORT" ]; then
  PG_PORT=5432
fi
case $PG_PORT in
  *[!0-9]*) fail "PostgreSQL's port must be a number, got \"$PG_PORT\"" ;;
esac

# 1. The unit: stopped, switched off, removed.
at 1 'the unit listener-line'
systemctl stop listener-line.service 2>/dev/null || true
if [ -f "$UNIT_FILE" ]; then
  systemctl disable listener-line.service || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  systemctl reset-failed listener-line.service 2>/dev/null || true
  say '1 the unit listener-line: stopped and removed'
else
  say '1 the unit listener-line: already gone'
fi

# 2. PostgreSQL: the slot, the grants and the user, the setting.
at 2 PostgreSQL
CLUSTER=''
if command -v pg_lsclusters >/dev/null 2>&1; then
  CLUSTER=$(pg_lsclusters -h | awk -v port="$PG_PORT" '$3 == port { print $1 "/" $2 }' | head -n 1)
fi
if [ -z "$CLUSTER" ]; then
  say "2 PostgreSQL: this machine has no PostgreSQL on port $PG_PORT, so nothing is there to take off"
else
  pg -c 'select 1' >/dev/null || fail "PostgreSQL $CLUSTER does not answer the local user postgres on port $PG_PORT. The unit is off; nothing more was taken off. Once PostgreSQL is up, the same line again finishes the work"

  # The slot. The line is down, so the listener's connection ends by
  # itself; the slot can be dropped once nothing uses it any more.
  SLOT=$(pg -c "select active::text from pg_replication_slots where slot_name = 'listener1'")
  if [ -z "$SLOT" ]; then
    SLOT_LINE='the slot listener1 already gone'
  else
    waited=0
    while [ "$SLOT" = true ]; do
      [ "$waited" -lt 30 ] || fail "the slot listener1 is still in use 30 seconds after the line was stopped: something else reads from it. Nothing more was taken off"
      sleep 1
      waited=$((waited + 1))
      SLOT=$(pg -c "select active::text from pg_replication_slots where slot_name = 'listener1'")
    done
    if [ -n "$SLOT" ]; then
      pg -c "select pg_drop_replication_slot('listener1')" >/dev/null
    fi
    SLOT_LINE='the slot listener1 dropped'
  fi

  # The grants and the user: the plan's appendix A.6, the way off.
  if [ "$(pg -c "select count(*) from pg_roles where rolname = 'listener'")" = 1 ]; then
    pg -1 -f - <<'SQL'
DROP OWNED BY listener;
DROP ROLE listener;
SQL
    ROLE_LINE='the grants taken back and the user listener dropped'
  else
    ROLE_LINE='the user listener already gone'
  fi

  # The setting, back to what it was before ALTER SYSTEM set it.
  if [ "$(pg -c "select count(*) from pg_file_settings where name = 'max_slot_wal_keep_size' and sourcefile like '%postgresql.auto.conf'")" = 0 ]; then
    KEEP_LINE='max_slot_wal_keep_size already set back'
  else
    pg -f - <<'SQL'
ALTER SYSTEM RESET max_slot_wal_keep_size;
SELECT pg_reload_conf();
SQL
    sleep 1
    KEEP_LINE="max_slot_wal_keep_size set back, with a reload and no restart (it is now $(pg -c 'show max_slot_wal_keep_size'))"
  fi
  say "2 PostgreSQL $CLUSTER on port $PG_PORT: $SLOT_LINE; $ROLE_LINE; $KEEP_LINE"
fi

# 3. The system user and its home, with the line's key.
at 3 'the system user listener'
if id listener >/dev/null 2>&1; then
  userdel listener || fail 'the system user listener could not be removed: a process of it may still run (ps -u listener)'
  USER_LINE=removed
else
  USER_LINE='already gone'
fi
if [ -d "$HOME_DIR" ]; then
  rm -rf /var/lib/listener
  HOME_LINE="removed, the line's key with it"
else
  HOME_LINE='already gone'
fi
say "3 the system user listener: $USER_LINE; $HOME_DIR: $HOME_LINE"

# 4. The three files of /etc/listener. On listener1, in the rehearsal, the
#    folder also holds the listener's own files; those stay.
at 4 'the folder /etc/listener'
if [ -d "$ETC" ]; then
  rm -f "$ETC/line.env" "$ETC/known_hosts" "$ETC/worker-id"
  if rmdir "$ETC" 2>/dev/null; then
    ETC_LINE='removed'
  else
    ETC_LINE="line.env, known_hosts and worker-id removed; the folder stays, because it holds other files: $(ls "$ETC" | tr '\n' ' ')"
  fi
else
  ETC_LINE='already gone'
fi
say "4 the folder $ETC: $ETC_LINE"

say "done: the listener's parts are off this machine. The clone and the logs under /opt/listener stay."
