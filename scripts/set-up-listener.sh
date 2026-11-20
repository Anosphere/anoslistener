#!/bin/sh
# Sets up listener1: the points L1 to L7, one line printed per point. Run on
# listener1 as root, from the clone:
#
#   sh /opt/listener/listenersoftware/scripts/set-up-listener.sh
#
#   L1   look: Debian 13, the memory, the disk
#   L1b  the Volume: found, given a file system when it holds none, and
#        mounted at /var/lib/barman, before any package is installed
#   L2   the packages: PostgreSQL 17 with no database of its own, Barman,
#        curl, git, rsync, ufw, and Node 24
#   L2b  Barman's own minute job, off
#   L3   SSH by key only; the firewall lets in port 22 and nothing else
#   L4   the user line, its empty key file, and its part of sshd's settings
#   L5   the clone of the validator's repository, for the chain check
#   L6   the five units, installed and not switched on
#   L7   the end: listener1's public host key line, for the worker
#
# It looks first and is safe to run again: every point does what is still
# missing and says "already" for what is done. It never formats a disk that
# holds a file system, and it never empties the key file of the user line.
#
# It needs nothing typed and asks nothing. Everything the commands print
# goes to /opt/listener/logs/set-up-listener.log.
set -eu

SCRIPT=set-up-listener.sh
REPO=/opt/listener/listenersoftware
VALIDATOR_REPO=/opt/listener/anosvalidator
LOG_DIR=/opt/listener/logs
LOG=$LOG_DIR/set-up-listener.log
STORE=/var/lib/barman
ETC=/etc/listener
KEYS=$ETC/line.authorized_keys
SSHD_DIR=/etc/ssh/sshd_config.d
CRON_FILE=/etc/cron.d/barman
UNITS='listener-receive@.service listener-archive@.service listener-archive@.timer listener-check.service listener-check.timer'
PACKAGES='postgresql-common postgresql-17 postgresql-client-17 barman curl git rsync ufw'

LC_ALL=C
LANG=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root
DEBIAN_FRONTEND=noninteractive
export LC_ALL LANG PATH HOME DEBIAN_FRONTEND

if [ "$(id -u)" -ne 0 ]; then
  echo "failed at the start: run as root: sh $REPO/scripts/$SCRIPT" >&2
  exit 1
fi
if [ ! -f "$REPO/scripts/$SCRIPT" ] || [ ! -f "$REPO/listener/sshd-line.conf" ]; then
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

# installed PACKAGE: dpkg says so.
installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

# all_installed: every package of L2 is there.
all_installed() {
  for package in $PACKAGES; do
    installed "$package" || return 1
  done
}

# node_is_24: node -v starts with v24.
node_is_24() {
  case $(node -v 2>/dev/null || true) in
    v24.*) return 0 ;;
  esac
  return 1
}

# show_disks: every disk this server sees, to the screen and to the log.
show_disks() {
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | while IFS= read -r disk_line; do
    say "    $disk_line"
  done
}

# sshd_file TARGET: the file "$TMP/sshd-file" goes to TARGET in sshd's
# settings folder. When sshd then refuses its settings, what was there
# before is put back, so that a later restart of sshd never meets a file it
# cannot read. Then a reload.
sshd_file() {
  rm -f "$TMP/sshd-file.before"
  if [ -f "$1" ]; then
    cp -p "$1" "$TMP/sshd-file.before"
  fi
  install -o root -g root -m 644 "$TMP/sshd-file" "$1"
  if ! sshd -t; then
    if [ -f "$TMP/sshd-file.before" ]; then
      cp -p "$TMP/sshd-file.before" "$1"
    else
      rm -f "$1"
    fi
    fail "sshd refuses its settings with the new file $1 in place; what was there before is back. The reason is at the end of $LOG"
  fi
  systemctl reload ssh
}

if [ $# -gt 0 ]; then
  fail "this script takes no word after its name, got \"$1\""
fi
TMP=$(mktemp -d)

# L1. Look: Debian 13, the memory, the disk.
at L1 look
DEBIAN=$(cat /etc/debian_version)
case $DEBIAN in
  13|13.*) ;;
  *) fail "this server runs Debian $DEBIAN; the plan asks for Debian 13" ;;
