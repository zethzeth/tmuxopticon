# tmuxopticon

A toggleable left tmux sidebar that watches every session at once: split
counts + live Claude Code status (working / waiting / done). User-facing
docs are in `README.md`; this file is the dev cheat-sheet.

Self-contained and meant to be shareable (tpm-installable, "clone anywhere"),
so it must stay path-independent and free of dotfiles-specific assumptions —
don't reach into sibling repo files. One soft exception: it reads the per-pane
`@cwd` var that `ubuntu/tmux/update-pane-cwd.sh` sets, and falls back to
`pane_current_path` when absent (so macOS still works).

**All shell code must stay bash-3.2 compatible** — macOS ships `/bin/bash`
3.2.57 and `env bash` resolves to it on a stock Mac, so bash-4isms are fatal
there. Banned: `${var^^}`/`${var,,}` (case conversion — "bad substitution"
kills the whole script; this once crash-looped the sidebar the moment a note
was set, see `bugs/2026-07-06-tmuxopticon-note-crash-bash32.md`), `mapfile`/
`readarray`, `declare -A`, `|&`, `&>>`. For case-insensitive matching use
character-class globs (`[Bb][Ll][Oo][Cc][Kk]*`).

## Files

- `tmuxopticon.sh` — all the logic. Subcommands: `toggle`, `ensure`, `reset`
  (snap every sidebar pane back to `@tmuxopticon-width` after a client resize
  skewed it — bound to `prefix O`), `render`,
  `jump N`, `next`/`prev` (cycle sessions in sidebar order, wrapping), `click Y`,
  `kill N`, `killcur` (kill the current session after hopping to the next one,
  wrapping, so the client isn't detached), `help` (`-h`/`--help`). No daemon; the redraw
  loop (`render`) runs *inside* the sidebar pane itself. `help` prints the key
  table, reading the live prefix from `tmux show-option -gv prefix`. The status
  panel is read-only here — `render` never fetches; it just reads cache files
  the collector wrote (see below).
- `tmuxopticon.tmux` — wires up key bindings + hooks. Sourced from `.tmux.conf`
  via `run-shell`. Locates its own dir, so it's path-independent. The bindings
  (not the hooks) are gated behind `@tmuxopticon-default-keys` (set `off` to bind
  your own).
- `lib/providers.sh` — **the provider registry.** Sourced by *both* `collect.sh`
  and `tmuxopticon.sh` so neither hardcodes which providers exist. A provider is
  a directory with a `provider.conf` manifest; `provider_rows()` discovers them
  from two roots — `providers/*/` (bundled) and
  `~/.config/tmuxopticon/providers.d/*/` (the user's, out of repo) — and emits one
  sorted, `\037`-separated row per provider (id, title, flag, pull, pull_cmd_var,
  timeout, throttle_min, order, dir). **`\037` (US), not tab**: tab is
  IFS-whitespace, so `read` would coalesce delimiters around an empty middle
  field (e.g. a BYO provider's blank `pull`) and shift columns. Adding a provider
  touches **no core file** — it's pure data discovery.
- `providers/` — the status-panel machinery, all running *outside* the render
  loop (from cron):
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
    code here anymore** — it's a single registry loop.
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
  - `uptimerobot/` — `provider.conf` + `pull.sh` (fetches Uptime Robot, writes
    `tmp/uptime_robot.cache`).
  - `slack/` — `provider.conf` + `slack-alarm-watch.sh` (the poller, writes
    `tmp/slack.cache`) + a thin `pull.sh` adapter (the registry calls
    `pull.sh <cache>`; the poller takes its cache via `$SLACK_ALARM_CACHE` + a
    `poll` subcommand, so the adapter bridges them) + the `*.example` templates.
  - `prs/` — `provider.conf` + a `README.md`, but **no puller**: the Open PRs
    fetch is work-specific, so the manifest sets `pull_cmd_var=PRS_PULL_CMD` and
    the user points that at their own script. The canonical "bring your own
    puller" example.
  The collector scripts (`collect.sh`, `collector-*.sh`) live directly in
  `providers/`; each *provider* is a subdirectory with a `provider.conf`. Only
  subdirs with a manifest are discovered, so the collector scripts aren't mistaken
  for providers.
- `examples/` — `pull.conf.example` (the committed template for the user's
  `pull.conf`) and `provider-template/` (a copy-paste manifest + skeleton
  `pull.sh` for a new provider).
- `tmp/` — gitignored. The collector drops `<id>.cache` files here; `render`
  reads them. The agreed path is `dirname(SELF)/tmp`, computed the same way in
  both `collect.sh` and `tmuxopticon.sh`.

## Architecture notes

- **Each render frame runs in a subshell** (`render` loops `( render_frame )`),
  so a hard shell error mid-frame (bad substitution, `set -u` unbound var) kills
  only that frame — the loop paints a red `⚠ render failed` notice and retries —
  instead of exiting the script and closing the sidebar pane. Keep new
  frame-time work inside `render_frame`, and don't "simplify" the subshell away.
- **State lives in tmux options**, not files: `@tmuxopticon-active` (0/1) is the
  global on/off; `-width` / `-interval` are config. Options are read live each
  frame, so config changes apply without a reload.
- **Per-session notes are tmux options too**: `prefix m` prompts (prefilled via
  `command-prompt -I '#{@tmuxopticon-note}'`) and stores the text as a
  *session-scoped* user option `@tmuxopticon-note`; `render` draws it as a `✎`
  block under the session header (`session_note` + `wrap_note`), bold red when
  it starts with `BLOCK`. Notes are never truncated: `wrap_note` word-wraps to
  the sidebar width (hard-splitting overlong words) and expands a literal `\n`
  into a line break; continuation rows indent under the `✎`. Deliberately no
  file store: the note survives renames (options ride
  the session, not its name) and dies with the session — matching the lifetime
  of a "Next step: …" jotting.
- **The drawer follows focus** via `after-select-window` / `after-new-window` /
  `client-session-changed` hooks, each calling `ensure` (a cheap no-op when
  inactive or already present). Don't add a daemon to do this.
- **Sidebar pane is identified by its title** (`pane_title == "tmuxopticon"`),
  set via `select-pane -T`. That title is how every `awk` filter excludes it
  from session/pane listings — keep that invariant if you touch pane handling.
- **Full-height left column** comes from `split-window -fhb` (`-f` = span the
  whole window height, not just the active pane). This is load-bearing: it's why
  the sidebar sits *beside* splits instead of halving one.
- **Click → session** is resolved through a row→index map written to
  `/tmp/tmuxopticon.rows.$UID` each frame; the mouse binding passes `mouse_y`.
- **Each split row is led by its `pane_index`** (`session_pane_rows` emits it as
  the first tab field; `render` prints it right-aligned in `nlen=3` cols). This is
  tmux's own per-window number — the one `prefix q` flashes and the dotfiles
  pane-border-format shows (`#{pane_index}:` prefix) — so a sidebar row maps to an
  on-screen pane. The focused window has the sidebar at index 1, so *its* work
  panes start at 2; that's correct, since the number always mirrors the live
  `pane_index` (and thus the border / `prefix q`) for that window.

## Status panel (bottom-anchored boxes)

A second region sits at the **bottom** of the sidebar, independent of the session
list: a stack of boxes for cross-cutting health signals. Three providers ship:
**Uptime Robot**, **Open PRs**, **Alarms** (Slack).

**The big invariant: render NEVER touches the network.** This was a deliberate
re-engineering (it also fixed a bug where each long-running `render` process
fetched on its own clock, so the box only appeared in whichever sidebar fetched
first). All fetching now happens in `providers/collect.sh`, run from **cron once
a minute**; `render` only reads the caches it leaves in `tmp/`. If you add a
provider, keep this shape — a puller invoked by the collector, never a fetch in
`render`.

- **Providers are a registry, not hardcoded** (`lib/providers.sh`). Neither
  `collect.sh` (which pulls) nor `render` (which draws) names a provider; both
  loop over `provider_rows`. So adding a provider = dropping a `provider.conf` +
  `pull.sh` directory (bundled under `providers/`, or user-supplied under
  `~/.config/tmuxopticon/providers.d/`), never editing the engine. See the
  `lib/providers.sh` entry under **Files** for the manifest keys and the `\037`
  separator gotcha.
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
  manifests set Uptime Robot=10, Open PRs=20, Alarms=30, so the default stack is
  Uptime Robot, Open PRs, Alarms (alarms at the very bottom = most visible) — same
  as before, but now data-driven, and a user provider can slot anywhere by its
  `order`. `bh` counts the total box rows across all enabled providers; if any box
  draws, the session list is capped to `avail = h - bh`.
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

### Providers

- **`uptimerobot/pull.sh <cache>`** — `curl` the API (`statuses=8-9` = down +
  seems-down), write the unified format: 0 down → `ok`/"all systems up";
  N down → `warn`/"N down" + monitor names; no key → `err`/"no API key" (+ path
  hint line); bad key/no response → `err` + message. Key from
  `~/.config/tmuxopticon/uptimerobot.key` (env `UPTIME_ROBOT_KEYFILE` override).
  Needs `curl` + `jq`. (`provider.conf`: id `uptime_robot`, order 10.)
- **`slack/slack-alarm-watch.sh poll`** — the Slack poller (see its own header).
  Emits `warn` when alarms are active (so the box lights `●`) and a friendly
  summary ("N alarms" / "no alarms"). The registry invokes it through the sibling
  **`slack/pull.sh`** adapter, which sets `SLACK_ALARM_CACHE=$1` and runs `poll`
  (the poller predates the `pull.sh <cache>` contract). `alarms_box` is gone — it
  renders through `provider_box` like everything else, and the script stays
  Slack-agnostic about *rendering*. (`provider.conf`: id `slack`, order 30.)
- **Open PRs** — has **no puller in this repo on purpose**: the `prs` command is
  work-specific, so the puller lives in the work-tooling repo and `pull.conf`
  points `PRS_PULL_CMD` at it. The puller takes a cache path as `$1` and writes
  the unified format. It writes the **neutral `info`** state (e.g. `info`/"Open
  PRs: 4 across 4 repos", compacted to "Open PRs: N" when too wide) — a PR count
  is an FYI, not a health alarm, so the box never goes red over it. tmuxopticon
  stays generic — it just renders `tmp/prs.cache`. (`providers/prs/provider.conf`:
  id `prs`, order 20, `pull_cmd_var=PRS_PULL_CMD`, `throttle_min=7` — the generic
  throttle that replaced the old hand-coded PR back-off. See `providers/prs/README.md`.)

## Status detection is heuristic and fragile

Whether a pane *is* Claude is decided robustly first, two ways: `pane_current_command
== claude`, **or** the pane *title* carries Claude's own glyph — `✳` (U+2733) when
idle/ready, a braille spinner (U+2800–U+28FF) while working. The title tell is what
catches a Claude running **over SSH**, where the local command is `ssh` (see the
caveat below); a plain remote shell's title is `user@host:path`, with no such glyph.
Both tells are immune to UI changes and to a custom `statusLine` (which replaces the
`? for shortcuts` hint, so an idle Claude pane would otherwise scrape as a plain
shell). The finer `working` / `waiting` / `done` split is still matched
against Claude's **current UI text** (`esc to interrupt`, `do you want`/`would you
like` / `esc to cancel`, `? for shortcuts` / `shift+tab to cycle` / `auto mode on`)
plus a
braille-spinner (U+2800–U+28FF) check on the pane *title* (survives narrow splits
where the footer truncates). A Claude pane that matches none of those — idle under
a custom statusLine — falls back to `done` precisely *because* the command is
`claude`. A Claude Code UI redesign can still break the working/waiting/done split
— update the patterns in `session_status` / `session_pane_rows` when that happens —
but presence detection no longer depends on it.

Caveat: a Claude session running **over SSH** reports `pane_current_command == ssh`
locally, so the command tell fails for those. Presence then rests on the title glyph
(`✳`/spinner, above): an *idle* remote Claude is titled `✳ …`, so it resolves to
`○ done` like a local one; a *working* one carries the braille spinner → `● working`;
and a *waiting* one is caught by the text scrape of the prompt footers (`esc to
cancel`, `do you want`) → `◐ waiting`. Only a remote pane *not* running Claude (a
plain shell, title `user@host:path`) stays `⇄ remote`. The fragile spot is a remote
Claude whose title glyph doesn't propagate (an old Claude build, or a terminal that
strips title escapes) *and* that's sitting idle under a custom statusLine — with no
glyph and no footer cue it falls back to `⇄ remote`. Working/waiting still surface.

Panes that *aren't* running Claude are classified by what they are, not by UI
text (so this part is sturdy): `nvim` when `pane_current_command` is
`nvim`/`vim`, `remote` when the resolved path has a `host:` prefix (an SSH pane,
courtesy of `@cwd`), else `local`. `render` maps these to the `N nvim` /
`⇄ remote` / `$ shell` icons, sharing the same status column as the Claude
states so paths stay aligned. Claude states take precedence over the type icon.

## Requirements

tmux 3.x, bash, perl, git (plus curl + jq for the network providers, and cron to
run `collect.sh`). Test the sidebar by sourcing the `.tmux` file and `prefix o`.
Test a provider by running its puller directly (`providers/uptimerobot/pull.sh
/tmp/x.cache`) or the whole collector (`providers/collect.sh --force`) and
inspecting `tmp/*.cache`. Inspect the registry itself with
`bash -c '. lib/providers.sh; provider_rows'` (point `TMUXOPTICON_CONFIG_DIR` at a
temp dir to test `providers.d/` discovery without touching `~/.config`). The
render path runs under **bash**, not your login shell — when testing
`provider_box`/`pull_enabled`/`provider_rows` in isolation, invoke them with
`bash`, not zsh (zsh mis-parses the bash substring/printf syntax and the `\037`
field split).
