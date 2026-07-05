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
● working ~/code/app    one line per split: state + path
◐ waiting ~/code/api
──────────────────────
 [2]  notes             a renamed session
○ done ~/code/dotfiles
N nvim    ~/code/conf    plain panes get an icon too:
⇄ remote  zeod:~/api     nvim / SSH / local shell
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
  clicking a session's row does the same.
- **Name & cull sessions.** `prefix t` renames the current session; `prefix K`
  opens a kill table (`prefix K 3` kills #3, `prefix K K` kills the current,
  `prefix K a` kills all *other* sessions).
- **A status panel at the bottom.** A bottom-anchored stack of boxes for
  at-a-glance health signals from elsewhere — **Uptime Robot** monitors, **open
  PRs** to review, **Slack alarm** channels. These are pulled by a once-a-minute
  cron job (`providers/collect.sh`) into cache files the sidebar just reads, so
  the redraw loop never touches the network (see *Status panel* below). Turn
  each box on in `~/.config/tmuxopticon/pull.conf`.
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
| `prefix o`       | Toggle the sidebar on/off (global)                |
| `prefix 1`…`9`   | Jump to the Nth session in the list               |
| click a row      | Jump to that session                              |
| `prefix t`       | Rename the current session                        |
| `prefix K` `N`   | Kill the Nth session (with confirm)               |
| `prefix K` `K`   | Kill the current session (with confirm)           |
| `prefix K` `a`   | Kill ALL sessions except the current (with confirm) |

## Options

Set these in your `~/.tmux.conf` (defaults shown):

```tmux
set -g @tmuxopticon-width           34    # sidebar width in columns
set -g @tmuxopticon-interval        1     # redraw interval in seconds
set -g @tmuxopticon-provider-stale  180   # secs before a status cache reads "stale"

# friendly aliases for ugly hostnames in SSH-pane paths (';'-separated from=to)
set -g @tmuxopticon-host-aliases    'ip-10-13-99-46=zeod;10.0.0.5=db'
# set this BEFORE the run-shell line to bind the keys yourself instead of the defaults
set -g @tmuxopticon-default-keys    'off'
```

The status-panel providers are **not** configured via tmux options — they're
enabled in `~/.config/tmuxopticon/pull.conf` and fed by a cron job (see *Status
panel* below).

The sidebar opens at `@tmuxopticon-width` columns. You can resize the pane
interactively at any time; the new width is local to that pane and isn't
propagated to other sessions.

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
real failure can't be missed. A box reads `⚠ stale` if its cache stops refreshing
— the tell that cron has stopped.

**Enable providers** in `~/.config/tmuxopticon/pull.conf` (copy
`examples/pull.conf.example`):

```sh
SLACK_PULL_ENABLED=true
UPTIME_ROBOT_PULL_ENABLED=true
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

- `providers/*/` — **bundled** with the repo (the three above).
- `~/.config/tmuxopticon/providers.d/*/` — **your own**, out of the repo, so a
  `git pull` on the plugin never clobbers them.

To add one: copy `examples/provider-template/` to
`~/.config/tmuxopticon/providers.d/<name>/`, edit the manifest + `pull.sh`, then
set its `flag` to `true` in `~/.config/tmuxopticon/pull.conf`. The collector runs
it into `tmp/<id>.cache` and the sidebar draws a box for it, in the manifest's
`order`. The render loop stays network-free. See `lib/providers.sh` for the full
manifest reference.

## Requirements

- tmux 3.x
- bash, perl, git
- curl, jq (for the network status providers; not needed otherwise)
- cron (to run the status-panel collector; the sidebar itself works without it)

## Status

Personal tooling, shared in case it's useful. It works well day-to-day but
isn't packaged or extensively tested across environments yet. Issues and
suggestions welcome.
