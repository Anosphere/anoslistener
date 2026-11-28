# listenersoftware: the record

What every file is for, what each script prints, where things live on the
two machines, and at the end the notes: every choice the build made where
the plan is silent.

Built from `~/Desktop/Z-TestNet/forclaude/wal-listener-plan-1.md` (FINAL,
2026-11-19), in that plan's step 1, on 2026-11-19. Where this file says "the
plan", "section 7", "reading 17" or "decision 35", it means that file. The
lines the operator runs are in `README.md`: "The walk" is the plan's section
11, line for line, and "Later" has the lines for the days after it.

What the build ran and what it did not run is in section 6. In short:
nothing in this repository has run on Debian, with systemd, or against a
server. Stage 3 of the walk, the rehearsal, is the first run.

## 1. The shape

```text
validator 1, at Google (banker-484021)                 listener1, at Hetzner (Ashburn)

  worker                                                 Barman
    PostgreSQL 17                                          one full copy, from the set-up
      the databases anos and keyholder                     the WAL as it is written
    the unit listener-line ── SSH, out through ─────────▶ sshd, the user `line`
      carries PostgreSQL's socket file    the doorman      may only hold the line open
                                                         127.0.0.1:5433 is validator 1's PostgreSQL
```

- The worker opens one SSH connection to listener1 and keeps it open: the
  line. It asks listener1 to listen on `127.0.0.1:5433` and passes every
  connection that arrives there into PostgreSQL's socket file on the worker.
- Barman on listener1 asks PostgreSQL through that port, as the PostgreSQL
  user `listener`, and stores the answers under `/var/lib/barman/validator1`,
  which lies on the Volume.
- The listener is Barman's `barman receive-wal`, run as a unit of its own.
  Before every start a script moves the unfinished WAL file into the kept
  folder, so the listener never writes into a file it has written to before.
- Nothing on listener1 is ever deleted or written over (decision 35).

## 2. The files

### 2.1 `README.md`, `docs/schemas.md`, `LICENSE` and `.gitignore`

| File | What it is for |
| --- | --- |
| `README.md` | what the repository is; the walk, which is the plan's section 11, line for line; and "Later", the lines for the days after the walk |
| `docs/schemas.md` | this file |
| `LICENSE` | the Apache 2.0 text, the same file as in the other repositories. Not in the plan's tree; added on the user's word |
| `.gitignore` | one line, `.DS_Store`: the file a Mac's Finder leaves in a folder it has shown. Not in the plan's tree; added on the user's word |

### 2.2 `listener/`, for listener1

| File | Installed as | By | What it is for |
| --- | --- | --- | --- |
| `barman-server.conf` | `/etc/barman.d/validator1.conf` | `connect-validator.sh`, point C2 | Barman's settings for the server: where PostgreSQL is (`127.0.0.1:5433`, the line), the slot `listener1`, `worm_mode = on`. The plan's appendix A.4, as it stands there. It has no `compression`, no `retention_policy` and no `last_backup_maximum_age` line: each would bring back a deletion or a copy by the calendar. For the server `rehearsal` the script fills in the name and a description of its own |
| `sshd-line.conf` | `/etc/ssh/sshd_config.d/20-listener-line.conf` | `set-up-listener.sh`, point L4 | sshd's settings for the user `line`: a key only, the key file `/etc/listener/line.authorized_keys`, one forward to `127.0.0.1:5433`, no shell, no terminal, no other forward. Appendix A.3 |
| `listener-receive@.service` | `/etc/systemd/system/` | `set-up-listener.sh`, point L6 | the listener. The name after the `@` is Barman's name for the server. Before every start it runs `scripts/move-unfinished.sh`; then `barman receive-wal`. When that ends, for any reason, it starts again after ten seconds. Appendix A.5 |
| `listener-archive@.service` | `/etc/systemd/system/` | L6 | one run of `barman archive-wal`: each finished WAL file goes from the streaming folder into Barman's store |
| `listener-archive@.timer` | `/etc/systemd/system/` | L6 | runs the unit above once a minute, at second 00 |
| `listener-check.service` | `/etc/systemd/system/` | L6 | one run of `scripts/check.sh validator1` |
| `listener-check.timer` | `/etc/systemd/system/` | L6 | runs the unit above once a minute, at second 20, so it does not start together with the archive timer |
| `verify-garlic-chain.mjs` | not installed; run from the clone | `practice-restore.sh`, point P6 | the chain check. A copy of `anossoftwarescripts/verify-garlic-chain.mjs`, byte for byte. It takes its two packages from the validator's clone, `/opt/listener/anosvalidator`. Since 2026-11-28 the copy is the chain check as step 4 of validator fund payment plan 1 (`~/Desktop/Z-TestNet/forclaude/validator-fund-payment-plan-1.md`) changed it, so that it knows a payment to the Fund, a link of type `paymentToFund`, and it was compared again with `anossoftwarescripts/verify-garlic-chain.mjs` on that day, byte for byte (section 6 of this file) |

