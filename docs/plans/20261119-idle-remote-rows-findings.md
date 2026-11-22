# Idle p4linux rows on p4studio: findings

Measured 2026-11-19 on p4studio against the live agterm 0.39.1 (pid 52288, up 37 h).
Code citations are at fork `main` (`4cd6654d`, and `25cddd98` locally), not the main checkout, which holds an
unfinished upstream merge.

## Contents

- [Answer in one screen](#answer-in-one-screen)
- [1. What one idle row costs](#1-what-one-idle-row-costs)
- [2. What exists today](#2-what-exists-today)
- [3. Design options](#3-design-options)
- [4. The reapers](#4-the-reapers)
- [Commands](#commands)

## Answer in one screen

- An idle remote row costs the Mac **memory and threads, not CPU**. CPU is close to zero.
- The terminal surface (in agterm) and the process chain (login, sh, ssh) cost about the same.
- The brief undercounted streams. Each attached row has **one pane stream per pane plus one
  presentation stream** (`ssh -T p4linux agtermctl zmx present <id>`). That is 157 + 94 = 251 ssh
  processes today.
- The ssh mux is broken. It answers `-O check`, but a new session fails with
  `mux_client_request_session: read from master failed: Broken pipe`. So 60 of 157 pane clients
  and 84 of 94 presentation clients have their own TCP connection. Three mux masters share one
  control path.
- 152 of 157 pane ssh clients started within two minutes (03:03–03:04 on 2026-11-19). That is a
  reconnect storm, which is the likely cause of the mux race.
- Remote rows are not most of the machine's 31 GB. The floor for all remote rows is about
  1.8 GB on the Mac. Eight WebKit processes hold 8.4 GB, and the in-process Rebased JVM holds
  about 1.1 GB.

## 1. What one idle row costs

Live counts: 14 windows (13 open), 173 rows, 121 remote rows (all `p4linux`).
94 rows are `attached`, 27 are `endedOnHost`. Remote rows have 198 surfaces: 163 in attached rows
and 35 in ended rows. About 20 surfaces are actually on screen (one selected row per open window).

| part | per unit | live total | how measured |
|---|---|---|---|
| ssh pane client, via mux | 2.09 MB footprint | 97 clients | `footprint` |
| ssh pane client, own TCP | 2.93 MB footprint | 60 clients | `footprint` + `lsof -i TCP` |
| `/bin/sh` wrapper per pane | 1.27 MB footprint | 199 MB | `footprint` |
| `/usr/bin/login` per pane | not measured: root-owned, `footprint` cannot read it. RSS 6.2 MB is an upper bound, mostly shared pages | 157 | `ps -o rss` |
| presentation ssh per row | 2.87 MB footprint | 270 MB (94) | `footprint` |
| agterm surface, hidden, empty | **4.6 MB**, 5 threads, about 2 MB of it graphics | | slope in an isolated instance |
| agterm surface, hidden, 20 000 lines of scrollback | **31 MB** | | same |
| CPU, all 157 pane clients | 155 s total over 12 h, about 0.36 % of one core | | `ps -o time` |
| CPU, 41 idle hidden surfaces | 0.02 s in 60 s | | isolated instance |

- **Per idle pane:** surface 4.6 MB or more, plus ssh, sh and login 3.4 MB or more, plus about 5 agterm
  threads. **Per row**, add 2.9 MB for the presentation stream.
- **Live scrollback is small.** Ghostty's scrollback pages show up as `app-specific tag 1`. In the
  isolated instance they took 515 MB for 20 full surfaces. In live agterm they take only 66 MB for all 292
  surfaces, so the live remote rows sit near the 4.6 MB floor, not the 31 MB ceiling.
- **What the rest of live agterm's 5.8 GB is:**
  - graphics: 2.6 GB. Not verified which part: the about 20 surfaces on screen in 13 windows, or hidden surfaces holding more than a fresh one (see "Why the saving is 1.1 GB" below). The 2–2.5 GB upside depends on which holds;
  - `MALLOC_SMALL`: 1.67 GB;
  - untagged `VM_ALLOCATE`: 1.2 GB. The isolated instance, which has no JVM, has 3.8 MB of it, so this is
    most likely the Rebased JVM;
  - stacks: 165 MB across 1687 threads.
- **Server side (p4linux):** the 94 `agtermctl zmx present` processes take 239 MB PSS in total (2.5 MB
  each). Their RSS reads 2.4 GB, but that counts shared pages many times.
- **What sleeping all idle remote panes would save:** about 140 panes are attached and off screen.
  Floor: 140 × (4.6 + 3.4) MB ≈ 1.1 GB, plus about 420 processes and about 700 threads. Closing the
  35 dead `endedOnHost` surfaces adds about 0.16 GB.

## 2. What exists today

Nothing keeps a row in the sidebar while freeing its pane.

- **Every session is mounted.** `detailPane` in `agterm/Views/WindowContentView+Detail.swift` mounts a
  deck of every session's terminal and hides the unselected ones with opacity 0. `SpawnPacer` only
  orders the spawns, and every pane is spawned in the end.
- **Hidden panes stop rendering, nothing else.** `updateRendererVisibility` in
  `agterm/Ghostty/GhosttySurfaceView+Visibility.swift` calls `ghostty_surface_set_occlusion` and
  frees the swap chain. The pty is still read and parsed, and nothing pauses the IO.
- **A surface is freed only on close or replacement.** `teardown` and `destroySurface` run from the
  close path (`WindowAccessor.swift`) and from `replacePane` in `agtermApp.swift`. `replacePane` is
  what reconnect and reattach use: a fresh surface in an existing pane. A wake can reuse it.
- **The tree's `realized` field** is `surface != nil` (`ControlProjection.swift`, filled in
  `AppStore.swift`). It reads false only before the first spawn. There is no stored state behind it.
- **`session park`** only sets a mark (`Session.parked`). It frees nothing.
- **`session detach`** works only in a remote catalog window, and it removes the row from this Mac.
  There is no `zmx detach`.
- **Restore at launch is eager.** `restoreRemoteRows` in `agterm/Control/ControlServer+RemoteRows.swift`
  (the fork's `RemoteRowBook`) calls `insertRemoteRow`, which builds the attach line and calls
  `startRemotePresentation`. The upstream merge adds a second restore path,
  `AppStore+AttachedRestore.swift`. It is also eager.
- **The attach line** is `RemoteSession.attachPaneCommand` and `attachCommand` in
  `agtermCore/Sources/agtermCore/RemoteSession.swift`. The `sh` stays alive because the line handles
  ssh's exit status 255 after ssh returns.
- **Row states** are `RemoteRowState { attached, disconnected, endedOnHost }`
  (`RemoteRowState.swift`). They are set by `RemoteRowSupervisor` (`paneExited`, `streamFailed`).
- **The presentation stream** (`PresentationFrames.swift`) carries `status`, `name`, `context`,
  `info`, `notify`, `sound`, `layout` and `hud`. So the sidebar row can stay live with no pane stream.
- **Idle facts per session:** only `lastSelectedAt` (persisted) and `statusChangedAt`. There is no last
  output time and no last input time.

## 3. Design options

### Sleep idle remote panes (recommended)

The row stays in the sidebar with its presentation stream, so status, name and notifications stay
live. A pane that has been off screen for N minutes loses its surface, and with it login, sh and ssh.
Showing the row wakes it: a fresh surface and a new `zmx attach`, which replays the current screen.

- **Saves** about 1.1 GB or more, about 420 processes and about 700 threads today. It also stops the
  reconnect storm at launch and after a network drop, because sleeping panes do not reconnect.
- **Costs Sasha:**
  - a wake delay when he opens a sleeping row (ssh through the mux plus the first frame; to be measured);
  - Mac-side scrollback beyond what zmx replays;
  - bells and other in-band terminal signals from a sleeping pane. Agent status and `notify` still arrive,
    because they use the presentation stream.
- **Code:**
  - a per-pane sleep state on `Session` in agtermCore;
  - `detailPane` must not mount a sleeping pane, or the teardown/`replacePane` path frees it;
  - `RemoteRowSupervisor.paneExited` and `RemoteReconnectBook` must ignore a deliberate sleep;
  - wake goes through `agtermApp.reattachPane` / `replacePane`;
  - restore at launch puts idle rows to sleep: `restoreRemoteRows` and the upstream restore path;
  - the tree gets a read-back field;
  - `session sleep|wake` in the control API and `agtermctl`, plus tests and the skill docs.
- Reads never wake a row. A `tree` read, the reaper's reads and `session text` stay passive.
- **Size: L** (agtermCore model, deck mounting, supervisor, both restore paths, control API, remote
  parity with mirrors on another Mac).

### Lazy attach at launch only

The first step of the option above, with no idle timer. Restored remote panes stay unspawned until
they are first shown.

- **Saves:** everything above at launch and after a reconnect storm, but rows refill as Sasha visits
  them. Over a 37 h app lifetime, most visited rows come back.
- **Costs Sasha:** the same wake delay, only once per row.
- **Code:** `restoreRemoteRows` and the upstream restore, the deck mount gate, `SpawnPacer`, and a tree field.
- **Size: M.**

### Close idle Mac rows to the picker

No agterm code. A script in agterm-agents closes Mac rows that have not been selected for N days. The
p4linux session keeps running. Sasha brings a row back from "Attach to session"
(`agtermctl zmx attach p4linux <id>`).

- **Saves:** everything, the presentation stream too.
- **Costs Sasha:**
  - the row leaves the sidebar, with its status and notifications;
  - it comes back at a new position unless the script stores a placement, as `macPlacement` in
    `20261103-reaped-rows-in-place.md` does;
  - ⚠️ attaching a session that already has a row makes a second row (`attachRemoteSession`
    does not check), so a script that reattaches must check first.
- **Size: M** (agterm-agents script, placement store, tests). It still needs a check that a Mac row
  close never closes the server session.

### Fix the ssh mux (small, separate)

Every stream should go over one TCP connection. The saving is small on the Mac: about 0.85 MB per
own-TCP client, about 120 MB in total. It also removes 144 ssh handshakes and connections.
**Size: S.**

**Cause (measured):**

- A mux master runs with the launchd soft limit of 256 open files: `launchctl limit maxfiles` gives
  `256 unlimited`.
- Master 20159 had 253 fds open, and master 19219 had 189. One mux session costs the master about 4
  fds, so one master is full at about 60 sessions.
- Once it is full, a new client fails with `read from master failed: Broken pipe` and falls back to its
  own TCP. A client that then tries to become master gets `ControlSocket ... already exists, disabling
  multiplexing`. The failure comes and goes: five later `ssh p4linux true` runs used the master.
- ufw on p4linux allows only 6 new ssh connections per 30 s from one source (`22/tcp LIMIT`, see the
  comment in `~/.ssh/config`). So during a reconnect storm, the direct fallbacks are refused too.

### Mosh (tested, not chosen)

agterm already supports it (`RemoteTransport.mosh`, `agtermctl zmx attach --transport mosh`). One
throwaway session was attached with mosh, measured, and closed with `moshcost.sh`.

- `mosh-client` takes 6.7 MB per pane on the Mac, against 2.1–2.9 MB for ssh.
- `mosh-server` takes 7.5 MB PSS per pane on p4linux.
- The row's presentation stream stayed on ssh: the count went from 94 to 95.
- `mosh-client` inherited agterm's localhost TCP sockets, among them 63343, the Rebased JVM port.
  Some agterm or JVM sockets have no close-on-exec flag. ssh does not show this because it closes extra
  file descriptors when it starts.
- Closing the Mac row did not end the p4linux session.
- **Decision (Sasha):** fix the ssh mux and keep ssh. No mosh.

### Why the saving is 1.1 GB when agterm uses 5.8 GB

The 1.1 GB uses the clean-instance cost of a hidden surface (4.6 MB). Live agterm splits like this:

- **Graphics, 2.6 GB.** A fresh hidden surface holds about 2.2 MB of graphics. Live agterm holds about
  5.7 MB per surface (1673 MB over 292 surfaces, with the same 20 regions per surface). Not verified:
  hidden panes may rebuild their swap chain after a window resize or display change. See
  `startHiddenJanitor`: that path rebuilds the chain, and only upstream can stop it.
- **Rebased JVM, about 1.2 GB** of untagged `VM_ALLOCATE`.
- **`MALLOC_SMALL`, 1.67 GB**, owner unknown. `vmmap` reports a peak footprint of 18.5 GB, and malloc
  keeps freed pages after a spike.
- **Scrollback, 66 MB** in all. **Stacks, 165 MB.**

So with the JVM taken out, a live surface averages about 16 MB. Sleeping may save 2–2.5 GB, not 1.1 GB.
The `footprint` before and after the first sleep run will tell. Follow-ups:

- graphics per hidden surface after a window resize, tested in an isolated instance;
- the 18.5 GB peak;
- the sockets that pane processes inherit.

### Rejected

- **One mux stream for all rows** (a single connection carrying every pane). It saves only the
  process chain, not the surface, and it is a new transport protocol. The ssh mux already gives
  one TCP connection once it works.
- **Less output for hidden rows.** Rendering already stops for hidden panes, and the measured CPU is
  near zero. There is nothing to win.

## 4. The reapers

- **The Mac reaper** (`reap-macos`, spec `docs/plans/20261118-reap-macos-spec.md` in agterm-agents)
  maps Mac-local Claude processes to rows. A remote row has no Mac Claude, so it gets `skip-no-claude`.
  Sleeping does not change that.
- **The p4linux reaper** decides idle from the last real transcript row on p4linux, not from Mac
  attach state. So a sleeping Mac row is not reaped sooner.
- **The reaper's Mac sweep** (`20261103-reaped-rows-in-place.md`) reads Mac rows' `remoteSession`,
  `remoteState`, `mode` and `state`. It closes a Mac row by `remoteSession`, and it sweeps
  `endedOnHost`. A sleeping row must keep all four fields, and must still turn `endedOnHost`. That works
  only if the presentation stream stays up. This is one more reason the recommended option keeps it.
- **The Mac sweep would also free the 35 dead `endedOnHost` surfaces** measured above, once it ships.

## Commands

Scripts are in `docs/plans/idle-remote-rows-scripts/`. All reads of the live app used the default
socket read-only (`tree`, `window list`, `session text`). The only live mutation was the mosh probe
row, attached and closed on Sasha's request.

```sh
# mux and ssh
ssh -O check p4linux                                  # Master running (pid=20159)
ssh -G p4linux | grep -Ei '^(controlmaster|controlpath|controlpersist|serveralive)'
ps -axww -o pid=,command= | grep -c '[s]sh -tt .*p4linux'     # 157 pane streams
ps -axww -o command= | grep -c '[z]mx present'                 # 94 presentation streams
ps -axww -o lstart=,command= | grep '[s]sh -tt .*p4linux' | awk '{print $4}' | cut -c1-5 | sort | uniq -c
                                                      # 17 at 03:03, 135 at 03:04
launchctl limit maxfiles                              # maxfiles 256 unlimited
for m in 18100 19219 20159; do lsof -p $m | tail -n +2 | wc -l; done   # 17, 189, 253
ssh -o BatchMode=yes p4linux true    # at times: read from master failed: Broken pipe
mux-repro.sh 256 <dir>; mux-repro.sh 8192 <dir>      # 82/120 ok at 252 fds; 120/120 at 8192
ssh p4linux 'sudo -n sshd -T | grep -iE "^maxsessions|^maxstartups"'   # MaxSessions 512

# per-process cost
rowcost.sh                    # footprint sums of ssh, sh, login per pane chain; own-TCP count
cpu.sh 52288                  # cumulative CPU of pane ssh clients, mux masters, agterm
for p in $(pgrep -f 'ssh -T .*zmx present'); do footprint $p; lsof -a -p $p -i TCP; done
ssh p4linux 'for p in $(pgrep -f "zmx present"); do awk "/^Pss:/{print \$2}" /proc/$p/smaps_rollup; done'
                              # 97 procs, 239 MB PSS

# agterm process
footprint 52288; vmmap --summary 52288; ps -M -p 52288 | wc -l
top -l 2 -s 15 -o cpu -stats pid,command,cpu,idlew,power,mem,cmprs
top -l 1 -o mem -n 12 -stats pid,command,mem,cmprs
agtermctl window list --json
agtermctl tree --json --window <id>      # per open window: rows, remoteState, surfaces, visible

# isolated probe (per-surface slope)
cp -R /Applications/agterm.app <scratch>/probe/agterm.app
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier com.umputun.agterm.probe' <scratch>/probe/agterm.app/Contents/Info.plist
codesign --force --deep -s - <scratch>/probe/agterm.app
mkdir -p /tmp/agp/windows
env -u AGTERM_... -u GHOSTTY_... -u CLAUDE... -u ZMX_... -u TERM_PROGRAM... \
    open -n --env AGTERM_STATE_DIR=/tmp/agp <scratch>/probe/agterm.app
slope.sh <probe pid>          # 1 → 21 empty → 41 with 20 000 lines; footprint in MB
footprint <probe pid> | sed -n '6,14p'; vmmap --summary <probe pid>
kill -TERM <probe pid>

# mosh probe
ssh p4linux '~/.local/bin/agtermctl zmx new --name mosh-probe --json'
agtermctl zmx attach p4linux <id> --transport mosh --mosh-server /usr/bin/mosh-server
moshcost.sh                   # mosh-client footprint and sockets, presentation count, mosh-server PSS
agtermctl session close --target <mac row>
ssh p4linux '~/.local/bin/agtermctl tree --json | grep -c <id>'   # 1: the origin session survives
ssh p4linux '~/.local/bin/agtermctl session close --target <id>'
```