esac
CPUS=$(nproc)
MEMORY_MB=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
SYSTEM_DISK=$(df -hP / | awk 'NR == 2 { print $2 ", " $4 " free" }')
say "L1 look: Debian $DEBIAN, $CPUS CPUs, $MEMORY_MB MB of memory, the system disk $SYSTEM_DISK"

# L1b. The Volume. Exactly one disk beside the system disk that holds no
#      partition. A file system is made only on a disk that holds none; a
#      disk that holds one is used as it is and never formatted again. The
#      mount is by the file system's UUID, with a line in /etc/fstab that
#      has nofail. All of this comes before the packages, so that every
#      file of Barman's is on the Volume from the first one.
at L1b 'the Volume'
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_DISK=$(lsblk -n -o PKNAME "$ROOT_SOURCE" 2>/dev/null | head -n 1)
if [ -z "$ROOT_DISK" ]; then
  ROOT_DISK=${ROOT_SOURCE#/dev/}
fi
VOLUME=''
CANDIDATES=0
for disk in $(lsblk -d -n -o NAME,TYPE | awk '$2 == "disk" { print $1 }'); do
  if [ "$disk" = "$ROOT_DISK" ]; then
    continue
  fi
  # A disk that holds a partition is not the Volume.
  if [ "$(lsblk -n -o NAME "/dev/$disk" | wc -l)" -ne 1 ]; then
    continue
  fi
  VOLUME=/dev/$disk
  CANDIDATES=$((CANDIDATES + 1))
done
if [ "$CANDIDATES" -ne 1 ]; then
  say "L1b the Volume: this script looks for exactly one disk beside the system disk ($ROOT_DISK) that holds no partition, and it finds $CANDIDATES. What this server sees:"
  show_disks
  fail "the Volume listener1-store is not here as expected ($CANDIDATES disks fit). Nothing was changed. In the Hetzner console the server needs exactly one Volume"
fi
VOLUME_SIZE=$(lsblk -d -n -o SIZE "$VOLUME" | tr -d ' ')
MOUNTED_AT=$(findmnt -n -o TARGET -S "$VOLUME" | head -n 1)
if [ -n "$MOUNTED_AT" ] && [ "$MOUNTED_AT" != "$STORE" ]; then
  say "L1b the Volume: $VOLUME is mounted at $MOUNTED_AT already. That is the mount option automatic of the Hetzner console; the plan asks for manual. What this server sees:"
  show_disks
  fail "the Volume is mounted at $MOUNTED_AT, not at $STORE. Nothing was changed"
fi
if [ "$MOUNTED_AT" = "$STORE" ]; then
  FS_TYPE=$(findmnt -n -o FSTYPE "$STORE")
  FS_UUID=$(blkid -o value -s UUID "$VOLUME")
  grep -q "^UUID=$FS_UUID[[:space:]]" /etc/fstab || fail "$VOLUME is mounted at $STORE, but /etc/fstab has no line for its UUID $FS_UUID: it would not come back after a restart. Nothing was changed"
  VOLUME_LINE=already
else
  if mountpoint -q "$STORE"; then
    fail "something else is mounted at $STORE: $(findmnt -n -o SOURCE "$STORE"). Nothing was changed"
  fi
  if [ -d "$STORE" ] && [ -n "$(ls -A "$STORE")" ]; then
    fail "$STORE holds files already and is not on the Volume: Barman was installed before the Volume was mounted. Nothing was changed"
  fi
  if installed barman; then
    fail "the package barman is installed already, and $STORE is not on the Volume. Nothing was changed"
  fi
  # blkid -p looks at the disk itself. It ends with 2 when it finds nothing
  # at all, and with 0 when it finds something. Any other end (it could not
  # read the disk, or what it found does not fit together) is not "empty".
  BLKID_STATE=0
  SIGNATURES=$(blkid -p "$VOLUME" 2>/dev/null) || BLKID_STATE=$?
  FS_TYPE=$(blkid -p -o value -s TYPE "$VOLUME" 2>/dev/null || true)
  if [ "$BLKID_STATE" -ne 0 ] && [ "$BLKID_STATE" -ne 2 ]; then
    fail "blkid cannot say what $VOLUME holds (it ended with $BLKID_STATE), so the Volume is not taken for empty. Nothing was changed, and nothing was formatted"
  fi
  if [ "$BLKID_STATE" -eq 2 ] && [ -z "$SIGNATURES" ] && [ -z "$FS_TYPE" ] && [ -z "$(lsblk -d -n -o FSTYPE "$VOLUME" | tr -d ' ')" ]; then
    # The disk holds no file system and nothing else that blkid knows.
    mkfs.ext4 "$VOLUME" </dev/null
    FS_TYPE=ext4
    FS_LINE='a file system made (ext4)'
  else
    case $FS_TYPE in
      ext4|xfs) FS_LINE="its file system used as it is ($FS_TYPE), not formatted" ;;
      *)
        say "L1b the Volume: $VOLUME holds something that is neither empty nor a file system this script uses. What blkid sees: ${SIGNATURES:-nothing it can name}"
        fail "the Volume is neither empty nor ext4 or xfs. Nothing was changed, and nothing was formatted"
        ;;
    esac
  fi
  FS_UUID=$(blkid -p -o value -s UUID "$VOLUME")
  [ -n "$FS_UUID" ] || fail "the file system on $VOLUME has no UUID that blkid can read"
  mkdir -p "$STORE"
  if ! grep -q "^UUID=$FS_UUID[[:space:]]" /etc/fstab; then
    if awk '$1 !~ /^#/ && $2 == "/var/lib/barman"' /etc/fstab | grep -q .; then
      fail "/etc/fstab has a line for $STORE already, and it is not the Volume's. Nothing more was changed"
    fi
    # A file whose last line has no end would have the new line glued to it.
    if [ -s /etc/fstab ] && [ -n "$(tail -c 1 /etc/fstab)" ]; then
      printf '\n' >> /etc/fstab
    fi
    printf '%s\n' "UUID=$FS_UUID $STORE $FS_TYPE defaults,nofail 0 2" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount "$STORE"
  VOLUME_LINE="$FS_LINE, a line in /etc/fstab by its UUID with nofail"