All three service units have `RequiresMountsFor=/var/lib/barman`: with no
Volume there is no listener, no archiving and no ping, and nothing is
written to the small system disk in its place. No unit takes a full copy.

### 2.3 `worker/`, for validator 1's worker

| File | Installed as | By | What it is for |
| --- | --- | --- | --- |
| `listener-line.service` | `/etc/systemd/system/listener-line.service` | `set-up-worker.sh`, point W7 | the line. It runs `scripts/line.sh` as the user `listener`, opens the line again ten seconds after it drops, and stays down when the script ends with 3. Appendix A.1 |

### 2.4 `scripts/`

Every script is a POSIX `sh` script and is run with `sh`. "Root" says
whether it must be run as root.

| Script | Machine | Run by | Root | What it does |
| --- | --- | --- | --- | --- |
| `set-up-listener.sh` | listener1 | the operator, stage 2 | yes | sets listener1 up: points L1 to L7 (section 5) |
| `rehearse.sh` | listener1 | the operator, stage 3 | yes | the rehearsal: listener1 plays both parts with a throwaway PostgreSQL and runs the scripts as the points R1 to R10 list them (section 9) |
| `add-worker-key.sh` | listener1 | the operator, stage 5 | yes | writes the worker's public key into the key file of the user `line`, limited to one address and to forwarding (section 6) |
| `connect-validator.sh` | listener1 | the operator, stage 7 | yes | connects Barman: points C1 to C7. `--full-copy` and `--start-over` are for later (section 6) |
| `move-unfinished.sh` | listener1 | the listener's unit, before every start | no, the user `barman` | moves the unfinished WAL file into the kept folder (section 7) |
| `set-ping-url.sh` | listener1 | the operator, stage 8 | yes | asks for the ping address at the keyboard and writes it to `/etc/listener/ping-url` (section 8) |
| `check.sh` | listener1 | `listener-check.timer`, once a minute | no, the user `barman` | the alarm's check; one ping when all is good (section 8) |
| `status.sh` | listener1 | the operator, any day | yes | prints the state of the copy, for a person. It only looks |
| `practice-restore.sh` | listener1 | the operator, stage 10 and any day | yes | a practice restore: points P1 to P9 (section 10) |
| `set-up-worker.sh` | the worker | the operator, stage 4 | yes | sets the worker up for the line: points W1 to W8 (section 4) |
| `line.sh` | the worker | the unit `listener-line` | no, the user `listener` | the guard, then the one `ssh` command (section 7) |
| `remove-from-worker.sh` | the worker | the operator, if ever | yes | takes everything `set-up-worker.sh` added off again (section 4) |

Each script stands alone. The few helper lines they share are repeated in
each, because the plan's tree has no shared file.

## 3. What each script prints

The scripts that work through points print one line a point to the screen
and keep everything their commands print in a log (section 4.3). When one
stops, its last line is `failed at <point> (<its name>): <why>`. The other
scripts print straight to the screen.

### 3.1 `set-up-listener.sh`

`L1` the look. `L1b` the Volume. `L2` the packages. `L2b` Barman's own
minute job. `L3` SSH by key only, and the firewall. `L4` the user `line`.
`L5` the validator's clone. `L6` the units. `L7` the end. The last line of
all is listener1's public host key line, for the worker: `ssh-ed25519 AAAA...`.

A second run says `already` at every point that is done. A pull that changed
a unit file or sshd's file makes L6 or L4 install the new one.

### 3.2 `set-up-worker.sh`

`W1` the look. `W2` the system user `listener`. `W3` its SSH key. `W4` the
folder `/etc/listener`. `W5` the PostgreSQL user `listener`. `W6`
`max_slot_wal_keep_size`. `W7` the unit `listener-line`. `W8` the end: the
line that starts the unit. The last line of all is the worker's public key
line, for listener1.

A second run changes nothing and prints `already` at each point. When
`/etc/listener/worker-id` holds another id than this VM's, the script stops
at W1 and says that this worker is a copy of the one the line was set up on.
`--new-worker` writes the new id.

### 3.3 `remove-from-worker.sh`

`1` the unit. `2` PostgreSQL: the slot, the grants and the user, the
setting. `3` the system user `listener` and `/var/lib/listener`. `4` the
folder `/etc/listener`. Then `done: ...`.

### 3.4 `add-worker-key.sh`

One line: `the worker's key is accepted: from <address> only, ...`, with the
fingerprint of the public key. Or `already: ...`.

### 3.5 `connect-validator.sh`

`C1` the look through the line. `C2` Barman's file for the server. `C3` the
listener's unit, the slot, the WAL file closed early. `C4` Barman's check
before the full copy. `C5` the full copy. `C6` Barman's check. `C7` the
timers. The last line is `validator1: the copy is running`.

`--full-copy` prints `C1`, `C5`, `C6`, and last
`validator1: a new full copy is there, and the older ones stay`.

`--start-over` prints `C1`, one line `start-over: ...`, `C5`, `C6`, and last
`validator1: started over; a new full copy is there, and the full copy from
before the hole stays, with its WAL`.

### 3.6 `move-unfinished.sh`

