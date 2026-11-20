#!/bin/sh
# A practice restore on listener1: the proof that the copy gives validator
# 1's database back, the last second too. Run on listener1 as root, from the
# clone, on any day:
#
#   sh /opt/listener/listenersoftware/scripts/practice-restore.sh validator1
#
# It only reads Barman's store. (Barman's own restore begins by filing the
# finished WAL files that wait in the streaming folder, which is what the
# minute timer does too.) Validator 1 is not touched: the script asks it one
# thing, its public health answer.
#
#   P1  Barman's check of the server passes
#   P2  validator 1's public health answer: the chain's position and record
#       hash, as they are when the restore begins
#   P3  barman restore <server> latest /var/lib/barman/practice/data --get-wal
#   P4  the settings a practice needs: no network at all, a socket in a
#       folder only barman can enter, logins trusted on that socket,
#       hot_standby off, and Barman's own restore_command without the sudo
#   P5  PostgreSQL 17 is started on that folder as the user barman, and the
#       script waits until the replay of the WAL has ended
#   P6  the chain check against the practice copy; its last line must begin
#       with EVERYTHING IS PERFECT
#   P7  the copy's chain has reached the position of P2, with the same
#       record hash
#   P8  the row counts of the waiting tables and of the keyholder's tables
#   P9  the practice PostgreSQL is stopped and its folder removed, whatever
#       happened before
#
# The last line is "PRACTICE RESTORE PASSED", or "PRACTICE RESTORE FAILED at
# P<n>:" and why.
#
# For the server rehearsal, P2, P6, P7 and P8 are replaced by the look for
# the two rows the rehearsal wrote.
#
# The practice folder, /var/lib/barman/practice, is the practice's own and
# is removed at the end. Nothing of Barman's store is changed or removed.
#
# Everything the commands print goes to
# /opt/listener/logs/practice-restore.log.
set -eu

SCRIPT=practice-restore.sh
REPO=/opt/listener/listenersoftware
VALIDATOR_REPO=/opt/listener/anosvalidator
LOG_DIR=/opt/listener/logs
LOG=$LOG_DIR/practice-restore.log
STORE=/var/lib/barman
PRACTICE=$STORE/practice
DATA=$PRACTICE/data
SOCKET=$PRACTICE/socket
PG_LOG=$PRACTICE/postgresql.log
PG_BIN=/usr/lib/postgresql/17/bin
# The practice PostgreSQL listens on no network. The number only names its
# socket file, in its own folder.
PORT=5432

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sh $REPO/scripts/$SCRIPT validator1" >&2
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

# fail REASON: the run ends, and the EXIT trap cleans up and prints the last
# line. Never called inside $(...).
STEP=P0
REASON=''
fail() {
  REASON=$*
  exit 1
}

# as_barman COMMAND: as the user barman.
as_barman() {
  runuser -u barman -- "$@"
}

# clean_practice: P9. The practice PostgreSQL is stopped and the practice
# folder removed. The folder is the practice's own; Barman's store is not
# touched.
clean_practice() {
  if [ -f "$DATA/postmaster.pid" ]; then
    as_barman "$PG_BIN/pg_ctl" -D "$DATA" -m fast -w -t 60 stop || as_barman "$PG_BIN/pg_ctl" -D "$DATA" -m immediate -w -t 60 stop || true
  fi
  if [ -f "$PG_LOG" ]; then
    echo "--- the end of the practice PostgreSQL's own log:"
    tail -n 15 "$PG_LOG" || true
  fi
  rm -rf /var/lib/barman/practice
}

TMP=''
STARTED=0
on_exit() {
  status=$?
  trap - EXIT
  LOG_END=''
  if [ "$status" -ne 0 ] && [ -z "$REASON" ]; then
    LOG_END=$(tail -n 5 "$LOG")
    REASON="a command ended with an error; the lines above are from $LOG"
  fi
  if [ "$STARTED" -eq 1 ]; then
    clean_practice || true
    if [ -e "$PRACTICE" ]; then
      say "P9 the practice folder $PRACTICE could not be removed"
      if [ "$status" -eq 0 ]; then
        status=1
        STEP=P9
        REASON="the practice folder $PRACTICE could not be removed"
      fi
    else
      say 'P9 the practice PostgreSQL is stopped, and its folder is removed'
    fi
  fi
  if [ -n "$TMP" ]; then
    rm -rf "$TMP"
  fi
  if [ "$status" -eq 0 ]; then
    say 'PRACTICE RESTORE PASSED'
  else
    if [ -n "$LOG_END" ]; then
      printf '%s\n' "$LOG_END" >&3
    fi
    say "PRACTICE RESTORE FAILED at $STEP: $REASON"
  fi
  exit "$status"
}
trap on_exit EXIT