fi
mountpoint -q "$STORE" || fail "$STORE is not a mount after the mount"
[ "$(findmnt -n -o SOURCE "$STORE")" = "$VOLUME" ] || fail "$STORE is mounted from $(findmnt -n -o SOURCE "$STORE"), not from $VOLUME"
say "L1b the Volume: $VOLUME, $VOLUME_SIZE, mounted at $STORE: $VOLUME_LINE"

# L2. The packages. postgresql-common first, with its setting that no
#     database is made at the install; then the others from Debian; Node 24
#     from NodeSource, the way the worker's own script gets it. Not cron and
#     not gzip.
at L2 'the packages'
if all_installed && node_is_24; then
  PACKAGES_LINE=already
else
  apt-get update
  apt-get install -y postgresql-common
  if [ -d /etc/postgresql-common/createcluster.d ]; then
    printf '%s\n' '# listener1 holds no database of its own: none is made when postgresql-17 is' '# installed (listenersoftware, scripts/set-up-listener.sh).' 'create_main_cluster = false' > /etc/postgresql-common/createcluster.d/listener.conf
  elif ! grep -Eq '^[[:space:]]*create_main_cluster[[:space:]]*=[[:space:]]*false' /etc/postgresql-common/createcluster.conf; then
    printf '%s\n' '' '# listener1 holds no database of its own (listenersoftware, scripts/set-up-listener.sh).' 'create_main_cluster = false' >> /etc/postgresql-common/createcluster.conf
  fi
  apt-get install -y postgresql-17 postgresql-client-17 barman curl git rsync ufw
  if ! node_is_24; then
    curl -fsSL https://deb.nodesource.com/setup_24.x -o "$TMP/nodesource-setup.sh"
    bash "$TMP/nodesource-setup.sh"
    apt-get install -y nodejs
  fi
  all_installed || fail "not every package is installed after the install: $PACKAGES"
  node_is_24 || fail "node is \"$(node -v 2>&1 || true)\" after the install, not v24"
  PACKAGES_LINE=installed
fi
if pg_lsclusters -h | awk '$2 == "main"' | grep -q .; then
  fail "a database was made at the install of PostgreSQL (pg_lsclusters shows a cluster main): the setting create_main_cluster = false did not hold. listener1 must run no database of its own"
