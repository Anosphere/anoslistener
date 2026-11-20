#!/bin/sh
# Sets up validator 1's worker for the line to listener1: the points W1 to
# W8, one line printed per point. Run on the worker as root, from the clone:
#
#   sudo sh /opt/listener/listenersoftware/scripts/set-up-worker.sh --listener <listener1's IPv4> --host-key "<listener1's host key line>"
#
#   --listener    listener1's IPv4 address
#   --host-key    listener1's public host key line, as scripts/set-up-listener.sh
#                 prints it last: "ssh-ed25519 AAAA..."
#   --pg-port     PostgreSQL's port, 5432 when left out; for the rehearsal
#   --new-worker  writes this VM's id over the one written down at the
#                 set-up. A person's decision, taken at the end of a way
#                 back, on a worker that was made new from a backup.
#
# What it adds to the worker, and nothing else: the system user listener
# with its SSH key in /var/lib/listener, three small files in /etc/listener,
# the PostgreSQL user listener, the setting max_slot_wal_keep_size, and the
# unit listener-line, which it does not start. PostgreSQL is not restarted.
# scripts/remove-from-worker.sh takes all of it off again.
#
# It looks first: W1 changes nothing, and stops when PostgreSQL is not as
# the line needs it. It is safe to run again: a second run changes nothing
# and prints "already" at each point. Once the values are in /etc/listener
# their flags may be left out; a flag that is given must say what is there.
#
# When /etc/listener/worker-id holds another id than this VM's, the script
# stops: this worker is a copy of the one the line was set up on.
#
# Everything the commands print goes to /opt/listener/logs/set-up-worker.log.
# The private half of the SSH key is never printed, by this script or by
# anything it runs.
set -eu

SCRIPT=set-up-worker.sh
REPO=/opt/listener/listenersoftware
LOG_DIR=/opt/listener/logs
LOG=$LOG_DIR/set-up-worker.log
ETC=/etc/listener
HOME_DIR=/var/lib/listener
KEY=$HOME_DIR/line.key
UNIT_FILE=/etc/systemd/system/listener-line.service

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sudo sh $REPO/scripts/$SCRIPT" >&2
  exit 1
fi
if [ ! -f "$REPO/scripts/line.sh" ] || [ ! -f "$REPO/worker/listener-line.service" ]; then
  echo "failed at the start: the clone must be at $REPO; the unit runs its scripts/line.sh" >&2
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

# is_ipv4 VALUE: four numbers 0 to 255 with dots.
is_ipv4() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
  ipv4_ifs=$IFS
  IFS=.
  set -- $1
  IFS=$ipv4_ifs
  for octet; do
    [ "$octet" -le 255 ] || return 1
  done
}

# public_key_body LINE: prints the body of one ed25519 public key line,
# "ssh-ed25519 AAAA... [a comment]". Fails for anything else.
public_key_body() {
  set -f
  set -- $1
  set +f
  [ $# -ge 2 ] || return 1
  [ "$1" = ssh-ed25519 ] || return 1
  case $2 in
    AAAAC3NzaC1lZDI1NTE5*) ;;
    *) return 1 ;;
  esac
  case $2 in
    *[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  [ "${#2}" -eq 68 ] || return 1
  printf '%s\n' "$2"
}

# this_vm_id: prints this VM's id: the Google id from the metadata server,
# or /etc/machine-id on a machine that is no Google VM. The same lines as in
# scripts/line.sh, which compares the two at every start of the line.
this_vm_id() {
  if grep -qi google /sys/class/dmi/id/product_name 2>/dev/null; then
    vm_id=$(/usr/bin/curl -sf -m 5 -H 'Metadata-Flavor: Google' http://169.254.169.254/computeMetadata/v1/instance/id) || return 1
    case $vm_id in
      ''|*[!0-9]*) return 1 ;;
    esac
  else
    vm_id=$(cat /etc/machine-id 2>/dev/null) || return 1
    [ -n "$vm_id" ] || return 1
  fi
  printf '%s\n' "$vm_id"
}

# pg ARGS: psql as the local user postgres, in the database postgres.
pg() {
  runuser -u postgres -- psql -X -At -q -v ON_ERROR_STOP=1 -p "$PG_PORT" -d postgres "$@"
}

