# tmuxopticon

A toggleable left tmux sidebar that watches every session at once: split
counts + live Claude Code status (working / waiting / done). User-facing docs
are in `README.md`; this file is the dev cheat-sheet — **the rules that will
bite you.** The reference material lives in `docs/`:

| Touching… | Read first |
| --- | --- |
| `tmuxopticon.sh`, `lib/`, the render loop, session ordering | `docs/internals.md` |
| `providers/`, the collector, the cache format, a box | `docs/status-panel.md` |
| Setting the collector up (user-facing) | `docs/collectors.md` |
| The Slack poller (user-facing) | `docs/slack-alarm-watch.md` |

## Stay shareable

Self-contained and meant to be shareable (tpm-installable, "clone anywhere"),
so it must stay path-independent and free of dotfiles-specific assumptions —
don't reach into sibling repo files. One soft exception: it reads the per-pane
`@cwd` var that `ubuntu/tmux/update-pane-cwd.sh` sets, and falls back to
`pane_current_path` when absent (so macOS still works).

This repo is **public** and providers are where personal detail creeps in.
Private *values* belong in config files under `~/.config/tmuxopticon/` (as the
Slack provider does with channel IDs); private *behaviour* belongs in a
`providers.d/` provider that can symlink into a private repo. The `pre-commit`
hook in `hooks/` is the backstop, not the plan.

## All shell code must stay bash-3.2 compatible

macOS ships `/bin/bash` 3.2.57 and `env bash` resolves to it on a stock Mac, so
bash-4isms are fatal there. Banned:

- `${var^^}` / `${var,,}` (case conversion) — "bad substitution" kills the
  whole script; this once crash-looped the sidebar the moment a note was set,
  see `bugs/2026-07-06-tmuxopticon-note-crash-bash32.md`
- `mapfile` / `readarray`
- `declare -A`
- `|&`, `&>>`

For case-insensitive matching use character-class globs
(`[Bb][Ll][Oo][Cc][Kk]*`).

## Invariants — do not "simplify" these away

Each one is load-bearing and most were a real bug. The rationale is in the
linked doc; the rule is here.

- **`render` NEVER touches the network.** All fetching happens in
  `providers/collect.sh`, run from cron; `render` only reads `tmp/*.cache`. A
  new provider is a puller invoked by the collector — never a fetch in
  `render`. (`docs/status-panel.md`)
- **Each render frame runs in a subshell** (`( render_frame )`) so a mid-frame
  shell error kills the frame, not the sidebar pane. Keep new frame-time work
  inside `render_frame`. (`docs/internals.md`)
- **The render nap is `sleep … & wait`, not a plain `sleep`.** `render` traps
  WINCH to repaint on resize, and bash only runs a trap after the foreground
  command finishes. Folding it into a foreground `sleep` silently breaks
  instant-repaint-on-resize. (`docs/internals.md`)
- **The registry separator is `\037` (US), not tab.** Tab is IFS-whitespace, so
  `read` coalesces delimiters around an empty middle field and shifts columns.
  (`docs/internals.md`)
- **State lives in tmux options**, not files — including per-session notes and
  manual ordering. Options ride the session through renames and die with it.
  (`docs/internals.md`)
- **The sidebar pane is identified by its title** (`pane_title ==
  "tmuxopticon"`). Every `awk` filter uses that to exclude it from session/pane
  listings. (`docs/internals.md`)
- **Full-height left column comes from `split-window -fhb`.** The `-f` is why
  the sidebar sits *beside* splits instead of halving one. (`docs/internals.md`)
- **The drawer follows focus via tmux hooks calling `ensure`.** Don't add a
  daemon to do this. (`docs/internals.md`)
- **`providers/machine/pull.sh` must stay self-contained** — no sourcing, no
  sibling files, no config. That is the only reason `pull-remote.sh` can stream
  it over ssh and run it on a host with nothing installed.
  (`docs/status-panel.md`)
- **Six traps are baked into `providers/machine/pull.sh`** (`LC_ALL=C`; `cat
  /proc/[0-9]*/stat | awk` never `awk <glob>`; two-sample rates; split
  `/proc/net/dev` on the colon; coverage-not-ranking app rows; `stall io` is
  not a warn trigger). **Read `docs/status-panel.md` § Machine before editing
  that file** — each one produced a wrong answer in production.
- **Adding a provider touches no core file.** Drop a `provider.conf` +
  `pull.sh` directory under `providers/` or
  `~/.config/tmuxopticon/providers.d/`. Neither `collect.sh` nor `render` may
  name a provider. (`docs/status-panel.md`)

Status detection (`working`/`waiting`/`done`) is heuristic and **expected to
break on a Claude Code UI redesign** — update the patterns in `session_status`
/ `session_pane_rows` when it does. Presence detection is sturdier; see
`docs/internals.md` § Status detection.

## Requirements and testing

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