# stopped HOW CODE: a Ctrl-C or a lost session ends the script like any
# other failure, so that P9 still runs. Without these three lines the shell
# would end at once and leave the practice PostgreSQL and its folder behind.
stopped() {
  REASON="the script was stopped from outside ($1)"
  exit "$2"
}
trap 'stopped "the session was lost" 129' HUP
trap 'stopped Ctrl-C 130' INT
trap 'stopped "a TERM signal" 143' TERM

# practice_sql DATABASE SQL: one question to the practice copy, over its
# socket, as the copy's own user postgres.
practice_sql() {
  as_barman "$PG_BIN/psql" -X -At -q -v ON_ERROR_STOP=1 -h "$SOCKET" -p "$PORT" -U postgres -d "$1" -c "$2"
}

# The one word: Barman's name for the server.
SERVER=${1:-}
case $SERVER in
  validator1|rehearsal) ;;
  *) fail "the one word after the script's name is Barman's name for the server: validator1 (or rehearsal, in the rehearsal)" ;;
esac
if [ $# -gt 1 ]; then
  fail "only one word after the script's name, got \"$2\" too"
fi
[ -x /usr/bin/barman ] || fail 'Barman is not installed: scripts/set-up-listener.sh first'
[ -f "/etc/barman.d/$SERVER.conf" ] || fail "Barman has no server $SERVER: scripts/connect-validator.sh first"
mountpoint -q "$STORE" || fail "$STORE is not a mount: the Volume is not attached"
TMP=$(mktemp -d)

# A practice that was cut short left its folder; it goes first.
if [ -e "$PRACTICE" ]; then
  clean_practice
  [ ! -e "$PRACTICE" ] || fail "the folder of an earlier practice, $PRACTICE, could not be removed"
  say "P0 the folder of an earlier practice that was cut short: removed"
fi

# P1. Barman's check of the server passes.
STEP=P1
CHECK_STATE=0
as_barman barman check "$SERVER" > "$TMP/check.out" 2>&1 || CHECK_STATE=$?
cat "$TMP/check.out"
if [ "$CHECK_STATE" -ne 0 ]; then
  NOT_OK=$(grep -E '^[[:space:]]' "$TMP/check.out" | grep -v ': OK' | sed 's/^[[:space:]]*//' | tr '\n' ';' | sed -e 's/;$//' -e 's/;/; /g')
  fail "barman check does not pass: ${NOT_OK:-it ended with $CHECK_STATE}"
fi
say "P1 Barman's check of $SERVER: every line OK"

# P2. Validator 1's public health answer, through its doorman: the address
#     of row 1 of the registry file in the validator's clone, with /health.
POSITION=''
RECORD_HASH=''
if [ "$SERVER" = validator1 ]; then
  STEP=P2
  REGISTRY=$VALIDATOR_REPO/network/testnet.registry.json
  [ -f "$REGISTRY" ] || fail "the registry file is not there: $REGISTRY"
  URL=$(node -e '
const registry = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const row = (registry.validators || []).find((validator) => validator.id === 1);
if (!row || typeof row.url !== "string") process.exit(1);
console.log(row.url);
' "$REGISTRY") || fail "row 1 of the registry file cannot be read: $REGISTRY"
  case $URL in
    https://*) ;;
    *) fail "row 1 of the registry file has an address that does not begin with https://: \"$URL\"" ;;
  esac
  case $URL in
    *[!A-Za-z0-9:/._-]*) fail "row 1 of the registry file has an address with a character that does not belong in one: \"$URL\"" ;;
  esac
  curl -sS -m 20 -o "$TMP/health.json" "$URL/health" || fail "validator 1's public health answer cannot be read at $URL/health"
  TAIL=$(node -e '
const health = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const worker = health.worker || {};
const chain = worker.chain;
if (!worker.validator || worker.validator.id !== 1) {
  console.log("another");
} else if (!chain || !Number.isInteger(chain.position) || chain.position < 1 || !/^[0-9a-f]{64}$/.test(String(chain.recordHash))) {
  console.log("none");
} else {
  console.log(chain.position + " " + chain.recordHash);
}
' "$TMP/health.json") || fail "the answer at $URL/health is not the health answer of a doorman"
  case $TAIL in
    another) fail "the answer at $URL/health is not validator 1's" ;;
    none) fail "validator 1's public health answer shows no chain position and record hash (its worker may be down)" ;;
  esac
  POSITION=${TAIL%% *}
  RECORD_HASH=${TAIL#* }
  case $POSITION in
    ''|*[!0-9]*) fail "validator 1's public health answer has a chain position that is not a number" ;;
  esac
  say "P2 validator 1's public health answer ($URL/health): the chain is at position $POSITION, record hash $RECORD_HASH"