# put FILE CONTENT: writes the file (root, mode 644) when it is not there or
# holds something else. Sets PUT to written or already.
put() {
  if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then
    PUT=already
  else
    printf '%s\n' "$2" > "$1.new"
    chmod 644 "$1.new"
    mv "$1.new" "$1"
    PUT=written
  fi
}

# The arguments: named flags, each given once, each checked for its shape,
# then against /etc/listener, before anything is touched.
LISTENER=''
HOST_KEY=''
PG_PORT=''
NEW_WORKER=0
SEEN=''
while [ $# -gt 0 ]; do
  case $1 in
    --listener|--host-key|--pg-port|--new-worker) ;;
    *) fail "unknown word \"$1\"; the flags are --listener, --host-key, --pg-port and --new-worker" ;;
  esac
  case " $SEEN " in
    *" $1 "*) fail "$1 given twice" ;;
  esac
  SEEN="$SEEN $1"
  if [ "$1" = --new-worker ]; then
    NEW_WORKER=1
    shift
    continue
  fi
  [ $# -ge 2 ] || fail "$1 needs a value"
  case $1 in
    --listener) LISTENER=$2 ;;
    --host-key) HOST_KEY=$2 ;;
    --pg-port) PG_PORT=$2 ;;
  esac
  shift 2
done

if [ -n "$LISTENER" ]; then
  is_ipv4 "$LISTENER" || fail "--listener must be an IPv4 address, four numbers 0 to 255 with dots, got \"$LISTENER\""
fi
if [ -n "$PG_PORT" ]; then
  case $PG_PORT in
    *[!0-9]*) fail "--pg-port must be a number, got \"$PG_PORT\"" ;;
  esac
  if [ "$PG_PORT" -lt 1 ] || [ "$PG_PORT" -gt 65535 ]; then
    fail "--pg-port must be between 1 and 65535, got \"$PG_PORT\""
  fi
fi
KEY_BODY=''
if [ -n "$HOST_KEY" ]; then
  KEY_BODY=$(public_key_body "$HOST_KEY") || fail '--host-key must be one ed25519 public key line in double quotes, "ssh-ed25519 AAAA...": the line scripts/set-up-listener.sh prints last on listener1'
fi

# What is in /etc/listener already. A value left out is taken from there; a
# value that is given must say the same.
DISK_LISTENER=''
DISK_PG_PORT=''
DISK_KEY_BODY=''
if [ -f "$ETC/line.env" ]; then
  DISK_LISTENER=$(sed -n 's/^LISTENER_ADDRESS=//p' "$ETC/line.env" | head -n 1)
  DISK_PG_PORT=$(sed -n 's/^PG_PORT=//p' "$ETC/line.env" | head -n 1)
fi
if [ -f "$ETC/known_hosts" ]; then
  DISK_KEY_BODY=$(awk 'NR == 1 { print $3 }' "$ETC/known_hosts")
fi
TO_CHANGE="scripts/remove-from-worker.sh takes the set-up off; then this script sets it up with the new value"
if [ -n "$LISTENER" ]; then
  if [ -n "$DISK_LISTENER" ] && [ "$LISTENER" != "$DISK_LISTENER" ]; then
    fail "--listener is $LISTENER, but $ETC/line.env has LISTENER_ADDRESS=$DISK_LISTENER. Nothing was changed. $TO_CHANGE"
  fi
elif [ -n "$DISK_LISTENER" ]; then
  LISTENER=$DISK_LISTENER
else
  fail "--listener is needed until $ETC/line.env exists: listener1's IPv4 address"
fi
if [ -n "$PG_PORT" ]; then
  if [ -n "$DISK_PG_PORT" ] && [ "$PG_PORT" != "$DISK_PG_PORT" ]; then
    fail "--pg-port is $PG_PORT, but $ETC/line.env has PG_PORT=$DISK_PG_PORT. Nothing was changed. $TO_CHANGE"
  fi
elif [ -n "$DISK_PG_PORT" ]; then
  PG_PORT=$DISK_PG_PORT
