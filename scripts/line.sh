#!/bin/sh
# The line: the one SSH connection from validator 1's worker to listener1.
# Run by the unit listener-line on the worker, as the user listener, never by
# hand (worker/listener-line.service):
#
#   ExecStart=/bin/sh /opt/listener/listenersoftware/scripts/line.sh
#
# LISTENER_ADDRESS and PG_PORT come from /etc/listener/line.env, through the
# unit.
#
# First the guard. A worker that came back from a backup is hours old, and
# its WAL would be a second history of validator 1 on listener1. So this
# script compares this VM's id with the one scripts/set-up-worker.sh wrote
# down, /etc/listener/worker-id, and stays down when they differ. The id is
# the VM's Google id, read from the metadata server. On a machine that is no
# Google VM it is /etc/machine-id, which is the rehearsal's way.
#
# Then it becomes the one ssh command. That command asks listener1 to listen
# on 127.0.0.1:5433 and to hand every connection there to this worker, where
# ssh passes it into PostgreSQL's socket file. PostgreSQL sees the local user
# listener. Nothing is sent to listener1 that Barman did not ask for.
#
# How it ends:
#   1  this VM's id cannot be read: the unit tries again in ten seconds
#   3  the id is another one, or the set-up is not whole: the unit stays
#      down (RestartPreventExitStatus=3)
#   else what ssh ends with: the unit opens the line again after ten seconds
set -u

ETC=/etc/listener

# this_vm_id: prints this VM's id. Fails when it cannot be read.
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

# The guard.
if ! VM_ID=$(this_vm_id); then
  echo "line: this VM's id cannot be read. The unit tries again in ten seconds."
  exit 1
fi
if [ ! -r "$ETC/worker-id" ]; then
  echo "line: $ETC/worker-id is missing: scripts/set-up-worker.sh has not finished on this machine. The line stays down."
  exit 3
fi
WRITTEN_ID=$(cat "$ETC/worker-id")
if [ "$VM_ID" != "$WRITTEN_ID" ]; then
  echo "line: the id differs. This VM's id is $VM_ID, and $ETC/worker-id holds $WRITTEN_ID: this worker is a copy of the one the line was set up on. The line stays down. scripts/set-up-worker.sh --new-worker writes the new id; that is a person's decision."
  exit 3
fi

# The two values of /etc/listener/line.env.
case ${LISTENER_ADDRESS:-} in
  ''|*[!0-9.]*)
    echo "line: LISTENER_ADDRESS is not an IPv4 address ($ETC/line.env). The line stays down."
    exit 3
    ;;
esac
case ${PG_PORT:-} in
  ''|*[!0-9]*)
    echo "line: PG_PORT is not a number ($ETC/line.env). The line stays down."
    exit 3
    ;;
esac

# The line itself: the command of the plan's appendix A.1.
exec /usr/bin/ssh -N -T -C \
  -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=15 \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/listener/known_hosts \
  -o IdentitiesOnly=yes -i /var/lib/listener/line.key \
  -R "127.0.0.1:5433:/var/run/postgresql/.s.PGSQL.$PG_PORT" \
  "line@$LISTENER_ADDRESS"
