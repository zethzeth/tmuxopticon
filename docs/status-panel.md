# Status panel internals (collector, renderer, providers)

Dev reference for the bottom-anchored boxes. User-facing setup is
`docs/collectors.md`; the sidebar itself is `docs/internals.md`.

A second region sits at the **bottom** of the sidebar, independent of the session
list: a stack of boxes for cross-cutting health signals. Four providers ship:
**Uptime Robot**, **Machine**, **Open PRs**, **Alarms** (Slack).

**The big invariant: render NEVER touches the network.** This was a deliberate
re-engineering (it also fixed a bug where each long-running `render` process
fetched on its own clock, so the box only appeared in whichever sidebar fetched
first). All fetching happens in `providers/collect.sh`, run from **cron once
a minute**; `render` only reads the caches it leaves in `tmp/`. If you add a
provider, keep this shape — a puller invoked by the collector, never a fetch in
`render`.

## The collector scripts

- `collect.sh` — the dispatcher cron runs once a minute. Reads
  `~/.config/tmuxopticon/pull.conf`, then **walks the registry** (`provider_rows`)
  and for each provider whose `flag` is enabled runs its puller into
  `tmp/<id>.cache` under a `timeout`, honouring `throttle_min` (minutes between
  pulls — the generic version of the old PR special-case; the stamp records
  every *attempt*). The puller is the manifest's `pull` script, or — when that's
  blank — the external command named by `pull_cmd_var` (e.g. `PRS_PULL_CMD`).
  Bails immediately unless the master flag
  `~/.config/tmuxopticon/collector.enabled` exists (the on/off switch below) —
  so a leftover cron line can't keep pulling after a stop. **No per-provider
  code here** — it's a single registry loop.
- `collector-start.sh` / `collector-stop.sh` — the on/off switch (collector is
  **off by default**). start installs the once-a-minute cron line (idempotent,
  tagged with the `# tmuxopticon-collector` marker so it never touches other
  lines) and `touch`es the `collector.enabled` flag; stop removes both. crontab
  persists across logins, so this is a one-time thing, not a per-login step.
- `collector-status.sh` — read-only health dump: is the flag set, is the cron
  line installed, and for each `tmp/*.cache` its mtime + first lines
  (epoch/state/summary). The quick "is it actually refreshing?" check.
- `collector-run.sh` — run `collect.sh` once on demand (synchronous, with
  feedback), for refreshing the caches now instead of waiting for the next cron
  tick. Invokes `collect.sh --force`, so it pulls even when the collector is
  stopped — a manual run is explicit intent and bypasses the `collector.enabled`
  gate *and* every `throttle_min` (the lock + per-puller timeouts still apply).

## Panel machinery

- **Providers are a registry, not hardcoded** (`lib/providers.sh`). Neither
  `collect.sh` (which pulls) nor `render` (which draws) names a provider; both
  loop over `provider_rows`. So adding a provider = dropping a `provider.conf` +
  `pull.sh` directory (bundled under `providers/`, or user-supplied under
  `~/.config/tmuxopticon/providers.d/`), never editing the engine. See the
  `lib/providers.sh` entry in `docs/internals.md` for the manifest keys and the
  `\037` separator gotcha.
- **The collector** (`collect.sh`) sources `~/.config/tmuxopticon/pull.conf`
  (trusted user file, like `slack.env`), then walks `provider_rows` and runs each
  enabled puller into `tmp/<id>.cache` under a single-flight lock (`mkdir`'d dir
  in `tmp/`, stolen if >5 min old) with a per-puller `timeout` and optional
  `throttle_min`. It exports a sane `PATH` because cron's is minimal. The render
  loop, by contrast, **greps** `pull.conf` (`pull_enabled`) rather than sourcing
  it — a long-running loop must not let a config file overwrite its variables
  (the registry walk itself only globs the filesystem, so it's safe to call each
  frame).
- **Unified cache format** (every provider, written atomically `tmp`+`mv`):
  `line1 epoch` (staleness, avoids `stat`) / `line2 state` (`ok|warn|err`) /
  `line3 summary` (headline shown next to the icon) / `line4+ detail lines`
  (dimmed, indented, bare — the renderer adds the indent, so pullers must NOT
  prepend spaces).