fi
BARMAN_V=$(dpkg-query -W -f='${Version}' barman)
case $BARMAN_V in
  3.13.*) ;;
  *) fail "Debian installed Barman $BARMAN_V. The plan was made and tried with Barman 3.13.3, and what Barman deletes by itself differs between versions. Nothing more was changed" ;;
esac
id barman >/dev/null 2>&1 || fail 'the package barman is installed, and the user barman is not there'
if [ "$(stat -c '%U:%G' "$STORE")" != barman:barman ]; then
  chown barman:barman "$STORE"
fi
PSQL_V=$(/usr/lib/postgresql/17/bin/psql --version | sed 's/^psql (PostgreSQL) //')
say "L2 the packages: $PACKAGES_LINE; PostgreSQL $PSQL_V with no database of its own, Barman $BARMAN_V, node $(node -v), curl, git, rsync, ufw; $STORE belongs to barman"

# L2b. Barman's own minute job, off. Debian's package brings
#      /etc/cron.d/barman, whose job line runs "barman -q cron" every
#      minute. That would start the listener without the move of
#      scripts/move-unfinished.sh. A "#" goes before every job line.
at L2b "Barman's own minute job"
if [ ! -f "$CRON_FILE" ]; then
  CRON_LINE="no file $CRON_FILE, so nothing runs it"
elif grep -Eq '^[[:space:]]*[0-9*@]' "$CRON_FILE"; then
  sed -i -E 's/^([[:space:]]*[0-9*@])/#\1/' "$CRON_FILE"
  if grep -Eq '^[[:space:]]*[0-9*@]' "$CRON_FILE"; then
    fail "$CRON_FILE still has a job line after the change"
  fi
  CRON_LINE="switched off: a # before the job line of $CRON_FILE"
else
  CRON_LINE="already off: $CRON_FILE has no job line"
fi
say "L2b Barman's own minute job: $CRON_LINE"

# L3. SSH by key only, with the monitor's file 10-key-only.conf. Then ufw:
#     port 22 in, nothing else, on IPv4 and IPv6.
at L3 'SSH by key only, and the firewall'
[ -s /root/.ssh/authorized_keys ] || fail "/root/.ssh/authorized_keys holds no key: SSH by key only would lock this server. Nothing more was changed"
printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' 'PermitRootLogin prohibit-password' > "$TMP/sshd-file"
if cmp -s "$TMP/sshd-file" "$SSHD_DIR/10-key-only.conf"; then
  SSH_LINE=already
else
  sshd_file "$SSHD_DIR/10-key-only.conf"
  SSH_LINE='set, sshd reloaded'
fi
SSHD_NOW=$(sshd -T)
printf '%s\n' "$SSHD_NOW" | grep -qx 'passwordauthentication no' || fail 'sshd still allows passwords (passwordauthentication is not no): another file of its settings wins'
printf '%s\n' "$SSHD_NOW" | grep -qx 'kbdinteractiveauthentication no' || fail 'sshd still allows keyboard-interactive logins (kbdinteractiveauthentication is not no): another file of its settings wins'
printf '%s\n' "$SSHD_NOW" | grep -Eqx 'permitrootlogin (without-password|prohibit-password)' || fail 'sshd does not hold root to a key (permitrootlogin): another file of its settings wins'
UFW_NOW=$(ufw status)
if printf '%s\n' "$UFW_NOW" | grep -q '^Status: active' && printf '%s\n' "$UFW_NOW" | grep -Eq '^22/tcp[[:space:]]+ALLOW'; then
  UFW_LINE=already
else
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw --force enable
  UFW_LINE='switched on'
  UFW_NOW=$(ufw status)
fi
printf '%s\n' "$UFW_NOW" | grep -q '^Status: active' || fail 'ufw is not active after it was switched on'
UFW_RULES=$(printf '%s\n' "$UFW_NOW" | grep -Ec '(ALLOW|DENY|REJECT|LIMIT)' || true)
UFW_22=$(printf '%s\n' "$UFW_NOW" | grep -Ec '^22/tcp( \(v6\))?[[:space:]]+ALLOW[[:space:]]+Anywhere' || true)
if [ "$UFW_RULES" -ne 2 ] || [ "$UFW_22" -ne 2 ]; then
  say 'L3 the firewall has other rules than port 22 on IPv4 and IPv6. What ufw shows:'
  printf '%s\n' "$UFW_NOW" | while IFS= read -r ufw_line; do
    say "    $ufw_line"
  done
  fail 'the firewall must let in port 22 and nothing else, on IPv4 and IPv6. Its rules were left as they are'