One line for each file it moves:
`move-unfinished: <file> moved to kept/<file>.<time>.<eight characters>`. Or
`no unfinished file to move`. Or why it moved nothing: a listener is
running, or PostgreSQL does not answer through the line. The unit puts the
lines into the journal: `journalctl -u listener-receive@validator1`.

It ends with 0 when it moved a file or had none to move, and with 1 in
every other case. With 1 the listener is not started in that round.

### 3.7 `check.sh`

One line: `check validator1: good (...)`, with whether the ping was sent, or
`check validator1: not good: <why>`. It ends with 0 when good, with 1 when
not good, and with 2 when its one word is wrong. The unit puts the line into
the journal: `journalctl -u listener-check`.

### 3.8 `set-ping-url.sh`

It asks one question. What is pasted is not shown. Then one line that says
where the address is, how many characters it has, and its last four.

### 3.9 `status.sh`

Eight short parts: Barman's check; the full copies; the listener's unit and
the two timers; how far the listener is behind; the last check's result and
time, with its line; the kept folder; Barman's own minute job; the disk.

### 3.10 `practice-restore.sh`

`P1` Barman's check. `P2` validator 1's public health answer. `P3` Barman's
restore. `P4` the practice's settings. `P5` the practice PostgreSQL and the
end of the replay. `P6` the chain check. `P7` the position and the record
hash. `P8` the row counts. `P9` the clean-up. The last line is
`PRACTICE RESTORE PASSED`, or `PRACTICE RESTORE FAILED at P<n>:` and why.

For the server `rehearsal` it prints `P1`, `P2` (left out), `P3`, `P4`,
`P5`, one line `P6` for the look for the two rows, and `P9`.

### 3.11 `rehearse.sh`

`R1` to `R9`, one line each, and `R0` first when it cleaned up what an
earlier rehearsal left. The last line is `REHEARSAL PASSED`, or
`REHEARSAL FAILED at R<n>:` and why. The lines of the scripts it runs (`W1`
to `W8`, `C1` to `C7`, `P1` to `P9`) go to its log, not to the screen; when
one of them fails, the last lines of the log are shown above the last line.

### 3.12 `line.sh`

It prints only when it does not open the line, and the unit puts that into
the journal: `journalctl -u listener-line`. It ends with 1 when this VM's id
cannot be read (the unit tries again in ten seconds), and with 3 when the id
differs or the set-up is not whole (the unit stays down). Otherwise it
becomes `ssh`, and the unit opens the line again ten seconds after `ssh`
ends.

## 4. Where things live

### 4.1 On listener1

| Place | What it is |
| --- | --- |
| `/opt/listener/listenersoftware` | the clone of this repository, owned by root. The units run its scripts |
| `/opt/listener/anosvalidator` | the clone of the validator's repository, with `npm ci --omit=dev`. For the chain check's two packages and for the registry file. Nothing in it is started |
| `/opt/listener/logs` | the scripts' logs, root only |
| `/var/lib/barman` | the Volume, mounted by its UUID with `nofail`. Barman's folder. Everything below is on the Volume |
| `/var/lib/barman/validator1/base` | the full copies, one folder each |
| `/var/lib/barman/validator1/meta` | Barman's note file for each full copy (`worm_mode` keeps it apart from the copy) |
| `/var/lib/barman/validator1/wals` | the finished WAL files, and Barman's list of them, `validator1-xlog.db`, the one file Barman rewrites |
| `/var/lib/barman/validator1/streaming` | the unfinished WAL file, which the listener is writing now |
| `/var/lib/barman/validator1/kept` | the kept folder: every unfinished file the listener will not write to any more, as `<name>.<time>.<first eight characters of its SHA-256>`, and what is left of a full copy that broke off, as `failed-copy-<its id>`. No program deletes from it, and none writes into a file that is in it |
| `/var/lib/barman/practice` | the practice restore's own folder. It exists only while a practice restore runs |
| `/etc/barman.d/validator1.conf` | Barman's file for the server |
| `/etc/barman.conf`, `/var/log/barman/barman.log` | as Debian's package ships them. Barman's own log |
| `/etc/cron.d/barman` | Debian's file for Barman's own minute job, with a `#` before its job line (point L2b) |
| `/etc/listener/line.authorized_keys` | the one key the user `line` accepts. Root's file, mode 644 |
| `/etc/listener/ping-url` | the ping address. Root and the group `barman`, mode 640. The one secret on listener1 |
| `/etc/ssh/sshd_config.d/10-key-only.conf` | SSH by key only |
| `/etc/ssh/sshd_config.d/20-listener-line.conf` | sshd's settings for the user `line` |
| `/etc/postgresql-common/createcluster.d/listener.conf` | `create_main_cluster = false`: no database is made when PostgreSQL is installed |
| `/etc/fstab` | one line for the Volume |

