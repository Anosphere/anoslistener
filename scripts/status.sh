#!/bin/sh
# The state of the copy, for a person. Run on listener1 as root, from the
# clone, on any day, and first of all when the email comes:
#
#   sh /opt/listener/listenersoftware/scripts/status.sh
#
# It prints: Barman's check, the full copies, the listener's unit and its
# state, how far the listener is behind, the last check's result and time,
# how many files the kept folder holds and the room they take, whether
# Barman's own minute job is off, and the disk.
#
# It only looks. It changes nothing and sends nothing. One more word names
# another Barman server than validator1: "rehearsal", for a look after a
# rehearsal that failed.
set -u

REPO=/opt/listener/listenersoftware
STORE=/var/lib/barman
PSQL=/usr/lib/postgresql/17/bin/psql
CRON_FILE=/etc/cron.d/barman

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root: sh $REPO/scripts/status.sh" >&2
  exit 1
fi
SERVER=${1:-validator1}
case $SERVER in
  validator1|rehearsal) ;;
  *)
    echo "the one word after the script's name is Barman's name for the server: validator1 when left out, or rehearsal" >&2
    exit 1
    ;;
esac
cd /

KEPT=$STORE/$SERVER/kept
CONF=/etc/barman.d/$SERVER.conf
RECEIVE=listener-receive@$SERVER.service
ARCHIVE_TIMER=listener-archive@$SERVER.timer

echo "The copy of $SERVER on $(hostname), $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

echo "Barman's check:"
if [ -f "$CONF" ]; then
  runuser -u barman -- barman check "$SERVER" 2>&1 | sed 's/^/  /'
else
  echo "  Barman has no server $SERVER yet ($CONF is not there)"
fi
echo

echo 'The full copies:'
if [ -f "$CONF" ]; then
  COPIES=$(runuser -u barman -- barman list-backups "$SERVER" 2>&1)
  if [ -n "$COPIES" ]; then
    printf '%s\n' "$COPIES" | sed 's/^/  /'
  else
    echo '  none'
  fi
else
  echo '  none'
fi
echo

echo "The listener's unit:"
SINCE=$(systemctl show -p ActiveEnterTimestamp --value "$RECEIVE" 2>/dev/null || true)
echo "  $RECEIVE is $(systemctl is-active "$RECEIVE" 2>/dev/null || true); its last start was at ${SINCE:-no time yet}"
echo "  $ARCHIVE_TIMER is $(systemctl is-active "$ARCHIVE_TIMER" 2>/dev/null || true); listener-check.timer is $(systemctl is-active listener-check.timer 2>/dev/null || true)"
echo

echo 'How far the listener is behind:'
CONNINFO=''
if [ -f "$CONF" ]; then
  CONNINFO=$(sed -n 's/^conninfo = //p' "$CONF" | head -n 1)
fi
ANSWER=''
if [ -n "$CONNINFO" ]; then
  ANSWER=$("$PSQL" -X -At -q -c "select count(*) filter (where state = 'streaming') || '|' || coalesce(min(pg_wal_lsn_diff(pg_current_wal_lsn(), coalesce(write_lsn, sent_lsn))) filter (where state = 'streaming'), -1)::bigint from pg_stat_replication where application_name = 'barman_receive_wal'" "$CONNINFO" 2>/dev/null) || ANSWER=''
fi
if [ -z "$ANSWER" ]; then
  echo '  PostgreSQL does not answer through the line'
else
  echo "  listeners streaming: ${ANSWER%%|*}; the nearest is ${ANSWER#*|} bytes behind PostgreSQL (-1: none is streaming)"
fi
echo

echo 'The last check (scripts/check.sh, once a minute):'
LAST_CODE=$(systemctl show -p ExecMainStatus --value listener-check.service 2>/dev/null || true)
LAST_TIME=$(systemctl show -p ExecMainExitTimestamp --value listener-check.service 2>/dev/null || true)
if [ -z "$LAST_TIME" ]; then
  echo '  it has not run yet'
else
  case $LAST_CODE in
    0) LAST_RESULT=good ;;
    1) LAST_RESULT='not good' ;;
    *) LAST_RESULT="it ended with $LAST_CODE" ;;
  esac
  echo "  $LAST_RESULT, at $LAST_TIME"
  journalctl -u listener-check.service -n 30 --no-pager -o cat 2>/dev/null | grep '^check ' | tail -n 1 | sed 's/^/  /'
fi
echo

echo 'The kept folder:'
if [ -d "$KEPT" ]; then
  echo "  $KEPT holds $(find "$KEPT" -type f | wc -l | tr -d ' ') files, which take $(du -sh "$KEPT" | cut -f1)"
else
  echo "  $KEPT is not there yet"
fi
echo

echo "Barman's own minute job:"
if [ ! -f "$CRON_FILE" ]; then
  echo "  off: there is no file $CRON_FILE"
elif grep -Eq '^[[:space:]]*[0-9*@]' "$CRON_FILE"; then
  echo "  ON, and it must be off: $CRON_FILE has a job line. It starts the listener without the move. scripts/set-up-listener.sh switches it off"
else
  echo "  off: $CRON_FILE has no job line"
fi
echo

echo 'The disk:'
if mountpoint -q "$STORE"; then
  echo "  $STORE is a mount of $(findmnt -n -o SOURCE "$STORE")"
else
  echo "  $STORE IS NOT A MOUNT: the Volume is not attached"
fi
df -hP "$STORE" | awk 'NR == 2 { print "  " $2 " in all, " $3 " used, " $4 " free, " $5 " full (the alarm rings at 80%)" }'
