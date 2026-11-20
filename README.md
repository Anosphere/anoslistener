# listenersoftware

The WAL listener for validator 1: a copy of validator 1's whole PostgreSQL,
outside Google, about one second behind.

Today the newest copy of a validator is the Google vault's, and it is up to
4 hours old. This repository sets up a small server at Hetzner, `listener1`,
that holds a copy of validator 1's whole PostgreSQL: the `anos` database
(the chain, the waiting rows, `logs`, `archives`) and the `keyholder`
database. The tool is Barman 3.13.3, from Debian 13's own packages.
Validator 1 never waits for the copy. When the copy stops, an email comes.
listener1 keeps everything it ever received: nothing there is deleted, and
nothing is written over.

How it works:

- Validator 1's worker opens one SSH connection to listener1 and keeps it
  open. That is the line. It carries PostgreSQL's own socket file to
  `127.0.0.1:5433` on listener1. PostgreSQL still listens only on the worker
  itself, and there is no password anywhere.
- Barman on listener1 asks PostgreSQL through the line and stores the
  answers: one full copy, taken at the set-up, and the WAL as it is written.
- Barman pulls. The worker's key can do one thing on listener1: hold the
  line open. Nothing on listener1 is written by the worker.
- Once a minute listener1 checks itself. When all is good it sends one empty
  ping to healthchecks.io. When something is wrong it sends nothing. Silence
  is the alarm: the email comes after about six minutes.

Nothing in this repository is secret: no address, no key, no ping address.
Nothing here changes the validator, the doorman or the keyholder, and no
other validator is touched. What is added on validator 1's worker comes off
again with one script.

The plan it is built from is `forclaude/wal-listener-plan-1.md`, beside the
repositories (FINAL, 2026-11-19). The record is `docs/schemas.md`: what every
file is for, what each script prints, where things live on the two machines,
and the notes where the plan is silent.

Nothing in this repository ran on Debian, with systemd or against a server
before the walk below. Copies of the scripts ran on the build's Mac, with
stand-ins for what a Mac lacks (`docs/schemas.md`, section 6). Stage 3 of
the walk, the rehearsal, is the first real run: listener1 plays both parts
with a throwaway PostgreSQL, before validator 1 is touched.

## What is in it

| Folder | What it holds |
| --- | --- |
| `listener/` | for listener1: Barman's file for the server, sshd's file for the line, the five units, and a copy of the chain check |
| `worker/` | for validator 1's worker: the unit of the line |
| `scripts/` | the twelve scripts. Nine are for listener1: `set-up-listener.sh`, `rehearse.sh`, `add-worker-key.sh`, `connect-validator.sh`, `move-unfinished.sh`, `set-ping-url.sh`, `check.sh`, `status.sh`, `practice-restore.sh`. Three are for the worker: `set-up-worker.sh`, `line.sh`, `remove-from-worker.sh` |
| `docs/` | `schemas.md`, the record |

Every script is a POSIX `sh` script and is run with `sh`. Each one looks
first, is safe to run twice, and prints one line a point. On both machines
the clone is `/opt/listener/listenersoftware`, owned by root.

## The walk

The walk is the plan's section 11, line for line. Where it names a section,
a decision or a reading, it means the plan's.

One stage a message, in a chat. The user runs every line and pastes what it prints.
Nothing runs against a server from a chat. Lines for listener1 go into an SSH
session as root on listener1, opened on the masterpod computer. Lines for the worker
go into an SSH session on validator 1's worker, opened in Cloud Shell with the
project `banker-484021` picked. Lines for the doorman go into an SSH session on
validator 1's doorman, opened the same way. `<...>` stands for a value from an
earlier stage.

Before the first line: the repository is on GitHub `main` of
`https://github.com/Anosphere/anoslistener.git`, and this plan is final.

Stage 1, the Hetzner console. A new project, `listener`. The estate-bootstrap public
key added to it. A new server: CPX11, Ashburn, Debian 13, IPv4 and IPv6, the key
ticked, one Volume of 50 GB (decision 38; the name `listener1-store`, the mount
option `manual`), no Hetzner firewall, no backups, the name `listener1`.
The clicks are given in the walk.

Stage 2, listener1. The login, on the masterpod computer:

```text
ssh -o ServerAliveInterval=20 -i ~/.ssh/estate-bootstrap root@<listener1's IPv4>
```

The look. Prints the name, the address, Debian's version, the CPUs, the memory, the
system disk, and every disk the server sees. The Volume must be among them.

```text
hostname; ip -4 -br addr show eth0; cat /etc/debian_version; nproc; free -m | sed -n 2p; df -h / | tail -1; lsblk -dn -o NAME,SIZE,TYPE
```

The updates and the restart. The session ends by itself.

```text
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold full-upgrade -y && apt-get autoremove -y && reboot
```

The clone and the set-up. Prints L1 to L7, and listener1's host key line last.