else
  PG_PORT=5432
fi
if [ -n "$KEY_BODY" ]; then
  if [ -n "$DISK_KEY_BODY" ] && [ "$KEY_BODY" != "$DISK_KEY_BODY" ]; then
    fail "--host-key is another key than the one in $ETC/known_hosts. Nothing was changed. $TO_CHANGE"
  fi
elif [ -n "$DISK_KEY_BODY" ]; then
  KEY_BODY=$DISK_KEY_BODY
else
  fail "--host-key is needed until $ETC/known_hosts exists: listener1's public host key line, in double quotes"
fi

# W1. Look, change nothing.
at W1 look
SOCKET=/var/run/postgresql/.s.PGSQL.$PG_PORT
[ -S "$SOCKET" ] || fail "PostgreSQL's socket file $SOCKET is not there: no PostgreSQL runs on port $PG_PORT. Nothing was changed"
LOOK=$(pg -c "select current_setting('server_version') || '|' || current_setting('server_version_num') || '|' || current_setting('wal_level') || '|' || current_setting('max_wal_senders') || '|' || current_setting('max_replication_slots') || '|' || (select count(*) from pg_hba_file_rules where type = 'local' and database = '{all}' and user_name = '{all}' and auth_method = 'peer' and error is null) || '|' || (select count(*) from pg_hba_file_rules where type = 'local' and database = '{replication}' and user_name = '{all}' and auth_method = 'peer' and error is null)") || fail "PostgreSQL does not answer the local user postgres on port $PG_PORT. Nothing was changed"
look_ifs=$IFS
IFS='|'
set -f
set -- $LOOK
set +f
IFS=$look_ifs
[ $# -eq 7 ] || fail "PostgreSQL's answer to the look is not understood: \"$LOOK\". Nothing was changed"
PG_VERSION=$1
PG_VERSION_NUM=$2
WAL_LEVEL=$3
WAL_SENDERS=$4
REPLICATION_SLOTS=$5
RULE_ALL=$6
RULE_REPLICATION=$7
case $PG_VERSION_NUM in
  17????) ;;
  *) fail "this is PostgreSQL $PG_VERSION, and the plan is made for PostgreSQL 17. Nothing was changed" ;;
esac
case $WAL_LEVEL in
  replica|logical) ;;
  *) fail "wal_level is $WAL_LEVEL; it must be replica or logical, and changing it needs a restart of PostgreSQL, which is not part of this script. Nothing was changed" ;;
esac
[ "$WAL_SENDERS" -ge 4 ] || fail "max_wal_senders is $WAL_SENDERS; it must be at least 4, and changing it needs a restart of PostgreSQL. Nothing was changed"
[ "$REPLICATION_SLOTS" -ge 1 ] || fail "max_replication_slots is $REPLICATION_SLOTS; it must be at least 1, and changing it needs a restart of PostgreSQL. Nothing was changed"
[ "$RULE_ALL" -ge 1 ] || fail "PostgreSQL's login rules have no line \"local all all peer\": a local user is not let in under its own name for a normal connection. Nothing was changed"
[ "$RULE_REPLICATION" -ge 1 ] || fail "PostgreSQL's login rules have no line \"local replication all peer\": a local user is not let in under its own name for a replication connection. Nothing was changed"
[ -x /usr/bin/ssh ] || fail "/usr/bin/ssh is not there: the line needs the OpenSSH client. Nothing was changed"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not there: the line's key cannot be made. Nothing was changed"
VM_ID=$(this_vm_id) || fail "this VM's id cannot be read: the Google metadata server at 169.254.169.254, or /etc/machine-id on a machine that is no Google VM. Nothing was changed"
if [ -f "$ETC/worker-id" ]; then
  WRITTEN_ID=$(cat "$ETC/worker-id")
  if [ "$WRITTEN_ID" != "$VM_ID" ] && [ "$NEW_WORKER" -eq 0 ]; then
    fail "this worker is a copy of the one the line was set up on: this VM's id is $VM_ID, and $ETC/worker-id holds $WRITTEN_ID. Nothing was changed, and the line stays down. --new-worker writes the new id: that is a person's decision, taken at the end of a way back"
  fi