Users on listener1: `barman` (Debian's package makes it; Barman, the
listener and the check run as it) and `line` (a system user with no login
shell and no home; the worker's key logs in as it). listener1 runs no
database of its own. A PostgreSQL runs there only during the rehearsal and
during a practice restore.

### 4.2 On validator 1's worker

| Place | What it is |
| --- | --- |
| `/opt/listener/listenersoftware` | the clone of this repository, owned by root |
| `/opt/listener/logs` | the logs of `set-up-worker.sh` and `remove-from-worker.sh`, root only |
| `/etc/listener/line.env` | `LISTENER_ADDRESS` and `PG_PORT`: listener1's address and PostgreSQL's port |
| `/etc/listener/known_hosts` | listener1's host key, as `<address> ssh-ed25519 <key>` |
| `/etc/listener/worker-id` | this VM's Google `id`, as it was at the set-up |
| `/var/lib/listener` | the home of the system user `listener`, mode 700 |
| `/var/lib/listener/line.key`, `line.key.pub` | the line's SSH key, made on the worker. The private half never leaves the worker and is never printed |
| `/etc/systemd/system/listener-line.service` | the unit of the line |

In PostgreSQL on the worker: the user `listener` (it may log in and read the
WAL, has no password, at most 10 connections, and Barman's grants; it can
change no row), the slot `listener1`, and the setting
`max_slot_wal_keep_size = 4GB` in `postgresql.auto.conf`. No file of
PostgreSQL's settings is edited, and PostgreSQL is not restarted.

Nothing else on the worker is touched. The validator's and the keyholder's
folders, their units and their databases' rows are not changed.

### 4.3 The logs

| Log | Written by |
| --- | --- |
| `/opt/listener/logs/set-up-listener.log` | `set-up-listener.sh` |
| `/opt/listener/logs/rehearse.log` | `rehearse.sh`; it also holds the lines of the scripts the rehearsal runs |
| `/opt/listener/logs/connect-validator.log` | `connect-validator.sh` |
| `/opt/listener/logs/practice-restore.log` | `practice-restore.sh`; it also holds the end of the practice PostgreSQL's own log |
| `/opt/listener/logs/set-up-worker.log` | `set-up-worker.sh` |
| `/opt/listener/logs/remove-from-worker.log` | `remove-from-worker.sh` |

A log grows; nothing trims it. No log holds a private key or the ping
address. The listener, the archiving, the check and the line write to the
journal of their units.

### 4.4 Names and numbers

| Name | What it is |
| --- | --- |
| `validator1` | Barman's name for the server. The scripts take this name and `rehearsal`, and no other |
| `rehearsal` | Barman's name for the rehearsal's throwaway PostgreSQL |
| `listener1` | the server at Hetzner; also the name of the slot in PostgreSQL |
| `listener` | on the worker: the system user that runs the line, and the PostgreSQL user Barman asks as |
| `line` | on listener1: the user the worker's key logs in as |
| port 5433 | on listener1's loopback only: the line's end. Behind it is PostgreSQL's socket file on the worker |
| port 5440 | the throwaway PostgreSQL of the rehearsal |
| `rehearsal_rows` | the one small table the rehearsal makes in its database `anos` |
| 16 MB | one WAL file. The check calls the listener good while it is less than this behind |
| 80 percent | how full the disk of `/var/lib/barman` may be before the check says not good |
| 4 GB | the WAL PostgreSQL holds back for a listener that is away |

## 5. How the pieces work

### 5.1 The guard of the line

`line.sh` compares this VM's id with `/etc/listener/worker-id` before every
start of the line. A worker restored from the Google vault has the same disk
and so the same files, and another Google `id`; its line stays down. The id
is read from the metadata server at 169.254.169.254. On a machine that is no
Google VM the id is `/etc/machine-id`, which is the rehearsal's way. A
machine is taken for a Google VM when `/sys/class/dmi/id/product_name` holds
the word Google.

### 5.2 The move

`move-unfinished.sh` runs as `ExecStartPre` of the listener's unit. It ends
with 1, and so keeps the listener from starting in that round, when a
listener runs already (Barman's lock file
`/var/lib/barman/.validator1-receive-wal.lock`, looked at with `flock`) or
when PostgreSQL does not answer `select 1` through the line. Else it moves
every unfinished file that holds something into the kept folder and leaves
an empty file of the old name. The script has `set -C`, so the shell itself
refuses to write into a file that exists, and the move is `mv -n`.

### 5.3 The check

`check.sh` runs `barman check`, then asks PostgreSQL through the line for
Barman's listeners in the view `pg_stat_replication`, then reads `df`. How
far a listener is behind is PostgreSQL's current WAL position minus the
position the listener says it has written. Right after a start, before the
listener has said anything, the position PostgreSQL has sent takes its
place.

### 5.4 A full copy

Three commands, as the user `barman`: `barman backup validator1`, then
`barman switch-wal --force --archive validator1`, then
`barman check-backup validator1 latest`. The second closes one WAL file
early, because on a quiet database the copy would wait for a file that only
new writes close. `connect-validator.sh` then reads `barman list-backups`
and goes on only when the newest copy is whole.

### 5.5 The practice restore

`barman restore ... --get-wal` copies the full copy into
`/var/lib/barman/practice/data` and writes a `restore_command` with `sudo`
into `postgresql.auto.conf`. The script then writes `postgresql.conf`,
`pg_hba.conf` and `pg_ident.conf` fresh, because the copy holds none, and
puts the practice's own settings at the end of `postgresql.auto.conf`, where
they win over every line before them: no network, the socket folder, port
5432 (it only names the socket file), `hot_standby = off`, and
`restore_command = 'barman get-wal -P validator1 %f > %p'`. `pg_ctl` comes
back before the replay has ended, so the script looks at the data folder
itself: the replay has ended when PostgreSQL runs, the file
`recovery.signal` is gone, and `pg_controldata` says `in production`.

## 6. The checks of the build

Run on the build's Mac on 2026-11-19:

- `sh -n` and `dash -n` on every one of the twelve scripts.
- `cmp` of `listener/verify-garlic-chain.mjs` with
  `anossoftwarescripts/verify-garlic-chain.mjs`: byte for byte.
  Since 2026-11-28 the copy is the chain check as step 4 of validator
  fund payment plan 1
  (`~/Desktop/Z-TestNet/forclaude/validator-fund-payment-plan-1.md`)
  changed it, so that it knows a payment to the Fund, a link of type
  `paymentToFund`; `cmp` of the two was run again on that day: byte for
  byte.
- A `diff` of the files of the plan's appendix A with the files here, and of
  the README's walk with the plan's section 11.
- No dollar sign in any line of the README that the operator pastes.
- One read by a second reader, of the scripts against the plan: every
  script, unit and settings file in full, and the whole plan. It found the
  scripts to follow the plan point by point, and three faults, all mended
  before the first commit: the ping address was a word of `curl`'s command
  line once a minute; a Ctrl-C or a lost session skipped the practice
  restore's clean-up; and a practice PostgreSQL that could not start was
  reported with a wrong reason. Of its doubts, these were taken up too: the
  look for an empty Volume now reads how `blkid` ended; the line for
  `/etc/fstab` is never glued to a last line without an end; a full copy
  left as `STARTED` by a lost session is moved aside like a failed one; an
  older copy that waits for its WAL no longer makes every run close a WAL
  file; and the rehearsal looks for the second row by three pieces of its
  note.

Tried beyond that, on the same Mac. None of it is the real thing: the Mac
has no Debian and no systemd, and no script ran with its real places or as
root.

- Every SQL statement of the scripts, taken out of the script files by a
  small program, against a throwaway PostgreSQL 17.11 on a port of its own.
- Copies of all twelve scripts in which only the places were changed
  (`/var/lib/barman`, `/etc/barman.d`, `/etc/listener` and so on became
  folders of a scratch folder), run with `dash`, with stand-ins for what a
  Mac lacks:
  - with Barman 3.13.3 from the planning test and a throwaway PostgreSQL:
    `connect-validator.sh` (a first run, a second run, a full copy that
    broke off, `--full-copy`, a copy left waiting for its WAL, a hole in the
    WAL and `--start-over`, the server name `rehearsal`),
    `move-unfinished.sh` (under a stand-in for the unit, and by hand),
    `check.sh` (good, not good, the ping through a stand-in for `curl` that
    sends nothing), `status.sh`, and `practice-restore.sh` for the server
    `rehearsal`. The practice restore's copy had five more lines changed,
    because a socket file's path cannot be that long on a Mac: it used
    `127.0.0.1` in place of the socket. Barman's own copy step of a restore
    cannot run on a Mac; `cp` stood in for it;
  - `set-up-worker.sh` (a first run, a second run, wrong flags, a machine
    with another id, `--new-worker`), `line.sh` (every way it ends; `ssh`
    was a stand-in that prints the words it is handed),
    `remove-from-worker.sh` (the slot in use, everything there, nothing
    there) and `add-worker-key.sh`;
  - `set-ping-url.sh` on a stand-in for a terminal: the address is not
    shown, and a wrong one changes nothing;
  - `rehearse.sh`, the whole of it, three times, with a stand-in for
    systemd, a TCP forward that can be stopped in place of the SSH line, and
    a fresh throwaway PostgreSQL in place of Debian's `pg_createcluster`.
    It passed. With a fault put in on purpose at R7 it stopped there and
    left everything standing, and the next run cleaned up first and passed;
  - `set-up-listener.sh` against stand-ins that answer as a fresh Hetzner
    server would, and that format, mount and install nothing: a first run,
    a second run, and four other states of the Volume (none there, mounted
    by Hetzner, something unknown on it, a file system on it already).
- A second round, after the second reader's findings were mended: the
  practice restore stopped by a signal while its PostgreSQL ran (it stopped
  that PostgreSQL and removed its folder); a practice PostgreSQL that could
  not start (the script gave PostgreSQL's own reason); a full copy cut off
  with Barman killed outright (Barman lists it as `STARTED`; it was moved
  aside); `--full-copy` while another full copy was being taken (refused);
  a copy left waiting for its WAL (made whole); the check's ping with the
  address on `curl`'s standard input; the Volume again, with two more
  states (`blkid` cannot tell; an `/etc/fstab` whose last line has no end);
  and the whole rehearsal once more: passed. Under `dash`, a script with
  the three signal lines ran its last lines on Ctrl-C, a lost session and a
  TERM signal; without them it did not.

What these trials cannot show: how Debian's own tools, systemd, sshd, the
SSH line itself and Barman's own `barman restore` behave, and the chain
check against a restored copy of the real database. Stage 3 of the walk is
the first run of the real thing.

## Notes

Every choice the build made where the plan is silent.

### All scripts

- The plan's tree lists no `LICENSE` and no `.gitignore`, so the build
  wrote none and asked. Both were added on the user's word of 2026-11-19,
  before the first commit. `LICENSE` is the Apache 2.0 text: a copy of the
  monitor's file, byte for byte, which is the same file in every other
  repository. `.gitignore` holds one line, `.DS_Store`; the repository has
  no packages of its own and no settings file that could hold a secret, so
  nothing else is in it. There is no `.editorconfig`: the plan's tree lists
  none, and it was not asked for.
- The logs are under `/opt/listener/logs`, on both machines. The plan names
  no place. On the worker this keeps the listener's parts in the three
  places of reading 33, because `/opt/listener` is the clone's place, which
  `remove-from-worker.sh` leaves.
- Every script sets `LC_ALL=C` and its own `PATH`, so what the tools print
  is in English and `useradd`, `sshd` and `ufw` are found.
- A script that must be the clone at `/opt/listener/listenersoftware` says
  so and stops when it is not: the units run the scripts from there.
- Inside the scripts a command runs as another user with `runuser`, not
  with `sudo`, so nothing depends on `sudo` being installed or set up.
- Barman's server names are held to `validator1` and `rehearsal`. Any other
  word is refused.
- A failure line names the point and says why. When a command failed that
  the script did not expect to fail, the last five lines of the log are
  shown first.
- A Ctrl-C or a lost SSH session ends a script like any other failure: its
  last line is still written to the log, and the practice restore still
  cleans up. Without three lines for these signals the shell would end at
  once and skip both.

### `set-up-listener.sh`

- L1b. The system disk is the disk that holds `/`. The Volume is the one
  other disk that holds no partition. It is taken for empty only when
  `blkid -p` finds nothing on it and `lsblk` shows no file system; then
  `mkfs.ext4` with its defaults. "Finds nothing" is `blkid` ending with 2;
  when it ends any other way without naming a file system (it could not
  read the disk, or what it found does not fit together), the script stops
  and formats nothing. A disk that holds ext4 or xfs is mounted as it is. A
  disk that holds anything else stops the script. The line in `/etc/fstab`
  is `UUID=<uuid> /var/lib/barman <type> defaults,nofail 0 2`; when the
  file's last line has no end, one is added first, so the new line is never
  glued to it.
- L1b also stops when `/var/lib/barman` holds files and is not on the
  Volume, or when the package `barman` is installed before the mount.
- L2. `create_main_cluster = false` goes into
  `/etc/postgresql-common/createcluster.d/listener.conf`, or to the end of
  `createcluster.conf` when that folder does not exist. After the install
  the script stops when a cluster `main` exists all the same.
- L2. The script stops when Debian installs another Barman than 3.13:
  what Barman deletes by itself differs between versions, and the plan was
  tried with 3.13.3.
- L2. `/var/lib/barman` is given to the user `barman` when the package did
  not do it. Its mode is left as it is.
- L2b. A `#` goes before every job line of `/etc/cron.d/barman`, which is a
  line that begins with a digit, a `*` or an `@`. When the file is not
  there, the point says so and goes on.
- L3. The script stops when `/root/.ssh/authorized_keys` holds no key, so
  that SSH by key only cannot lock the server. When sshd refuses its
  settings with a new file in place, the file that was there before is put
  back.
- L3. The firewall must show exactly two rules, port 22 on IPv4 and on
  IPv6. Other rules stop the script; it removes none.
- L4. The user `line` is a system user with the home `/nonexistent` and the
  shell `/usr/sbin/nologin`. The key file is made empty only when it is not
  there: a later run never empties it.
- L5. The clone and `npm ci --omit=dev` are done as root. A later run does
  not pull the clone.
- L6. A unit file is installed when it is not there or differs from the
  clone's. A unit that runs is not restarted.
- L7. The host key line is the type and the key of
  `/etc/ssh/ssh_host_ed25519_key.pub`, without the comment.

### `set-up-worker.sh`

- Once the values are in `/etc/listener`, `--listener`, `--host-key` and
  `--pg-port` may be left out. A flag that is given must say what is there.
  To move the line to another address: `remove-from-worker.sh`, then the
  set-up again.
- `--host-key` takes the line with or without a comment. Only an ed25519
  key is taken.
- W1 also looks for PostgreSQL's socket file, for `ssh` and `ssh-keygen`,
  and that this VM's id can be read.
- W2. The user is made with `useradd --system --user-group
  --no-create-home`, and its home with `install -d`, so no skeleton files
  land in it.
- W3. The key's comment is `listener-line`. When `line.key.pub` is missing,
  it is worked out from the private half.
- W5. A PostgreSQL user `listener` that is there and whole is `already`.
  One that is there and not as appendix A.6 makes it stops the script; it
  is not changed. The eight lines run in one transaction.
- W6 waits up to ten seconds for the reload to show.
- W7. A unit file that differs from the clone's is installed anew. The
  line is not restarted.
- `--new-worker` does one thing: it writes this VM's id into `worker-id`.

### `line.sh`

- It ends with 3, and so stays down, also when `worker-id` is missing, or
  when `LISTENER_ADDRESS` is not an address or `PG_PORT` not a number.
  Trying again would not mend a set-up that is not whole.

### `remove-from-worker.sh`

- `--pg-port` names PostgreSQL's port. When left out: the port in
  `line.env`, then 5432.
- When the machine has no PostgreSQL on that port (`pg_lsclusters`), the
  PostgreSQL point says so and the script goes on. When there is one and it
  does not answer, the script stops there: the unit is off, and nothing more
  is taken off until PostgreSQL is up.
- It waits up to 30 seconds for the slot to be free before it drops it.
- `max_slot_wal_keep_size` is set back only when `postgresql.auto.conf`
  holds it.
- It removes the three files of `/etc/listener` and the folder only when
  the folder is empty then. On listener1, in the rehearsal, the folder also
  holds the listener's own files.
- It leaves `/opt/listener`: the clone and the logs.

### `add-worker-key.sh`

- The key file holds one key. A key that was there before is replaced, and
  the script says so. The key is looked at twice: its shape, and
  `ssh-keygen -l`.

### `connect-validator.sh`

- Another server than `validator1` is named with one more word:
  `connect-validator.sh rehearsal`. For it the script fills the name into
  Barman's file and gives it a description of its own.
- C2. A file that is there and differs from the clone's stops the script.
  Barman's settings for a server that is connected are not changed by it.
- C3 waits up to 90 seconds for the listener to stream. One WAL file is
  closed early only when no finished one has arrived yet: Barman's list of
  them, `wals/<server>-xlog.db`, is empty and no full copy is there.
- C4. Before the full copy two lines may fail: `minimum redundancy
  requirements`, as the plan says, and `failed backups` when an earlier try
  broke off. C5 moves what is left of that try aside. Any other line that
  fails stops the script.
- C5. A copy that Barman lists as `WAITING_FOR_WALS` is looked at again
  first (`barman check-backup`), which closes no WAL file. When the newest
  copy still waits then, a run was cut short after the first of the three
  commands: the other two make it whole, and no new one is taken. An older
  copy that still waits is named in the C5 line and left as it is.
- C5. A copy "broke off" when Barman lists it as `FAILED`, and also when it
  lists it as `STARTED` or `EMPTY` while no full copy is being taken
  (Barman's lock for a full copy is free and no `pg_basebackup` runs as
  `barman`). That second kind is what a lost session or a restart of
  listener1 in the middle of a copy leaves; Barman's own check does not
  count it. While a full copy is being taken by another run, the script
  moves nothing and stops.
- C5. What is left of a full copy that broke off goes to
  `kept/failed-copy-<its id>`: its folder as `base`, its note file beside
  it.
- `barman switch-wal --archive` waits Barman's own 30 seconds for the file.
- `--start-over` waits up to 30 seconds for the slot to be free, and drops
  the slot only when it is there.
- `--full-copy` and `--start-over` need a server that is connected, and
  each has a last line of its own.

### `move-unfinished.sh`

- `start-over` as a second word is the move of `--start-over`.
- The script has `umask 077`: the kept folder and the empty file belong to
  `barman` alone, as the listener's own files do.
- A kept name that exists already gets `.2`, `.3` and so on.
- Barman's own check takes the listener's lock for an instant to see whether
  a listener runs. When that falls into the very moment of a start, the
  journal says "a listener of validator1 is running; nothing moved" once,
  and the unit tries again ten seconds later.

### `check.sh`

- It ends with 0 when good and 1 when not good, so the rehearsal can read
  it, and so `systemctl` shows the last result.
- Good needs exactly one listener that is streaming.
- For the server `rehearsal` no ping is sent.
- With no ping address yet the check is still good, and its line says that
  no ping was sent. A ping that cannot be sent in three tries, two seconds
  apart, leaves the result good; the silence then rings the alarm, as it
  should.
- The ping address is handed to `curl` on its standard input
  (`curl -K -`, one line `url = "..."`), never as a word of the command, so
  it is in no list of processes. An address that holds a character
  `set-ping-url.sh` would not take is not used.

### `set-ping-url.sh`

- The terminal's echo is off while the address is pasted, so the address is
  not on the screen and not in a copy of the screen.
- The address may hold letters, digits and `: / . _ ~ -`.
- The script sends no ping itself.
- Its last line names the length of the address and its last four
  characters, and nothing else of it. Why: the account at healthchecks.io
  also holds the masterpod's check, and the four characters let the
  operator see on the page that the address pasted is the one of the check
  `listener1`.

### `status.sh`

- Beside the listener's unit it shows the two timers.
- The last check's result and time come from systemd
  (`ExecMainStatus`, `ExecMainExitTimestamp`), its line from the journal.
- One more word names the server `rehearsal`.

### `rehearse.sh`

- The throwaway PostgreSQL is made with
  `pg_createcluster --locale C.UTF-8 --port 5440 --start 17 rehearsal`.
- Its one table is `rehearsal_rows (id, note)`. The two notes begin with
  `REHEARSAL-ROW-ONE` and `REHEARSAL-ROW-TWO`.
- It also refuses to run when the key file of the user `line` holds a key
  that is not from 127.0.0.1: the worker's key was accepted then, and the
  rehearsal would take it out. And when port 5440 is in use.
- R4 waits 15 seconds, longer than the unit's ten, and looks at three
  things: the unit is `failed`, its script ended with 3, and port 5433 is
  free.
- R6 looks for the second note in the unfinished file and in no finished
  one. It looks for three pieces of the note that only the second row has:
  a WAL file is made of pages, and the border of two pages can cut through
  one piece, never through all three.
- R8 first makes the throwaway PostgreSQL quiet: one `CHECKPOINT`, then its
  WAL position must stand still for 20 seconds. Without that, PostgreSQL's
  own checkpoint could write a record into the unfinished file in the
  middle of the proof, and the proof would fail for no fault. With the line
  down it waits 25 seconds, two rounds of the listener's unit.
- R8 leaves Barman's list file out of the comparison by its name: any file
  whose name ends in `xlog.db`.
- R9 is the same clean-up a second run begins with. After it the script
  looks that nothing of the rehearsal is left.
- The rehearsal runs what the plan's points R1 to R10 list. It does not run
  `connect-validator.sh --full-copy` or `--start-over`, `status.sh`,
  `set-ping-url.sh`, or the ping of `check.sh` (no ping is sent for the
  server `rehearsal`). Their first run on Debian is the day they are
  needed; here they ran only as copies on the build's Mac (section 6). This
  gap is written here and in the work note
  `forclaude/notes/project-validator-wal-copies.md`; adding points to the
  rehearsal would be a change of the plan.

### `practice-restore.sh`

- P2 waits up to 20 seconds for the health answer. The answer must be
  validator 1's, and must show a chain position and a record hash.
- P3. Barman's own restore begins by filing the finished WAL files that
  wait in the streaming folder into its store, which is what the minute
  timer does too (read in Barman 3.13.3's `backup.py`). So "it only reads
  Barman's store" is true but for that; nothing is deleted or changed.
- P5 has no time limit: it waits for as long as the practice PostgreSQL
  runs and replays. Every five minutes it says so. The replay has ended
  when PostgreSQL runs, has taken its file `recovery.signal` away, and the
  data folder says `in production`. The folder's word alone is not enough:
  a full copy says `in production` from the start, as the worker did when
  it was copied. A practice PostgreSQL that does not run stops the script
  with its own last lines.
- P6. The last line of the chain check that is not empty must begin with
  `EVERYTHING IS PERFECT`, and the check must end with 0.
- P7. The copy's chain must end at or after the position of P2.
- P9 is in the script's exit, so it runs whatever happened before. A folder
  that an earlier practice left is removed at the start.
- The validator's clone is not pulled by a practice restore.

### The units

- `listener-archive@.service` and `listener-check.service` have a
  `Description` and no `Group` line: appendix A.5 lists `User=barman` for
  them, and systemd then takes the user's own group.
- The two timers are `WantedBy=timers.target`.

### Two places where the plan and Barman's or its own words differ

- The plan calls Barman's list file `xlog.db`. Barman 3.13.3 names it
  `<server>-xlog.db`, in the folder `wals`. Found in the trial on the Mac.
- The plan's section 7 still has the sentence "The unit needs the limit's
  unit". The limit went with decision 40, and appendix A.1 has no such
  line; the unit is appendix A.1 as it stands. And section 6 says the unit
  is started in stage 7; the walk starts it in stage 6, and the README
  follows the walk.

### Not known from the Mac

- The locale of validator 1's PostgreSQL. A practice restore needs
  listener1 to have that locale. `C.UTF-8` is always there on Debian. If it
  is another one that listener1 lacks, P5 stops and shows PostgreSQL's own
  words about it.
- What Debian's `barman` package does with a `/var/lib/barman` that exists
  already and belongs to root. The script gives the folder to `barman`
  after the install.
- Whether a worker restored from the Google vault has a new `id`. Reading
  16 rests on it, and the plan says so.

### One thing to know about Debian 13's sshd

- It refuses an address for a while after logins from it were refused
  (`PerSourcePenalties`, on by default; read in the manual page of OpenSSH
  10.3: five seconds for each refused login, enforced once 15 seconds have
  added up, up to ten minutes). The line tries again every ten seconds. So
  a line that was refused a few times, for instance because its unit was
  started before its key was accepted on listener1, or because the key is
  accepted from another address than the one listener1 sees, may stay
  refused for up to ten minutes after the cause is mended. The walk accepts
  the key in stage 5 and starts the line in stage 6, so it does not meet
  this.