fi
say "L3 SSH by key only: $SSH_LINE; the firewall (ufw): $UFW_LINE, port 22 in and nothing else, on IPv4 and IPv6"

# L4. The user line, with no login shell. The folder /etc/listener with an
#     empty key file that belongs to root, so the login cannot add a key.
#     The sshd file that allows the one forward and nothing else.
at L4 'the user line'
if id line >/dev/null 2>&1; then
  USER_LINE=already
else
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin line
  USER_LINE=made
fi
if [ ! -d "$ETC" ]; then
  install -d -o root -g root -m 755 "$ETC"
fi
if [ -e "$KEYS" ]; then
  KEYS_LINE='already there (what it holds was left as it is)'
else
  install -o root -g root -m 644 /dev/null "$KEYS"
  KEYS_LINE='made, empty'
fi
chown root:root "$ETC" "$KEYS"
chmod 755 "$ETC"
chmod 644 "$KEYS"
cp "$REPO/listener/sshd-line.conf" "$TMP/sshd-file"
if cmp -s "$TMP/sshd-file" "$SSHD_DIR/20-listener-line.conf"; then
  MATCH_LINE=already
else
  sshd_file "$SSHD_DIR/20-listener-line.conf"
  MATCH_LINE='installed, sshd reloaded'
fi
say "L4 the user line: $USER_LINE, with no login shell; its key file $KEYS: $KEYS_LINE; sshd's file 20-listener-line.conf: $MATCH_LINE"

# L5. The clone of the validator's repository, for the chain check's two
#     packages and for the registry file. Nothing in it is started.
at L5 "the validator's clone"
if [ -d "$VALIDATOR_REPO/.git" ]; then
  CLONE_LINE=already
else
  git clone https://github.com/Anosphere/anosvalidator.git "$VALIDATOR_REPO"
  CLONE_LINE=cloned
fi
if [ -d "$VALIDATOR_REPO/node_modules/pg" ] && [ -d "$VALIDATOR_REPO/node_modules/canonicalize" ]; then
  NPM_LINE=already
else
  (cd "$VALIDATOR_REPO" && npm ci --omit=dev)
  NPM_LINE=run
fi
[ -f "$VALIDATOR_REPO/network/testnet.registry.json" ] || fail "the registry file is not in the clone: $VALIDATOR_REPO/network/testnet.registry.json"
say "L5 the validator's clone at $VALIDATOR_REPO: $CLONE_LINE, at commit $(git -C "$VALIDATOR_REPO" rev-parse --short HEAD); npm ci --omit=dev: $NPM_LINE; nothing in it is started"

# L6. The five units: installed, not switched on.
at L6 'the units'
UNITS_CHANGED=''
for unit in $UNITS; do
  [ -f "$REPO/listener/$unit" ] || fail "the clone has no file listener/$unit"
  if ! cmp -s "$REPO/listener/$unit" "/etc/systemd/system/$unit"; then
    install -o root -g root -m 644 "$REPO/listener/$unit" "/etc/systemd/system/$unit"
    UNITS_CHANGED="$UNITS_CHANGED $unit"
  fi
done
if [ -n "$UNITS_CHANGED" ]; then
  systemctl daemon-reload
  UNITS_LINE="installed:$UNITS_CHANGED. A unit that runs already uses its new file after its next restart"
else
  UNITS_LINE='already, all five'
fi
say "L6 the units: $UNITS_LINE; none is switched on by this script"

# L7. The end: listener1's public host key line, for the worker, last.
at L7 'the end'
HOST_KEY_FILE=/etc/ssh/ssh_host_ed25519_key.pub
[ -s "$HOST_KEY_FILE" ] || fail "$HOST_KEY_FILE is not there: sshd has no ed25519 host key"
HOST_KEY_LINE=$(awk 'NR == 1 { print $1 " " $2 }' "$HOST_KEY_FILE")
say "L7 the end: listener1 is set up. Prove the key from a second terminal before this session is closed. listener1's public host key line, for the worker:"
say "$HOST_KEY_LINE"