fi
say "W1 look: PostgreSQL $PG_VERSION on port $PG_PORT, wal_level $WAL_LEVEL, max_wal_senders $WAL_SENDERS, max_replication_slots $REPLICATION_SLOTS, a local user is let in under its own name (both rules), ssh is there"

# W2. The system user listener: no login shell, home /var/lib/listener,
#     mode 700.
at W2 'the system user listener'
if id listener >/dev/null 2>&1; then
  USER_HOME=$(getent passwd listener | cut -d: -f6)
  [ "$USER_HOME" = "$HOME_DIR" ] || fail "a user listener is there with the home $USER_HOME, not $HOME_DIR: it is not this script's. Nothing more was changed"
  USER_LINE=already
else
  useradd --system --user-group --no-create-home --home-dir "$HOME_DIR" --shell /usr/sbin/nologin listener
  USER_LINE=made
fi
if [ -d "$HOME_DIR" ] && [ "$(stat -c '%U:%G %a' "$HOME_DIR")" = 'listener:listener 700' ]; then
  HOME_LINE=already
else
  install -d -o listener -g listener -m 700 "$HOME_DIR"
  HOME_LINE=made
fi
say "W2 the system user listener: $USER_LINE, with no login shell; its home $HOME_DIR, mode 700: $HOME_LINE"

# W3. Its SSH key: ed25519, made on this machine, never printed, never
#     copied. ssh-keygen -q prints nothing.
at W3 'its SSH key'
if [ -f "$KEY" ]; then
  KEY_LINE=already
else
  runuser -u listener -- ssh-keygen -q -t ed25519 -N '' -C listener-line -f "$KEY"
  KEY_LINE=made
fi
if [ ! -f "$KEY.pub" ]; then
  # The public half can always be worked out from the private one.
  PUBLIC_HALF=$(runuser -u listener -- ssh-keygen -y -f "$KEY")
  printf '%s\n' "$PUBLIC_HALF" > "$KEY.pub"
fi
chown listener:listener "$KEY" "$KEY.pub"
chmod 600 "$KEY"
chmod 644 "$KEY.pub"
say "W3 its SSH key: $KEY_LINE at $KEY (ed25519; the private half stays on this machine and is never printed)"

# W4. The folder /etc/listener: where listener1 is, its host key, and this
#     VM's id.
at W4 'the folder /etc/listener'
if [ ! -d "$ETC" ]; then
  install -d -o root -g root -m 755 "$ETC"
fi
put "$ETC/line.env" "LISTENER_ADDRESS=$LISTENER
PG_PORT=$PG_PORT"
ENV_LINE=$PUT
put "$ETC/known_hosts" "$LISTENER ssh-ed25519 $KEY_BODY"
KNOWN_LINE=$PUT
if [ ! -f "$ETC/worker-id" ]; then
  put "$ETC/worker-id" "$VM_ID"
  ID_LINE=written
elif [ "$(cat "$ETC/worker-id")" = "$VM_ID" ]; then
  ID_LINE=already
else
  put "$ETC/worker-id" "$VM_ID"
  ID_LINE='written anew for a new worker (--new-worker)'
fi
say "W4 the folder $ETC: line.env $ENV_LINE (listener1 at $LISTENER, PostgreSQL's port $PG_PORT), known_hosts $KNOWN_LINE, worker-id $ID_LINE"

# W5. The PostgreSQL user listener, in the database postgres: it may log in
#     and read the WAL, has no password and at most 10 connections, and the
#     grants Barman's page lists for a user that is not a superuser. The
#     lines are the plan's appendix A.6, in one transaction.
at W5 'the PostgreSQL user listener'
if [ "$(pg -c "select count(*) from pg_roles where rolname = 'listener'")" = 1 ]; then
  WHOLE=$(pg -c "select (rolcanlogin and rolreplication and not rolsuper and rolconnlimit = 10 and has_function_privilege('listener', 'pg_backup_start(text, boolean)', 'EXECUTE') and has_function_privilege('listener', 'pg_backup_stop(boolean)', 'EXECUTE') and has_function_privilege('listener', 'pg_switch_wal()', 'EXECUTE') and has_function_privilege('listener', 'pg_create_restore_point(text)', 'EXECUTE') and pg_has_role('listener', 'pg_read_all_settings', 'MEMBER') and pg_has_role('listener', 'pg_read_all_stats', 'MEMBER') and pg_has_role('listener', 'pg_checkpoint', 'MEMBER'))::text from pg_roles where rolname = 'listener'")
  [ "$WHOLE" = true ] || fail "a PostgreSQL user listener is there, and it is not as this script makes it. It was left as it is. scripts/remove-from-worker.sh takes it off; then this script makes it again"
  ROLE_LINE=already