else
  say "P2 left out for the server $SERVER: P2, P6, P7 and P8 are replaced by the look for the two rows"
fi

# P3. Barman's restore of the newest full copy. With --get-wal the WAL is
#     not copied: PostgreSQL fetches it file by file as it replays, the
#     unfinished file too.
STEP=P3
STARTED=1
install -d -o barman -g barman -m 700 "$PRACTICE"
as_barman barman restore "$SERVER" latest "$DATA" --get-wal || fail 'barman restore ended with an error'
[ -f "$DATA/PG_VERSION" ] || fail "barman restore left no PostgreSQL data folder at $DATA"
say "P3 barman restore $SERVER latest $DATA --get-wal: the full copy is in the practice folder"

# P4. The settings a practice needs. The settings files themselves are
#     written fresh, because the copy holds none: on Debian they live in
#     /etc/postgresql, outside the data folder. The practice's own settings
#     go to the end of postgresql.auto.conf, after the lines Barman's
#     restore wrote there, so they win over every other line.
STEP=P4
install -d -o barman -g barman -m 700 "$SOCKET"
printf '%s\n' \
  '# Written fresh by practice-restore.sh: the copy holds no settings file.' \
  "# The practice's own settings are the last lines of postgresql.auto.conf." \
  > "$DATA/postgresql.conf"
printf '%s\n' \
  '# Written fresh by practice-restore.sh. Logins are trusted on the one socket,' \
  '# which lies in a folder only barman can enter. There is no network.' \
  'local all all trust' \
  > "$DATA/pg_hba.conf"
true > "$DATA/pg_ident.conf"
printf '%s\n' \
  '' \
  "# The practice's own settings (practice-restore.sh). They come last, so they win." \
  "listen_addresses = ''" \
  "port = $PORT" \
  "unix_socket_directories = '$SOCKET'" \
  'hot_standby = off' \
  "restore_command = 'barman get-wal -P $SERVER %f > %p'" \
  >> "$DATA/postgresql.auto.conf"
chown barman:barman "$DATA/postgresql.conf" "$DATA/pg_hba.conf" "$DATA/pg_ident.conf" "$DATA/postgresql.auto.conf"
chmod 600 "$DATA/postgresql.conf" "$DATA/pg_hba.conf" "$DATA/pg_ident.conf" "$DATA/postgresql.auto.conf"
[ -f "$DATA/recovery.signal" ] || fail "barman restore left no recovery.signal in $DATA: PostgreSQL would not replay the WAL"
say "P4 the practice's settings: no network at all, a socket in a folder only barman can enter, logins trusted on it, hot_standby off, restore_command = 'barman get-wal -P $SERVER %f > %p'"

# P5. PostgreSQL 17 on that folder, as the user barman. pg_ctl comes back
#     before the replay has ended, so the script looks at the data folder
#     itself. The replay has ended when PostgreSQL runs, has taken its file
#     recovery.signal away, and the folder says "in production". The folder
#     alone is not enough: a full copy says "in production" from the start,
#     as the worker did when it was copied.
STEP=P5
BEGAN=$(date +%s)
# 3>&-: the practice PostgreSQL does not carry this script's screen along.
as_barman "$PG_BIN/pg_ctl" -D "$DATA" -l "$PG_LOG" -w -t 120 start 3>&- || true
waited=0
while :; do
  if ! as_barman "$PG_BIN/pg_ctl" -D "$DATA" status >/dev/null 2>&1; then
    fail "the practice PostgreSQL does not run: it did not start, or it ended before the replay of the WAL was done. Its last lines: $(tail -n 3 "$PG_LOG" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  STATE=$(as_barman "$PG_BIN/pg_controldata" -D "$DATA" 2>/dev/null | sed -n 's/^Database cluster state:[[:space:]]*//p')
  if [ "$STATE" = 'in production' ] && [ ! -e "$DATA/recovery.signal" ]; then
    break
  fi
  sleep 2
  waited=$((waited + 2))
  if [ $((waited % 300)) -eq 0 ]; then
    say "P5 the replay of the WAL is still running after $((waited / 60)) minutes"
  fi
done
REPLAY_SECONDS=$(($(date +%s) - BEGAN))
answered=0
tries=0
while [ "$tries" -lt 30 ]; do
  if practice_sql postgres 'select 1' >/dev/null 2>&1; then
    answered=1
    break
  fi
  tries=$((tries + 1))
  sleep 2
