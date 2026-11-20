#!/bin/sh
# Moves the unfinished WAL file aside before the listener starts, so that the
# listener never writes into a WAL file it has written to before. Run on
# listener1 as the user barman, by the listener's unit before every start
# (listener/listener-receive@.service):
#
#   ExecStartPre=/bin/sh /opt/listener/listenersoftware/scripts/move-unfinished.sh %i
#
# It does three things, in this order.
#
#   1. It makes sure no listener is running, by Barman's own lock file for
#      the listener. When one runs, it moves nothing and ends with 1.
#   2. It asks PostgreSQL "select 1" through the line, with the conninfo of
#      the server's Barman file. With no answer it moves nothing and ends
#      with 1, so the listener is not started in this round. The unfinished
#      file then stays in the streaming folder, where a restore looks for it.
#   3. It moves every unfinished file that holds something from Barman's
#      streaming folder into the kept folder, under the file's name with the
#      time and the first eight characters of its SHA-256, and leaves an
#      empty file of the old name. The empty file makes the listener begin
#      at that same WAL file.
#
# With the second word start-over it is the move of
# "connect-validator.sh --start-over": step 2 is left out, every unfinished
# file leaves the streaming folder, the empty one too, and nothing is left
# in its place.
#
#   sh move-unfinished.sh validator1 start-over
#
# It deletes nothing, and it never writes over a file: the move is "mv -n",
# and the shell refuses to write into a file that exists (set -C).
set -u
set -C
umask 077
LC_ALL=C
export LC_ALL

SERVER=${1:-}
MODE=${2:-start}
case $SERVER in
  validator1|rehearsal) ;;
  *)
    echo "move-unfinished: the first word is Barman's name for the server: validator1 (or rehearsal, in the rehearsal)" >&2
    exit 1
    ;;
esac
case $MODE in
  start|start-over) ;;
  *)
    echo "move-unfinished: the second word can only be start-over" >&2
    exit 1
    ;;
esac

STORE=/var/lib/barman
STREAMING=$STORE/$SERVER/streaming
KEPT=$STORE/$SERVER/kept
LOCK=$STORE/.$SERVER-receive-wal.lock
CONF=/etc/barman.d/$SERVER.conf
PSQL=/usr/lib/postgresql/17/bin/psql

# 1. No move while a listener runs. Barman holds this lock (flock) for as
#    long as "barman receive-wal" runs.
if [ -e "$LOCK" ]; then
  lock_state=0
  flock -n "$LOCK" true || lock_state=$?
  if [ "$lock_state" -eq 1 ]; then
    echo "move-unfinished: a listener of $SERVER is running; nothing moved"
    exit 1
  fi
  if [ "$lock_state" -ne 0 ]; then
    echo "move-unfinished: Barman's lock file $LOCK cannot be looked at (flock ended with $lock_state); nothing moved"
    exit 1
  fi
fi

# 2. No move, and no start of the listener, while PostgreSQL does not answer.
if [ "$MODE" = start ]; then
  if [ ! -r "$CONF" ]; then
    echo "move-unfinished: $CONF is missing; nothing moved, the listener is not started"
    exit 1
  fi
  CONNINFO=$(sed -n 's/^conninfo = //p' "$CONF" | head -n 1)
  if [ -z "$CONNINFO" ] || ! "$PSQL" -X -At -q -c 'select 1' "$CONNINFO" >/dev/null 2>&1; then
    echo "move-unfinished: PostgreSQL does not answer through the line; nothing moved, the listener is not started"
    exit 1
  fi
fi

# 3. The move.
if ! mkdir -p "$KEPT"; then
  echo "move-unfinished: the kept folder $KEPT cannot be made; nothing moved"
  exit 1
fi
moved=0
for file in "$STREAMING"/*.partial; do
  [ -e "$file" ] || continue
  if [ "$MODE" = start ] && [ ! -s "$file" ]; then
    continue
  fi
  name=${file##*/}
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if [ -s "$file" ]; then
    tag=$(sha256sum "$file" | cut -c1-8)
  else
    tag=empty
  fi
  if [ -z "$tag" ]; then
    echo "move-unfinished: the SHA-256 of $name cannot be worked out; nothing more is moved"
    exit 1
  fi
  target=$KEPT/$name.$stamp.$tag
  n=1
  while [ -e "$target" ]; do
    n=$((n + 1))
    target=$KEPT/$name.$stamp.$tag.$n
  done
  mv -n "$file" "$target"
  if [ -e "$file" ] || [ ! -e "$target" ]; then
    echo "move-unfinished: $name could not be moved into the kept folder"
    exit 1
  fi
  if [ "$MODE" = start ]; then
    if ! true > "$file"; then
      echo "move-unfinished: the empty file $name could not be left in the streaming folder"
      exit 1
    fi
  fi
  echo "move-unfinished: $name moved to kept/${target##*/}"
  moved=$((moved + 1))
done
if [ "$moved" -eq 0 ]; then
  echo "move-unfinished: no unfinished file to move"
fi
exit 0