else
  pg -1 -f - <<'SQL'
CREATE ROLE listener LOGIN REPLICATION CONNECTION LIMIT 10;
GRANT EXECUTE ON FUNCTION pg_backup_start(text, boolean) TO listener;
GRANT EXECUTE ON FUNCTION pg_backup_stop(boolean) TO listener;
GRANT EXECUTE ON FUNCTION pg_switch_wal() TO listener;
GRANT EXECUTE ON FUNCTION pg_create_restore_point(text) TO listener;
GRANT pg_read_all_settings TO listener;
GRANT pg_read_all_stats TO listener;
GRANT pg_checkpoint TO listener;
SQL
  ROLE_LINE=made
fi
say "W5 the PostgreSQL user listener: $ROLE_LINE (it may log in and read the WAL, no password, at most 10 connections, Barman's grants; it can change no row)"

# W6. The WAL PostgreSQL holds back for an absent listener: 4 GB, then
#     PostgreSQL lets it go. ALTER SYSTEM and a reload, no restart.
at W6 'max_slot_wal_keep_size'
KEEP=$(pg -c 'show max_slot_wal_keep_size')
if [ "$KEEP" = 4GB ]; then
  KEEP_LINE=already
else
  pg -f - <<'SQL'
ALTER SYSTEM SET max_slot_wal_keep_size = '4GB';
SELECT pg_reload_conf();
SQL
  waited=0
  while [ "$(pg -c 'show max_slot_wal_keep_size')" != 4GB ]; do
    [ "$waited" -lt 10 ] || fail "max_slot_wal_keep_size is still \"$(pg -c 'show max_slot_wal_keep_size')\" ten seconds after the reload (it was \"$KEEP\")"
    sleep 1
    waited=$((waited + 1))
  done
  KEEP_LINE="set (it was $KEEP), with a reload and no restart"
fi
say "W6 max_slot_wal_keep_size = 4GB: $KEEP_LINE"

# W7. The unit listener-line: installed and enabled, not started.
at W7 'the unit listener-line'
if cmp -s "$REPO/worker/listener-line.service" "$UNIT_FILE"; then
  UNIT_LINE=already
else
  if [ -f "$UNIT_FILE" ]; then
    UNIT_LINE='installed anew (the file in the clone has changed; a line that runs uses it after its next restart)'
  else
    UNIT_LINE=installed
  fi
  install -o root -g root -m 644 "$REPO/worker/listener-line.service" "$UNIT_FILE"
  systemctl daemon-reload
fi
if [ "$(systemctl is-enabled listener-line.service 2>/dev/null || true)" = enabled ]; then
  ENABLED_LINE=already
else
  systemctl enable listener-line.service
  ENABLED_LINE=done
fi
UNIT_STATE=$(systemctl is-active listener-line.service || true)
say "W7 the unit listener-line: $UNIT_LINE; enabled: $ENABLED_LINE; not started by this script (it is $UNIT_STATE)"

# W8. The end: the line that starts the unit, and the worker's public key
#     line, for listener1, last.
at W8 'the end'
PUBLIC_LINE=$(awk 'NR == 1 { print $1 " " $2 }' "$KEY.pub")
public_key_body "$PUBLIC_LINE" >/dev/null || fail "$KEY.pub does not hold one ed25519 public key line"
say "W8 the end: the worker is ready and the line is not started. Once the key below is accepted on listener1 (scripts/add-worker-key.sh), this starts it: sudo systemctl start listener-line"
say "The worker's public key line, for listener1:"
say "$PUBLIC_LINE"