- **One generic renderer**: `provider_box <title> <cachefile> <tw>` replaced the
  old per-provider `uptimerobot_box`/`alarms_box`. It maps state→icon
  (`ok`→green `○`, `info`→neutral `•`, `warn`→red `●`), prints the summary, then
  up to `max` detail lines, and prefixes `Last sync: H:MM (N min ago)` when `epoch` is older than
  `@tmuxopticon-provider-stale` (default 180s). `info` is the neutral state for a
  count/FYI that isn't a health verdict (Open PRs uses it, so a PR count never
  lights the box red). A box that has no cache file yet draws **nothing**
  (`[ -r "$cache" ] || return 0`) — so an enabled-but-unpulled provider is silent.
  **`err` is the loud exception**: instead of one `⚠` line it paints a full-width
  red banner — a solid red bar, then reverse-video (red-background) `⚠ TITLE —
  ERROR` / summary / detail lines, then a closing red bar (colours `C_ALERT` /
  `C_ALERTBAR`). The whole box block goes red so a real failure is impossible to
  miss. `render` reserves rows for it like any other box (it's just taller).
- **render gates the whole panel on the collector flag first.** If
  `~/.config/tmuxopticon/collector.enabled` (`COLLECTOR_FLAG`) is absent — the
  default, off state — render draws a single dim `⊘ Cron-checker disabled` box
  (divider + notice, `bh=2`) *instead of* any provider boxes, since nothing is
  refreshing them and stale data would mislead. Only when the flag exists does it
  fall through to the per-provider gating below.
- **render gates each box on `pull_enabled <FLAG>`** and the cache's existence,
  looping over `provider_rows` in registry **`order`** (low=top). The bundled
  manifests set Uptime Robot=10, Machine=15, Open PRs=20, Alarms=30, so the default
  stack is Uptime Robot, Machine, Open PRs, Alarms (alarms at the very bottom =
  most visible) — data-driven, and a user provider can slot anywhere by its
  `order`. `bh` counts the total box rows across all enabled providers; if any box
  draws, the session list is capped to `avail = h - bh`.
- **A box's detail-line cap is per provider** (`max_lines` in the manifest,
  default 6, **`0` = no cap at all**), passed to `provider_box` as its 4th
  argument. Use 0 for a provider whose output is a bounded *table* — truncating
  one hides its bottom rows, which is where the Machine box keeps the
  per-application diagnosis, and a "+N more" you cannot expand is worse than
  the data. Picking a number big enough for today's worst case (this started at
  14) just makes every future row a truncation bug waiting to happen. It sits early in the
  `provider_rows` row (right after `flag`) because the render loop reads only the
  first few columns and lets `pf_rest` swallow the tail — anything the *renderer*
  needs must come before the collector-only fields. `collect.sh` reads the same
  row and must stay in step with the column order.
- **An empty detail line is a deliberate spacer row**, printed as a blank line
  rather than skipped. A provider drawing a small table needs to group its rows
  (the Machine box separates machine-wide readings from per-application ones this
  way). It still counts toward `max_lines` and `bh`, so the bottom-anchor math
  stays correct.
- **Bottom anchoring is real cursor math**, not just "print last". render measures
  `pane_height`, reserves `bh` rows for the boxes, **caps the session list to
  `avail = h - bh`** (the `prow` counter — this also stops a long list from
  scrolling the pane and breaking absolute positioning), paints the list from the
  top + `\033[J`, then jumps the cursor to row `h-bh+1` and paints the boxes. The
  last box line carries no trailing newline, so painting it never scrolls the pane.
  When any box draws, `render` appends **two empty lines** to `boxlines` (and bumps
  `bh` by 2) so the panel floats two rows above the tmux status bar instead of
  butting against it — the two blank rows *are* the bottom-most box rows.
- **Secrets stay out of the repo** under `~/.config/tmuxopticon/`: the Uptime
  Robot key (`uptimerobot.key`), Slack token (`slack.env`), and `pull.conf`
  itself. The repo copies are `.example` templates + a gitignore rule.

