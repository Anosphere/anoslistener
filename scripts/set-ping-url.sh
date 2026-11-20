#!/bin/sh
# Takes the ping address of the check at healthchecks.io and writes it to
# /etc/listener/ping-url. Run on listener1 as root, from the clone:
#
#   sh /opt/listener/listenersoftware/scripts/set-ping-url.sh
#
# It asks for the address at the keyboard, so the address is in no command
# line and in no history. What is pasted is not shown on the screen, so it
# is not in a copy of the screen either. It takes only an address that
# begins with https://hc-ping.com/ and writes it to the file as root and the
# group barman, mode 640: the check runs as the user barman and reads it
# (scripts/check.sh).
#
# The ping address is the one secret listener1 holds. This script sends no
# ping itself: only a check that found everything good sends one.
#
# A second run asks again and writes the new address over the old one.
set -eu

SCRIPT=set-ping-url.sh
REPO=/opt/listener/listenersoftware
ETC=/etc/listener
PING_FILE=$ETC/ping-url

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL LANG PATH

# stop REASON: nothing was changed.
stop() {
  echo "failed: $*. Nothing was changed." >&2
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sh $REPO/scripts/$SCRIPT" >&2
  exit 1
fi
if [ $# -gt 0 ]; then
  stop 'this script takes no word after its name: the address is asked for at the keyboard, so that it is in no command line'
fi
[ -d "$ETC" ] || stop "$ETC is not there: scripts/set-up-listener.sh first"
getent group barman >/dev/null || stop 'the group barman is not there: scripts/set-up-listener.sh first'
[ -t 0 ] || stop 'this script asks at the keyboard: run it in a terminal, with nothing piped into it'
cd /

# The question. The terminal's echo is off while the address is pasted, and
# back on whatever happens.
OLD_TERMINAL=$(stty -g)
trap 'stty "$OLD_TERMINAL" 2>/dev/null || true' EXIT
trap 'exit 1' INT TERM
printf 'The ping address of the check listener1 at healthchecks.io. Paste it and press Enter (it is not shown): '
stty -echo
URL=''
IFS= read -r URL || true
stty "$OLD_TERMINAL"
printf '\n'

URL=$(printf '%s' "$URL" | tr -d '[:space:]')
case $URL in
  https://hc-ping.com/?*) ;;
  *) stop 'it takes only an address that begins with https://hc-ping.com/' ;;
esac
case $URL in
  *[!A-Za-z0-9:/._~-]*) stop 'the address holds a character that does not belong in a ping address' ;;
esac

umask 077
printf '%s\n' "$URL" > "$PING_FILE.new"
chown root:barman "$PING_FILE.new"
chmod 640 "$PING_FILE.new"
mv "$PING_FILE.new" "$PING_FILE"
echo "the ping address is in $PING_FILE (root and the group barman, mode 640): ${#URL} characters, the last four are ${URL#"${URL%????}"}"
echo 'The check sends the first ping within a minute, when all is good. The page of the check at healthchecks.io shows it.'
