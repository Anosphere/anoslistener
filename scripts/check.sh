#!/bin/sh
# The alarm's check. Run on listener1 as the user barman, once a minute, by
# listener-check.timer (listener/listener-check.service):
#
#   ExecStart=/bin/sh /opt/listener/listenersoftware/scripts/check.sh validator1
#
# Good means all three:
#   - Barman's own check of the server passes ("barman check" ends with 0);
#   - one listener is streaming and is less than 16 MB behind PostgreSQL;
#   - the disk that holds Barman's folder is less than 80 percent full.
#
# When good, it sends one empty request to the address in
# /etc/listener/ping-url (curl, ten seconds, three tries). The address is
# handed to curl on its standard input, so it is in no command line. When
# not good, it sends nothing and prints the reason, which the unit puts into
# the journal.
# Silence is the alarm: healthchecks.io sends the email when the pings stop.
# Nothing about validator 1 is ever sent to healthchecks.io.
#
# The check touches no WAL file. Moving the unfinished file is the work of
# the listener's unit alone (scripts/move-unfinished.sh).
#
# It prints one line, "check <server>: good ..." or "check <server>: not
# good: <why>", and ends with 0 when good and with 1 when not good. The
# rehearsal runs it for the server rehearsal; for that server no ping is
# sent.
set -u
LC_ALL=C
export LC_ALL

SERVER=${1:-}
case $SERVER in
  validator1|rehearsal) ;;
  *)
    echo "check: the one word is Barman's name for the server: validator1 (or rehearsal, in the rehearsal)" >&2
    exit 2
    ;;
esac

STORE=/var/lib/barman
CONF=/etc/barman.d/$SERVER.conf
PING_FILE=/etc/listener/ping-url
PSQL=/usr/lib/postgresql/17/bin/psql
# One WAL file: the listener must be less than this many bytes behind.
MAX_BEHIND=16777216
# The disk must be less than this many percent full.
MAX_FULL=80

REASONS=''
# reason TEXT: one more reason why it is not good.
reason() {
  if [ -z "$REASONS" ]; then
    REASONS=$1
  else
    REASONS="$REASONS; $1"
  fi
}

# 1. Barman's own check of the server.
check_state=0
CHECK=$(/usr/bin/barman check "$SERVER" 2>&1) || check_state=$?
if [ "$check_state" -ne 0 ]; then
  NOT_OK=$(printf '%s\n' "$CHECK" | grep -E '^[[:space:]]' | grep -v ': OK' | sed -e 's/^[[:space:]]*//' -e 's/:.*$//' | tr '\n' ',' | sed -e 's/,$//' -e 's/,/, /g')
  if [ -n "$NOT_OK" ]; then
    reason "barman check fails on: $NOT_OK"
  else
    reason "barman check ended with $check_state"
  fi
fi

# 2. The listeners that are streaming, and how far the nearest is behind.
#    Asked of PostgreSQL through the line, as Barman asks.
CONNINFO=''
if [ -r "$CONF" ]; then
  CONNINFO=$(sed -n 's/^conninfo = //p' "$CONF" | head -n 1)
fi
ANSWER=''
if [ -n "$CONNINFO" ]; then
  ANSWER=$("$PSQL" -X -At -q -c "select count(*) filter (where state = 'streaming') || '|' || coalesce(min(pg_wal_lsn_diff(pg_current_wal_lsn(), coalesce(write_lsn, sent_lsn))) filter (where state = 'streaming'), -1)::bigint from pg_stat_replication where application_name = 'barman_receive_wal'" "$CONNINFO" 2>/dev/null) || ANSWER=''
fi
STREAMING=${ANSWER%%|*}
BEHIND=${ANSWER#*|}
case $STREAMING in
  '')
    reason 'PostgreSQL does not answer through the line'
    ;;
  1)
    case $BEHIND in
      ''|*[!0-9]*)
        reason 'how far the listener is behind cannot be read'
        ;;
      *)
        if [ "$BEHIND" -ge "$MAX_BEHIND" ]; then
          reason "the listener is $BEHIND bytes behind PostgreSQL, 16 MB or more"
        fi
        ;;
    esac
    ;;
  0)
    reason 'no listener is streaming'
    ;;
  *)
    reason "$STREAMING listeners are streaming, not one"
    ;;
esac

# 3. How full the disk of Barman's folder is.
FULL=$(df -P "$STORE" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }')
case $FULL in
  ''|*[!0-9]*)
    reason "how full the disk of $STORE is cannot be read"
    ;;
  *)
    if [ "$FULL" -ge "$MAX_FULL" ]; then
      reason "the disk of $STORE is $FULL percent full, $MAX_FULL or more"
    fi
    ;;
esac

if [ -n "$REASONS" ]; then
  echo "check $SERVER: not good: $REASONS"
  exit 1
fi

GOOD="check $SERVER: good (barman check passes, one listener streaming and $BEHIND bytes behind, the disk $FULL percent full)"

# The ping, for validator 1 only.
if [ "$SERVER" != validator1 ]; then
  echo "$GOOD; no ping is sent for this server"
  exit 0
fi
if [ ! -r "$PING_FILE" ]; then
  echo "$GOOD; no ping sent: there is no ping address yet (scripts/set-ping-url.sh)"
  exit 0
fi
URL=$(head -n 1 "$PING_FILE")
case $URL in
  https://hc-ping.com/?*) ;;
  *)
    echo "$GOOD; no ping sent: $PING_FILE does not hold a ping address (scripts/set-ping-url.sh)"
    exit 0
    ;;
esac
case $URL in
  *[!A-Za-z0-9:/._~-]*)
    echo "$GOOD; no ping sent: $PING_FILE holds a character that does not belong in a ping address (scripts/set-ping-url.sh)"
    exit 0
    ;;
esac
try=1
while [ "$try" -le 3 ]; do
  # The address goes to curl on its standard input, as one line of settings,
  # and never as a word of the command: so it is in no list of processes.
  if printf 'url = "%s"\n' "$URL" | /usr/bin/curl -fsS -m 10 -o /dev/null -K - 2>/dev/null; then
    echo "$GOOD; ping sent"
    exit 0
  fi
  try=$((try + 1))
  sleep 2
done
echo "$GOOD; the ping could not be sent in three tries"
exit 0