## Providers

### Directory layout of the bundled four

- `uptimerobot/` — `provider.conf` + `pull.sh` (fetches Uptime Robot, writes
  `tmp/uptime_robot.cache`).
- `slack/` — `provider.conf` + `slack-alarm-watch.sh` (the poller, writes
  `tmp/slack.cache`) + a thin `pull.sh` adapter (the registry calls
  `pull.sh <cache>`; the poller takes its cache via `$SLACK_ALARM_CACHE` + a
  `poll` subcommand, so the adapter bridges them) + the `*.example` templates.
- `machine/` — `provider.conf` + `pull.sh` + a `README.md` that is the user's
  **legend** for the box's abbreviations. The only provider with no network and
  no secret: it reads `/proc`, `/sys` and process tables for local CPU / memory
  / GPU / thermal health. Plus `pull-remote.sh <cache> <host>`, which draws the
  same table for *another* box.
- `prs/` — `provider.conf` + a `README.md`, but **no puller** (see below).

### Uptime Robot

**`uptimerobot/pull.sh <cache>`** — `curl` the API (`statuses=8-9` = down +
seems-down), write the unified format: 0 down → `ok`/"all systems up";
N down → `warn`/"N down" + monitor names; no key → `err`/"no API key" (+ path
hint line); bad key/no response → `err` + message. Key from
`~/.config/tmuxopticon/uptimerobot.key` (env `UPTIME_ROBOT_KEYFILE` override).
Needs `curl` + `jq`. (`provider.conf`: id `uptime_robot`, order 10.)

### Alarms (Slack)

**`slack/slack-alarm-watch.sh poll`** — the Slack poller (see its own header).
Emits `warn` when alarms are active (so the box lights `●`) and a friendly
summary ("N alarms" / "no alarms"). The registry invokes it through the sibling
**`slack/pull.sh`** adapter, which sets `SLACK_ALARM_CACHE=$1` and runs `poll`
(the poller predates the `pull.sh <cache>` contract). `alarms_box` is gone — it
renders through `provider_box` like everything else, and the script stays
Slack-agnostic about *rendering*. (`provider.conf`: id `slack`, order 30.)

### Machine

**`machine/pull.sh <cache>`** — local box health, the only provider that never
leaves the machine. It's a **two-column table**, not prose: a 7-char label then
the level (`row()` owns that contract in one place). Anything with a real
ceiling gets an 8-wide bar so cpu/mem/gpu/temp are comparable without reading a
digit; rates (`net`, `spawn`) print raw values because there's no honest 100%
to bar against. `temp` is scaled 30→100°C — a 0-based bar never leaves its
first third and stops being a gauge. Then a **spacer row** and three
application rows. Three states map onto the existing vocabulary: `ok`
comfortable, `info` busy-but-not-stalling (a dev box mid-build lives here),
`warn` degraded — and a `warn` summary **names the culprit** (`slow: io stall
22%`) because "slow" alone is not a diagnosis. Every row is omitted when its
numbers are unavailable, so a box with no GPU counter just draws shorter.

Design decisions that look like omissions but aren't: load average, drive
temperature and GPU clock are **deliberately not shown** (`stall cpu` says what
load says without a division; the other two are never the answer), and swap and
disk stay hidden until they cross a threshold. Every row costs sidebar height
the session list would otherwise get — that's the budget being spent.

**`stall io` is deliberately NOT a warn trigger.** PSI `full` means "every
non-idle task is stalled", so it inflates as a machine gets *quieter* — after
a real swap-thrashing fix here (swap-out 4339 -> 0 pages/s, major faults 480
-> 84/s, machine visibly snappier) it *rose* from 31% to 48%. `some` was 56%
at the same moment. The verdict watches the mechanism instead: swap fault-in
rate and genuine device saturation. Do not "restore" the io threshold.

**Six traps are baked into `pull.sh`. Do not "simplify" them away:**

- **`LC_ALL=C` at the top.** `printf`/`awk` parse floats through `strtod`,
  which reads a decimal *comma* under a Danish/German locale — without this
  every float silently truncates to its integer part.
