# tmuxopticon

A toggleable left **sidebar for tmux** that watches every session at once —
showing each session's name, the working directory of every split, and the
**live status of Claude Code** in each pane: `● working`, `◐ waiting`, or
`○ done`.

Run a fleet of Claude Code sessions across many tmux sessions and you lose
track of which ones are grinding, which are blocked on a prompt, and which
have finished. tmuxopticon gives you one always-current panel — a little
[panopticon](https://en.wikipedia.org/wiki/Panopticon) for your terminal — so
you can glance left and jump straight to whichever session needs you.

```
▶[1]  refactor-auth     ← active session (highlighted)
 ✎ Next step: write tests   your note for this session (prefix m)
● working ~/code/app    one line per split: state + path
◐ waiting ~/code/api
──────────────────────
 [2]  notes             a renamed session
 ✎ BLOCKED: needs local setup   BLOCK… notes go bold red
○ done ~/code/dotfiles
N nvim    ~/code/conf    plain panes get an icon too:
⇄ remote  api1:~/api    nvim / SSH / local shell
$ shell   ~/scratch
──────────────────────

──────────────────────   ← status panel, pinned to the bottom
 Uptime Robot
 ● 1 down                 monitors currently down (Uptime Robot)
   api.example.com
```

## What it does

- **One panel, every session.** A single **full-height left column**, listing
  all tmux sessions in stable order. Because it spans the whole window height
  (`split-window -f`) it sits *beside* any existing splits rather than carving
  one of them in half. It **follows the focused window/session** while toggled
  on — tmux hooks re-home it whenever you switch windows, open a new one, or
  jump between sessions, so it's always on the left wherever you land.
- **Live Claude Code status per split.** Each non-sidebar pane is probed and
  labelled `working` / `waiting` / `done` (see *How status is detected*). Panes
  not running Claude get a type icon instead: `N nvim`, `⇄ remote` (an SSH
  pane), or `$ shell` (a plain local terminal).
- **Jump anywhere.** `prefix 1`…`prefix 9` switches to the Nth listed session;
  clicking a session's row does the same. `prefix n` / `prefix p` cycles to the
  next / previous session in the list, wrapping at the ends.
- **Order the list by hand.** `prefix ↑` / `prefix ↓` moves the *current*
  session one row up or down, so related sessions can sit next to each other
  instead of in the order you happened to open them (both `dotfiles` sessions
  together, both `brapi` ones together). The jump numbers follow the new order —
  there's nothing separate to renumber. Repeatable: one `prefix`, then `↑↑↑`.
  No wrap at the ends — but the key never *silently* does nothing: at the top or
  bottom it says so in the status line (`'Brapi' is already at the top (#1 of
  2)`), and a successful move made with the sidebar closed reports where the
  session landed. Sessions you've never moved keep sorting by creation time
  *below* the ones you have, so a new session appears at the bottom rather than
  landing in the middle of your grouping. Stored per session in
  `@tmuxopticon-order` (survives renames, dies with the session); run
  `tmuxopticon.sh move reset` to drop the manual order and go back to pure
  creation order.
- **Name & cull sessions.** `prefix t` renames the current session; `prefix K`
  opens a kill table (`prefix K 3` kills #3, `prefix K K` kills the current
  session and hops to the next one — wrapping — instead of detaching you,
  `prefix K a` kills all *other* sessions).
- **A note per session.** `prefix m` attaches a note to the current session —
  "Next step: write tests", "waiting on review" — shown with a `✎` right under
  the session's name. It's your own re-orientation line: glance at the card
  instead of re-reading a Claude transcript to remember where a session is at.
  The prompt is prefilled with the current note (edit, don't retype); submit
  empty to clear. Notes are **never cut off**: long ones word-wrap across as
  many sidebar rows as needed (an overlong URL/path is hard-split), and typing
  a literal `\n` forces a line break — the prompt itself is single-line, so
  that's how you author multi-line notes. A note starting with `BLOCK` renders
  bold red. Stored as a per-session tmux option (`@tmuxopticon-note`) — no
  files, survives renames, dies with the session.
- **A status panel at the bottom.** A bottom-anchored stack of boxes for
  at-a-glance health signals — **Uptime Robot** monitors, **open PRs** to
  review, **Slack alarm** channels, and **this machine's own** CPU / memory /
  GPU / temperature. These are pulled by a once-a-minute cron job
  (`providers/collect.sh`) into cache files the sidebar just reads, so the
  redraw loop never touches the network (see *Status panel* below). Turn each
  box on in `~/.config/tmuxopticon/pull.conf`.
- **No daemon.** A bash script does the work and a `.tmux` file wires up the
  bindings; the redraw loop lives inside the sidebar pane itself. The status
  providers run separately, off a cron clock.

A note on zoom: `prefix z` on a work pane hides every other pane, so the drawer
disappears while you're zoomed and reappears when you unzoom — handy when you
want a single pane fullscreen.

## Install

Clone this folder anywhere, then either:

**Manually** — add to your `~/.tmux.conf`:

```tmux
run-shell /path/to/tmuxopticon/tmuxopticon.tmux
```

**With [tpm](https://github.com/tmux-plugins/tpm):**

```tmux
set -g @plugin 'youruser/tmuxopticon'
```

Reload tmux (`prefix : source-file ~/.tmux.conf`) and hit `prefix o`.

## Key bindings

| Binding          | Action                                            |
| ---------------- | ------------------------------------------------- |
| `prefix o`       | Toggle the sidebar on/off (global; on = opened in every session) |
| `prefix O`       | Fix the sidebar everywhere: open in every session + reset widths |
| `prefix 1`…`9`   | Jump to the Nth session in the list               |
| `prefix n` / `p` | Next / previous session in the list (wraps)       |
| click a row      | Jump to that session                              |
| `prefix ↑` / `↓` | Move the current session up / down one row (repeatable, no wrap) |
| `prefix t`       | Rename the current session                        |
| `prefix m`       | Set/edit the session's note (empty clears; `\n` = line break) |
| `prefix K` `N`   | Kill the Nth session (with confirm)               |
| `prefix K` `K`   | Kill the current session (with confirm)           |
| `prefix K` `a`   | Kill ALL sessions except the current (with confirm) |

These take over some tmux defaults — `prefix n`/`p` (next/previous-window),
`prefix m` (mark-pane), and `prefix ↑`/`↓` (select-pane up/down). Windows stay
reachable with `prefix w` / `prefix l`; for panes, bind your own (`bind k
select-pane -U`, `bind j select-pane -D`, …) or set
`@tmuxopticon-default-keys 'off'` and wire every subcommand yourself.

## Options

Set these in your `~/.tmux.conf` (defaults shown):

```tmux
set -g @tmuxopticon-width           34    # sidebar width in columns
set -g @tmuxopticon-interval        1     # redraw interval in seconds
set -g @tmuxopticon-provider-stale  180   # secs before a status cache reads "stale"

# friendly aliases for ugly hostnames in SSH-pane paths (';'-separated from=to)
set -g @tmuxopticon-host-aliases    'ip-10-13-99-46=api1;10.0.0.5=db'
# set this BEFORE the run-shell line to bind the keys yourself instead of the defaults
set -g @tmuxopticon-default-keys    'off'
```

The status-panel providers are **not** configured via tmux options — they're
enabled in `~/.config/tmuxopticon/pull.conf` and fed by a cron job (see *Status
panel* below).

The sidebar opens at `@tmuxopticon-width` columns. You can resize the pane
interactively at any time; the new width is local to that pane and isn't
propagated to other sessions.

Client resizes — docking, unplugging a monitor, projecting in a meeting —
make tmux rescale panes proportionally, which can leave sidebars at odd
widths. `prefix O` (or `tmuxopticon.sh reset` from a shell) fixes the sidebar
everywhere in one go: it opens the sidebar in every session's active window
that lacks one (without moving your focus — so the "first visit opens a fresh
pane" flash is pre-paid; zoomed windows are left alone), then snaps every
sidebar pane back to `@tmuxopticon-width`. Toggling the sidebar on with
`prefix o` runs the same fix automatically, so a fresh open is already
flash-free across sessions.

The render loop also listens for pane resizes (`SIGWINCH`) and repaints
immediately, so landing in a freshly re-sized session shows a correct frame
right away instead of waiting out the redraw interval.

## How status is detected

Each pane is classified by what Claude Code is showing:

- **working** — a braille spinner (`U+2800`–`U+28FF`) is animating in the pane
  *title*, or the footer reads `esc to interrupt`. The title check survives
  narrow splits where the footer text gets truncated.
- **waiting** — the pane is asking a question (`do you want…`, `would you
  like…`, or any selection/question prompt showing `esc to cancel` in its
  footer).
- **done** — Claude is idle at its prompt (`? for shortcuts`, `shift+tab to
  cycle`, `auto mode on`).

Whether a pane is Claude at all is decided first by its foreground process
(`pane_current_command` is `claude`) and, failing that, by the glyph Claude stamps
on the pane **title** (`✳` when idle, a braille spinner while working). Both are
robust — they keep working even if you run a **custom Claude `statusLine`** that
replaces the default `? for shortcuts` hint, and the title glyph also catches a
Claude running **over SSH**, where the local command is just `ssh`. The
working/waiting/done split above is then refined from the UI text; a Claude pane
that matches none of it is shown as `done` (idle). So a future UI redesign may need
the *state* patterns in `tmuxopticon.sh` updated, but Claude panes won't be missed
entirely — a remote Claude shows `working`/`waiting`/`done` like a local one, and
only a remote pane that *isn't* Claude (a plain shell, titled `user@host:path`)
shows `⇄ remote`.

A pane **not** running Claude is labelled by what it *is*, which is robust (no
UI sniffing): **nvim** when the foreground command is `nvim`/`vim`, **remote**
when the pane's path carries a `host:` prefix (an SSH pane — `@cwd` is set to
`host:~/path`), and **shell** for everything else (a plain local terminal).

## Status panel

The bottom of the sidebar hosts a stack of **status boxes** for signals that
don't belong to any one session — a bottom-anchored panel that stays put no
matter how long the session list gets.

**How it works.** The redraw loop never touches the network. Instead, a small
collector — `providers/collect.sh` — runs **once a minute from cron**, reads
which providers you've enabled, runs each one's puller, and drops a tiny cache
file in the plugin's `tmp/` folder. The sidebar only ever *reads* those caches.
Every box uses the same shape: a state (`ok` → green `○`, `info` → neutral `•`,
`warn` → red `●`), a one-line summary, and optional detail lines. An `err` state
is loud on purpose — the whole box turns into a **full-width red banner** so a
real failure can't be missed. A box reads `Last sync: H:MM (N min ago)` if its
cache stops refreshing — the tell that cron has stopped.

**Enable providers** in `~/.config/tmuxopticon/pull.conf` (copy
`examples/pull.conf.example`):

```sh
SLACK_PULL_ENABLED=true
UPTIME_ROBOT_PULL_ENABLED=true
MACHINE_PULL_ENABLED=true
PRS_PULL_ENABLED=true
PRS_PULL_CMD=/path/to/your/prs-pull.sh   # see "Open PRs" below
```

**Start the collector** — it's **off by default**. The start script installs the
once-a-minute cron line for you (you only do this once — crontab persists across
logins) and flips it on:

```sh
providers/collector-start.sh    # on  — installs cron + enable flag
providers/collector-stop.sh     # off — removes both (sidebar shows "⊘ Cron-checker disabled")
providers/collector-status.sh   # inspect the flag, cron line, and each cache's age + contents
providers/collector-run.sh      # run the pull once now, on demand (skip waiting for the next cron tick)
```

`collector-run.sh` does exactly what cron does each minute, but synchronously and
with feedback — handy right after you change something and want the sidebar to
catch up immediately. It runs with `--force`, so it refreshes even while the
collector is stopped.

With no `pull.conf` the collector is a quiet no-op, and a provider whose cache
doesn't exist yet simply doesn't draw — so nothing shows until you opt in.

### Uptime Robot

Shows the monitors currently **down** (statuses "down" + "seems down"), or a
green `○ all systems up` when healthy:

```
──────────────────
 Uptime Robot
 ● 2 down
   api.example.com
   web.foo.com
```

Create a **read-only** API key in Uptime Robot → *Integrations* → *API* and drop
it where the puller looks for it (kept out of the repo):

```sh
mkdir -p ~/.config/tmuxopticon
echo 'u123456-yourreadonlykey' > ~/.config/tmuxopticon/uptimerobot.key
```

With `UPTIME_ROBOT_PULL_ENABLED=true` the collector polls the API each minute
(`providers/uptimerobot/pull.sh`). With the flag on but no key, the box reads
`⚠ no API key`; a bad key shows the API's own error text. A read-only key is all
it needs — it never writes.

### Machine

The one provider that watches the box you're *typing on* rather than something
out on the network: **why does this machine feel slow right now?**

```
──────────────────────────────
 Machine
 • cpu 80% · mem 37% · 59°C
   cpu 80%  load 9.2/8 · 1966f/s
   mem 11/30G · swap 11G
   gpu 17% · 800MHz
   tmp cpu 59° · ssd 49°
   psi c18 i5 m0 · dsk 16%
   top s1-agent 36% · ghostty 20%
```

Green `○` is comfortable, neutral `•` is working hard but not stalling (a normal
state mid-build), and red `●` means degraded — with the headline **naming the
culprit**: `slow: io stall 22%`, `slow: memory 94%`, `slow: cpu 93°C`.

Set `MACHINE_PULL_ENABLED=true` and that's it — no key, no network, no root.
Every line is skipped when its numbers aren't available, so hardware without a
GPU counter or a temperature sensor just gets a shorter box.

The line worth knowing about is `psi` — the kernel's **Pressure Stall
Information**, the share of the last minute actually *lost* waiting on `c`pu,
disk `i`/o, or `m`emory. `cpu 100%` with `psi c0` is a machine doing its job;
`psi i40` is a machine you are waiting on. Its companion is `f/s`, the fork
rate, which appears above 100/s and is the usual explanation for a box pegged in
system time while no single process looks busy.

**`providers/machine/README.md` is the full legend** — every abbreviation, where
it's read from, and the exact thresholds. Linux gets everything; macOS gets cpu,
load, memory, disk and top processes (no PSI, no fork rate, no GPU, and
temperature only with `osx-cpu-temp` installed).

### Open PRs

Runs a command of your choice each minute and shows its one-line summary —
built for "how many PRs are waiting on me":

```
──────────────────
 Open PRs
 • Open PRs: 4 across 4 repos
```

It uses the neutral `info` state — a PR count is informational, so the box never
turns red no matter how many are open. The Open PRs provider (`providers/prs/`)
ships a manifest but **no puller** on purpose: point `PRS_PULL_CMD` at your own
script that takes a cache-file path as `$1` and writes the provider format
(`epoch` / `ok|info|warn|err` / summary). The puller lives **outside** this repo
when it's work-specific — this dotfiles setup keeps it in a separate work-tooling
repo so tmuxopticon stays generic. See `providers/prs/README.md`.

### Alarms (Slack)

Surfaces messages from Slack "alarm" channels you're a member of:

```
──────────────────
 Alarms
 ● 2 alarms
   15:51 #prod-alerts CPU 98%
   15:52 #db disk 91%
```

`○ no alarms` when clear. The shipped puller is
`providers/slack/slack-alarm-watch.sh` (a plain-member Slack poller using a user
token); enable it with `SLACK_PULL_ENABLED=true` and configure it under
`~/.config/tmuxopticon/slack.env` — see `docs/slack-alarm-watch.md` for the
one-time Slack-app setup.

### Adding a provider

Providers are **drop-in directories**, discovered by a registry
(`lib/providers.sh`) — the core engine names no provider, so adding one touches
**no core file**. A provider directory holds two things:

```
my-provider/
  provider.conf      # the manifest (id, title, flag, pull, order, …)
  pull.sh            # the puller, invoked as `pull.sh <cachefile>`
```

The puller writes the shared cache format (`epoch` / `ok|info|warn|err` /
summary / detail lines) to the path it's handed — exactly like the bundled ones.
Discovery scans **two roots**:

- `providers/*/` — **bundled** with the repo (the four above).
- `~/.config/tmuxopticon/providers.d/*/` — **your own**, out of the repo, so a
  `git pull` on the plugin never clobbers them.

To add one: copy `examples/provider-template/` to
`~/.config/tmuxopticon/providers.d/<name>/`, edit the manifest + `pull.sh`, then
set its `flag` to `true` in `~/.config/tmuxopticon/pull.conf`. The collector runs
it into `tmp/<id>.cache` and the sidebar draws a box for it, in the manifest's
`order`. The render loop stays network-free. See `lib/providers.sh` for the full
manifest reference.

### Keeping private logic out of this repo

Providers are the part of this codebase that gets personal fastest. A watch rule
grows a colleague's name; a health check grows an internal hostname. This repo is
public, so it draws a line: **the bundled providers hold generic engines and
worked examples, and anything that identifies a person, an employer or a
workspace lives outside them.**

Two places to put the private part, in order of preference:

1. **Move the values into config, keep the code here.** The bundled Slack
   provider is the model — the poller is generic, and every channel ID, label
   and false-alarm filter lives in `~/.config/tmuxopticon/slack.env`. Nothing
   identifying ever enters the tree. Prefer this whenever only the *data* is
   private.
2. **Write a private provider.** When the *behaviour* itself is personal —
   "alarm me when a specific person messages" — the whole provider belongs in
   `~/.config/tmuxopticon/providers.d/<name>/`. The registry treats it exactly
   like a bundled one. Because that path is outside the repo, it can be a
   symlink into a private repo of your own, which gets it version-controlled and
   synced across machines without ever being pushable here:

   ```sh
   ln -s ~/code/my-private-dotfiles/tmuxopticon-providers/boss \
         ~/.config/tmuxopticon/providers.d/boss
   ```

And a backstop for the evening you edit a bundled provider without thinking
about it — a pre-commit hook that refuses to commit staged credentials, Slack
workspace IDs, email addresses, or any word on a denylist you keep *outside*
this repo:

```sh
hooks/install.sh        # sets core.hooksPath; needed once per clone
```

The denylist is read from the first of `$TMUXOPTICON_PRIVATE_WORDS`,
`~/.config/tmuxopticon/private-words`, or
`~/.config/tmuxopticon/providers.d/private-words` — one extended regex per line,
case-insensitive. With no such file the structural credential checks still run.
Blocked commits name the file and line; `git commit --no-verify` overrides
deliberately.

## Requirements

- tmux 3.x
- bash 3.2+ (macOS's stock `/bin/bash` is enough), perl, git
- curl, jq (for the network status providers; not needed otherwise)
- cron (to run the status-panel collector; the sidebar itself works without it)

## Status

Personal tooling, shared in case it's useful. It works well day-to-day but
isn't packaged or extensively tested across environments yet. Issues and
suggestions welcome.