```text
apt-get install -y git && git clone https://github.com/Anosphere/anoslistener.git /opt/listener/listenersoftware && sh /opt/listener/listenersoftware/scripts/set-up-listener.sh
```

Then the key is proven from a second terminal before this session is closed.

Stage 3, listener1, the rehearsal. The last line must be `REHEARSAL PASSED`.

```text
sh /opt/listener/listenersoftware/scripts/rehearse.sh
```

Stage 4, the worker. The login, in Cloud Shell of `banker-484021`:

```text
gcloud compute ssh banker@worker --zone us-east1-b --tunnel-through-iap
```

The clone and the set-up. Prints W1 to W8, and the worker's public key line last.

```text
sudo git clone https://github.com/Anosphere/anoslistener.git /opt/listener/listenersoftware
```

```text
sudo sh /opt/listener/listenersoftware/scripts/set-up-worker.sh --listener <listener1's IPv4> --host-key "<listener1's host key line>"
```

Stage 5, listener1. The worker's key, accepted from the doorman's address only. The
doorman's public IPv4 is the address in row 1 of the registry, and in
`forclaude/validators-record.md`.

```text
sh /opt/listener/listenersoftware/scripts/add-worker-key.sh --from <the doorman's public IPv4> "<the worker's public key line>"
```

Stage 6. First the doorman's count, before the line exists (reading 41). The login,
in Cloud Shell of `banker-484021`, and then the count, on the doorman:

```text
gcloud compute ssh banker@doorman --zone us-east1-b --tunnel-through-iap
```

```text
sudo nft list quota inet doorman egress-month
```

Then the worker. The line. Prints `active`.

```text
sudo systemctl start listener-line; sleep 5; systemctl is-active listener-line
```

Stage 7, listener1. The copy. Prints C1 to C7; the first full copy is in it. The
last line must be `validator1: the copy is running`.

```text
sh /opt/listener/listenersoftware/scripts/connect-validator.sh
```

Stage 8, the alarm. At healthchecks.io: the check `listener1`, period 1 minute,
grace 5 minutes. Then on listener1, with the check's ping address pasted at the
question:

```text
sh /opt/listener/listenersoftware/scripts/set-ping-url.sh
```

Stage 9, the alarm's test. On the worker the line is stopped. The email must come
within about seven minutes. Then the line is started again, and the second email
says the check is up.

```text
sudo systemctl stop listener-line
```

```text
sudo systemctl start listener-line; sleep 5; systemctl is-active listener-line
```

Stage 10, listener1, the practice restore. The last line must be
`PRACTICE RESTORE PASSED`.

```text
sh /opt/listener/listenersoftware/scripts/practice-restore.sh validator1
```

Stage 11, a day later. On listener1 the state, and on the doorman the count again.
Against the count of stage 6 it shows what validator 1 and the line sent out
together in that day. This is the first measured figure of the real line.

```text
sh /opt/listener/listenersoftware/scripts/status.sh
```

```text
sudo nft list quota inet doorman egress-month
```

## Later

The lines for the days after the walk. Lines for listener1 go into an SSH
session as root on listener1. Lines for the worker and for the doorman go
into their SSH sessions, opened in Cloud Shell as in the walk. No line holds
a dollar sign.

The state, on listener1. It only looks: Barman's check, the full copies, the
listener's unit, how far it is behind, the last check, the kept folder,
Barman's own minute job, and the disk.

```text
sh /opt/listener/listenersoftware/scripts/status.sh
```

A practice restore, on any day. It only reads Barman's store, and it is the
way to notice a stored file that is damaged. The last line must be
`PRACTICE RESTORE PASSED`.

```text
sh /opt/listener/listenersoftware/scripts/practice-restore.sh validator1
```

### When the email comes

On listener1, `status.sh` first. Then:

| what it shows | what it means | what to do |
|---|---|---|
| no listener is streaming, and the worker's `systemctl status listener-line` says it keeps trying | the network, or listener1 was restarted | wait; it comes back by itself |
| the same, and on the doorman `nft list quota inet doorman egress-month` shows more than 102400 MB used | the doorman's month is used up, and the line's traffic is part of it. The doorman now drops everything validator 1 sends out, not the line alone | find out what used it. If it was the line, stop the line on the worker first. Then wait for the 1st, or set the doorman's count back |
| the unit on the worker is down and its journal says the id differs | this worker is a copy of the one the line was set up on | "If validator 1 is lost", below |
| `replication slot` or `receive-wal running` is `FAILED`, and the line is up | the listener's unit is down, or its listener keeps ending | the listener's journal says why. Never `barman cron`: it starts the listener without the move |
| the same, and the journal says `requested WAL segment ... has already been removed` | the line was down while more than 4 GB of WAL was written | `connect-validator.sh --start-over` |
| `failed backups` is `FAILED` | a full copy broke off | `connect-validator.sh --full-copy`. It moves the broken copy's folder and its note file into the kept folder, as `failed-copy-<its id>`, and takes the full copy again. Never `barman delete` |
| `systemid coherence` is `FAILED` | the PostgreSQL behind the line is not the one the full copy was made from | nothing on listener1; "If validator 1 is lost", below |
| the disk of `/var/lib/barman` is 80 percent full or more | nothing is deleted, so the room runs out one day | the Volume made larger: in the Hetzner console, then the two lines below. Until then the alarm stays down and cannot ring for anything else |
| the disk is full | the copy has stopped; the email at 80 percent came before it | the same, at once |
| `/var/lib/barman` is not a mount, and no unit of the listener runs | the Volume is not attached | the Hetzner console; then the server restarted, or the line below |
| no email, and the page of healthchecks.io shows no pings | listener1 itself is gone | the Hetzner console |

