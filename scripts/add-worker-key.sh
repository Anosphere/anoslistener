#!/bin/sh
# Accepts the worker's key on listener1, for the line and for nothing else.
# Run on listener1 as root, from the clone:
#
#   sh /opt/listener/listenersoftware/scripts/add-worker-key.sh --from <the doorman's public IPv4> "<the worker's public key line>"
#
#   --from   the one address the key is accepted from: the public IPv4 of
#            validator 1's doorman, which the worker's connections leave by
#   the key  the worker's public key line, as scripts/set-up-worker.sh prints
#            it last: "ssh-ed25519 AAAA...", in double quotes
#
# It takes exactly one ed25519 public key line and writes
# /etc/listener/line.authorized_keys with it, as one line:
#
#   from="<the address>",restrict,port-forwarding ssh-ed25519 <the key>
#
# With that line the key can do one thing on listener1: hold the line open.
# sshd's own file for the user line (listener/sshd-line.conf) allows the one
# forward, to 127.0.0.1:5433, and nothing else. The key file belongs to
# root, so the login cannot add a key.
#
# The file holds one key at a time: a key that was there before is replaced.
# A second run with the same values changes nothing and says "already".
set -eu

SCRIPT=add-worker-key.sh
REPO=/opt/listener/listenersoftware
ETC=/etc/listener
KEYS=$ETC/line.authorized_keys

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
  echo "failed at the start: run as root: sh $REPO/scripts/$SCRIPT --from <the doorman's public IPv4> \"<the worker's public key line>\"" >&2
  exit 1
fi
cd /
umask 022

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

# The arguments.
FROM=''
KEY_LINE=''
while [ $# -gt 0 ]; do
  case $1 in
    --from)
      [ $# -ge 2 ] || stop '--from needs a value'
      [ -z "$FROM" ] || stop '--from given twice'
      FROM=$2
      shift 2
      ;;
    --*) stop "unknown flag \"$1\"; the one flag is --from" ;;
    *)
      [ -z "$KEY_LINE" ] || stop 'this script takes exactly one public key line, in double quotes'
      KEY_LINE=$1
      shift
      ;;
  esac
done
[ -n "$FROM" ] || stop "--from is needed: the doorman's public IPv4, the one address the key is accepted from"
is_ipv4 "$FROM" || stop "--from must be an IPv4 address, four numbers 0 to 255 with dots, got \"$FROM\""
[ -n "$KEY_LINE" ] || stop "the worker's public key line is needed, in double quotes: the line scripts/set-up-worker.sh prints last"
KEY_BODY=$(public_key_body "$KEY_LINE") || stop 'the key must be one ed25519 public key line, "ssh-ed25519 AAAA..."'

[ -d "$ETC" ] || stop "$ETC is not there: scripts/set-up-listener.sh first"
id line >/dev/null 2>&1 || stop 'the user line is not there: scripts/set-up-listener.sh first'

# ssh-keygen must be able to read the key too. It prints the fingerprint,
# which is of the public half.
CHECK_FILE=$(mktemp)
trap 'rm -f "$CHECK_FILE"' EXIT
printf '%s\n' "ssh-ed25519 $KEY_BODY" > "$CHECK_FILE"
FINGERPRINT=$(ssh-keygen -l -f "$CHECK_FILE" 2>/dev/null | awk '{ print $2 }') || FINGERPRINT=''
[ -n "$FINGERPRINT" ] || stop 'ssh-keygen cannot read the key: it is not a whole ed25519 public key'

WANTED="from=\"$FROM\",restrict,port-forwarding ssh-ed25519 $KEY_BODY"
if [ -f "$KEYS" ] && [ "$(cat "$KEYS")" = "$WANTED" ]; then
  echo "already: $KEYS holds this key, accepted from $FROM only (fingerprint $FINGERPRINT)"
  exit 0
fi
WAS='it was empty'
if [ -s "$KEYS" ]; then
  WAS='the key that was there before is replaced'
fi
printf '%s\n' "$WANTED" > "$KEYS.new"
chown root:root "$KEYS.new"
chmod 644 "$KEYS.new"
mv "$KEYS.new" "$KEYS"
echo "the worker's key is accepted: from $FROM only, and only to hold the line open (fingerprint $FINGERPRINT). $KEYS holds this one key; $WAS."