done
if [ "$answered" -ne 1 ]; then
  fail "the replay of the WAL has ended, and the practice PostgreSQL lets no connection in. What it says: $(practice_sql postgres 'select 1' 2>&1 | tr '\n' ' ' || true)"
fi
TIMELINE=$(practice_sql postgres 'select timeline_id from pg_control_checkpoint()')
say "P5 the practice PostgreSQL: started as the user barman; the replay of the WAL ended about $REPLAY_SECONDS seconds after its start (it is now on timeline $TIMELINE)"

if [ "$SERVER" = validator1 ]; then
  # P6. The chain check, against the database anos of the practice copy. It
  #     takes pg and canonicalize from the validator's clone.
  STEP=P6
  CHAIN_STATE=0
  as_barman env PGHOST="$SOCKET" PGPORT="$PORT" PGUSER=postgres PGDATABASE=anos node "$REPO/listener/verify-garlic-chain.mjs" --repo "$VALIDATOR_REPO" > "$TMP/chain.out" 2> "$TMP/chain.err" || CHAIN_STATE=$?
  cat "$TMP/chain.out" "$TMP/chain.err"
  CHAIN_LAST=$(grep -v '^[[:space:]]*$' "$TMP/chain.out" | tail -n 1)
  case $CHAIN_LAST in
    'EVERYTHING IS PERFECT'*) ;;
    *) fail "the chain check did not end with EVERYTHING IS PERFECT (it ended with $CHAIN_STATE). Its last line: ${CHAIN_LAST:-$(tail -n 1 "$TMP/chain.err")}" ;;
  esac
  [ "$CHAIN_STATE" -eq 0 ] || fail "the chain check's last line is \"$CHAIN_LAST\", and it ended with $CHAIN_STATE, not 0"
  CHAIN_LINKS=$(sed -n 's/^  links[[:space:]]*//p' "$TMP/chain.out" | head -n 1)
  say "P6 the chain check against the practice copy: $CHAIN_LAST (links: ${CHAIN_LINKS:-not shown})"

  # P7. The copy's chain has reached the position of P2, and its record
  #     hash at that position is the one of P2.
  STEP=P7
  COPY_TAIL=$(practice_sql anos 'select coalesce(max(position), 0) from garlic_chain')
  [ "$COPY_TAIL" -ge "$POSITION" ] || fail "the copy's chain ends at position $COPY_TAIL, and validator 1's public health answer showed position $POSITION when the restore began"
  COPY_HASH=$(practice_sql anos "select encode(record_hash, 'hex') from garlic_chain where position = $POSITION")
  [ "$COPY_HASH" = "$RECORD_HASH" ] || fail "at position $POSITION the copy's record hash is $COPY_HASH, and validator 1's public health answer showed $RECORD_HASH"
  say "P7 the copy's chain has reached position $POSITION with the same record hash (the copy's chain ends at position $COPY_TAIL)"

  # P8. The row counts of the waiting tables and of the keyholder's tables.
  #     The chain check does not look at these; they are only counted.
  STEP=P8
  ANOS_COUNTS=''
  for table in pending locked_transactions assisted_transfers escrow_transfers escrow_arbitrations fund_proposals guardian_votes logs archives; do
    rows=$(practice_sql anos "select count(*) from $table") || fail "the rows of the table $table in the database anos cannot be counted"
    ANOS_COUNTS="$ANOS_COUNTS, $table $rows"
  done
  KEYHOLDER_COUNTS=''
  for table in owners shares waiting_copies; do
    rows=$(practice_sql keyholder "select count(*) from $table") || fail "the rows of the table $table in the database keyholder cannot be counted"
    KEYHOLDER_COUNTS="$KEYHOLDER_COUNTS, $table $rows"
  done
  say "P8 the row counts. anos: ${ANOS_COUNTS#, }. keyholder: ${KEYHOLDER_COUNTS#, }"
else
  # The server rehearsal: the look for the two rows the rehearsal wrote
  # (scripts/rehearse.sh, R1 and R6).
  STEP=P6
  ROWS=$(practice_sql anos "select coalesce(string_agg(id::text, ',' order by id), 'none') from rehearsal_rows") || fail "the table rehearsal_rows of the database anos cannot be read in the practice copy"
  [ "$ROWS" = '1,2' ] || fail "the practice copy holds the rows \"$ROWS\" of the rehearsal, and it must hold 1,2: the second row lives only in the unfinished WAL file"
  say "P6 the look for the two rows, in place of P6, P7 and P8: both are in the practice copy (rows $ROWS)"
fi

# P9 and the last line are the EXIT trap's.
exit 0