The lines the table names.

On listener1, the listener's journal:

```text
journalctl -u listener-receive@validator1 -n 30 --no-pager
```

On listener1, after `requested WAL segment ... has already been removed`. It
moves every unfinished file into the kept folder, drops the slot and makes
it again, and takes a new full copy. The full copy from before the hole
stays, with its WAL. The last line must be `validator1: started over; a new
full copy is there, and the full copy from before the hole stays, with its
WAL`.

```text
sh /opt/listener/listenersoftware/scripts/connect-validator.sh --start-over
```

On listener1, after a full copy that broke off, or when a stored file is
found damaged. The older full copies stay. The last line must be
`validator1: a new full copy is there, and the older ones stay`.

```text
sh /opt/listener/listenersoftware/scripts/connect-validator.sh --full-copy
```

On listener1, after the Volume was made larger in the Hetzner console. The
first line makes the file system as large as the Volume. The second shows
the new size.

```text
findmnt -n -o SOURCE /var/lib/barman | xargs resize2fs
```

```text
df -h /var/lib/barman | tail -1
```

On listener1, after the Volume was attached again without a restart of the
server:

```text
mount /var/lib/barman && systemctl start listener-receive@validator1 listener-archive@validator1.timer listener-check.timer
```

On the worker, the line: its state and its last lines, then the two lines
that stop it and start it.

```text
systemctl status listener-line --no-pager | head -12
```

```text
sudo systemctl stop listener-line
```

```text
sudo systemctl start listener-line; sleep 5; systemctl is-active listener-line
```

On the doorman, the count of the month, and the line that sets it back to
nothing before the 1st:

```text
sudo nft list quota inet doorman egress-month
```

```text
sudo nft reset quota inet doorman egress-month
```

### If validator 1 is lost

- Nothing has to be done on listener1. The full copy and all the WAL after
  it stay: no program there deletes anything.
- Until validator 1's database is back, do not run `--start-over` or
  `--full-copy`.
- Do not delete anything under `/var/lib/barman`, then or ever.
- A worker restored from the Google vault keeps its line down by itself.
  Leave it down.
- The way back is worked out on the day, with the copy safe. The plan's
  section 13 lists what was tried about a restore. It looks in two places
  for the newest unfinished WAL file: the streaming folder,
  `/var/lib/barman/validator1/streaming`, and the kept folder,
  `/var/lib/barman/validator1/kept`.

At the end of a way back, on a worker that was made new: this writes the new
worker's id, so that its line may come up. It is a person's decision.

```text
sudo sh /opt/listener/listenersoftware/scripts/set-up-worker.sh --new-worker
```

### A new version of this repository

A fault the rehearsal finds, or a later change, is a change in this
repository, never a fix by hand on a server. After the push, on listener1:
the pull, then the set-up script again. It says `already` at every point
that did not change and installs a unit file that did.

```text
git -C /opt/listener/listenersoftware pull --ff-only
```

```text
sh /opt/listener/listenersoftware/scripts/set-up-listener.sh
```

On the worker, the same two:

```text
sudo git -C /opt/listener/listenersoftware pull --ff-only
```

```text
sudo sh /opt/listener/listenersoftware/scripts/set-up-worker.sh
```

A unit that runs already uses its new file only after its next restart.
Every restart of the listener's unit or of the line leaves one more file of
16 MB in the kept folder, so restart one only when the change needs it.

### A new ping address

On listener1. The address is asked for at the keyboard and is not shown.

```text
sh /opt/listener/listenersoftware/scripts/set-ping-url.sh
```

### Taking it all off the worker

On the worker. It stops and removes the unit, drops the slot and the
PostgreSQL user `listener`, sets `max_slot_wal_keep_size` back, and removes
the system user `listener`, `/var/lib/listener` and `/etc/listener`.
PostgreSQL is not restarted. It leaves the clone. listener1 keeps what it
has; its copy stops growing, and the email comes.

```text
sudo sh /opt/listener/listenersoftware/scripts/remove-from-worker.sh
```

### Never

- Never `barman cron` on listener1, by a program or by hand: it starts the
  listener without the move.
- Never `barman delete`, and never `barman receive-wal --reset`.
- Never delete or change a file under `/var/lib/barman`.
- A later update of Debian's `barman` package may ask about
  `/etc/cron.d/barman`. The changed file is the one to keep.