- **`cat /proc/[0-9]*/stat | awk`, never `awk <glob>`.** Processes exit
  between the glob expanding and the file opening, and **mawk aborts the whole
  run on the first ENOENT** (gawk merely warns). That truncated the snapshot to
  low-numbered PIDs, which made every long-running process look brand-new in
  the second sample and report its lifetime CPU as one second's worth —
  `gnome-shell 939641%`.
- **Rates need two samples**, so the puller sleeps `TMUXOPTICON_MACHINE_SAMPLE`
  (1s) between them. The per-process figure is a `/proc/<pid>/stat` utime+stime
  delta, deliberately *not* `ps`'s `%cpu`, which is a lifetime average and on a
  long-uptime box blames whatever was busy last week. Processes born *and*
  killed inside the window escape any PID diff — that's what the `spawn`
  rate (delta of `processes` in `/proc/stat`) is there to catch. That counter
  increments on every `clone()`, so it counts threads too; the docs say "task
  spawns", not "processes", on purpose.
- **`/proc/net/dev` must be split on the COLON**, not parsed by whitespace
  field number. The file right-pads the interface name to 6 chars, so `lo:`
  gets a space before its first counter and `wlp0s20f3:` does not — field
  numbering shifts *per interface*, and the offset-based version silently
  reported packet counts as byte counts. Everything after the colon is the 16
  counters (#1 rx bytes, #9 tx bytes). Virtual interfaces are excluded because
  container/bridge traffic also crosses the real NIC and would be counted twice.
- **The three application rows are picked for coverage, not ranking**: biggest
  CPU consumer, biggest memory consumer, then whichever is next. A straight
  "top 3 by share of the box" was tried and reads badly — RAM is measured
  against 30 GB while one core is an eighth of the machine, so on a CPU-pegged
  box all three rows came back `mem` and the thing burning the CPU never
  appeared. Rows aggregate by **program name**, not PID, so a browser's fifty
  processes are one row.

(`provider.conf`: id `machine`, order 15, timeout 20, **`max_lines=0`** — uncapped;
the default of 6 is built for a headline-plus-notes provider and this one is a
table whose last rows carry half the meaning.) Legend + thresholds live in
`providers/machine/README.md`.

### Machine — remote

**`machine/pull-remote.sh <cache> <host>`** — the same box for a machine you're
not sitting at. It works only because `pull.sh` is self-contained, so it can be
streamed to the host (`ssh host bash -s -- <mktemp>`) and run there; the remote
installs nothing and keeps nothing. **That only works while `pull.sh` stays
self-contained (no sourcing, no sibling files, no config) — keep it that way.**

Output is passed through **verbatim** from line 4 down — no re-thresholding, no
reformatting, so one legend covers a local and a remote box. Two things it does
change, both deliberate: line 1 (the epoch) is rewritten from the **local**
clock, because that's the staleness marker the renderer reads and a skewed
remote clock would make the box permanently stale or permanently fresh; and an
unreachable host writes **`warn`**, not `err` — `err` is the full-width red
banner, and a laptop off the VPN is a daily state, not an incident. It must
still write *something*, or a dead host sits there green on its last good
reading. Hosts are one provider dir each (`providers.d/machine-<host>/`), since
title/order/flag are manifest fields; the per-host `pull.sh` is a two-line
`exec`.

### Open PRs

**`prs/`** — `provider.conf` + a `README.md`, but **no puller in this repo on
purpose**: the `prs` command is work-specific, so the puller lives in the
work-tooling repo and `pull.conf` points `PRS_PULL_CMD` at it. The canonical
"bring your own puller" example. The puller takes a cache path as `$1` and
writes the unified format. It writes the **neutral `info`** state (e.g.
`info`/"Open PRs: 4 across 4 repos", compacted to "Open PRs: N" when too wide) —
a PR count is an FYI, not a health alarm, so the box never goes red over it.
tmuxopticon stays generic — it just renders `tmp/prs.cache`.
(`providers/prs/provider.conf`: id `prs`, order 20,
`pull_cmd_var=PRS_PULL_CMD`, `throttle_min=7` — the generic throttle that
replaced the old hand-coded PR back-off. See `providers/prs/README.md`.)
