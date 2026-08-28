# Internals — files, architecture, status detection

Dev reference for the sidebar itself. The status-panel machinery (collector,
providers, cache format) is in `docs/status-panel.md`. The invariants you must
not break are summarised in `CLAUDE.md` — this file is the *why* behind them.

## Files

- `tmuxopticon.sh` — all the logic. Subcommands: `toggle` (on-toggle also runs
  the full `reset` fix, so a fresh open warms every session), `ensure`, `reset`
  (fix the sidebar everywhere — open it in every session's active window
  without moving focus, skipping zoomed windows, then snap every sidebar pane
  back to `@tmuxopticon-width` — bound to `prefix O`), `render`,
  `jump N`, `next`/`prev` (cycle sessions in sidebar order, wrapping),
  `move up|down|reset` (hand-reorder the current session — bound to `prefix
  Up`/`prefix Down`), `click Y`,
  `kill N`, `killcur` (kill the current session after hopping to the next one,
  wrapping, so the client isn't detached), `help` (`-h`/`--help`). No daemon; the redraw
  loop (`render`) runs *inside* the sidebar pane itself. `help` prints the key
  table, reading the live prefix from `tmux show-option -gv prefix`. The status
  panel is read-only here — `render` never fetches; it just reads cache files
  the collector wrote.
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
  field (e.g. a BYO provider's blank `pull`) and shift columns. `session_pane_rows`
  learned this the hard way when its usually-empty `label` field was added — it
  emits `\037` too. Adding a provider
  touches **no core file** — it's pure data discovery.
- `providers/` — the status-panel machinery, all running *outside* the render
  loop (from cron). See `docs/status-panel.md` for the full breakdown of
  `collect.sh`, the `collector-*.sh` on/off switch, and each bundled provider.
  The collector scripts (`collect.sh`, `collector-*.sh`) live directly in
  `providers/`; each *provider* is a subdirectory with a `provider.conf`. Only
  subdirs with a manifest are discovered, so the collector scripts aren't mistaken
  for providers.
- `hooks/` — `pre-commit` + `install.sh`. **This repo is public and providers are
  where personal detail creeps in**, so the hook scans staged content for
  credentials, Slack workspace IDs, email addresses, and any regex on a denylist
  read from *outside* the repo (`$TMUXOPTICON_PRIVATE_WORDS`,
  `~/.config/tmuxopticon/private-words`, or
  `~/.config/tmuxopticon/providers.d/private-words`). `install.sh` sets
  `core.hooksPath` (git never clones hooks). Two structural patterns are tuned
  against real false positives and must stay that way: the Slack-ID regex
  requires an embedded digit (without it, plain all-caps English matches and
  `LICENSE` fails its own hook on "WARRANTIES"), and the token regex requires a
  numeric segment so the documented `xoxp-your-token-here` placeholder stays
  legal. Policy, not just mechanism: private *values* belong in config files
  (as the Slack provider does with channel IDs), private *behaviour* belongs in
  a `providers.d/` provider that can symlink into a private repo.
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
- **The render nap is `sleep … & wait`, not a plain `sleep`** — deliberately.
  `render` traps WINCH to repaint immediately on a pane resize, and bash only
  runs a trap after the foreground command finishes; `wait` returns the moment
  the signal lands. Folding it back into a foreground `sleep` silently breaks
  the instant-repaint-on-resize behavior.
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
- **Session order is one function, `ordered_sessions`** — render, `jump N`,
  `kill N`, the click row-map and `next`/`prev` all read it, which is why
  reordering the list renumbers everything for free. It sorts on two keys: the
  per-session option `@tmuxopticon-order` (the manual rank, written by `move`),
  then `#{session_created}`. An unranked session gets `RANK_UNSET` (9999999), so
  sessions you've never moved sort *below* the ones you have, in creation order —
  a new session lands at the bottom instead of in the middle of a hand-made
  grouping, and with nobody ranked the behaviour is the original pure
  creation-order list. Fields are **tab**-separated (session names contain
  spaces) and the awk pass rewrites only field 1 via `sub()` on `$0`, so a name
  is never re-split; `cut -f3-` returns the remainder verbatim.
- **`move` renumbers the whole list, not just the swapped pair.** After any move
  every session carries an explicit 1..N rank. That's deliberate: it collapses a
  mixed ranked/unranked list into a single explicit order, so the next move has a
  clean baseline instead of fighting `RANK_UNSET`. `move` does not wrap at the
  ends (unlike `next`/`prev`) — the keys are `-r` repeatable, and a wrap would let
  a held key teleport a session end-to-end. `move reset` unsets every rank.
- **`move` never does nothing silently.** A no-op at the ends `display-message`s
  "already at the top/bottom (#i of N)", and a *successful* move reports where
  the session landed when the sidebar is closed (`sidebar_active ||`) — with the
  sidebar open the list itself is the feedback, so staying quiet there keeps a
  repeated key from spamming the status line. This isn't decoration: a silent
  no-op on a fresh keybinding is indistinguishable from a broken keybinding, and
  in a 2-session list an even number of swaps looks exactly like nothing
  happened.
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

## Status detection is heuristic and fragile

Whether a pane *is* Claude is decided robustly first, two ways: `pane_current_command
== claude`, or a bare version string like `2.1.250` — 2.1.x sets its process title
to its own version, so that is what tmux reports — **or** the pane *title* carries
Claude's own glyph — `✳` (U+2733) when idle/ready, a spinner while working
(`$GLYPH_SPIN`: braille U+2800–U+28FF on older builds, ◐◑◒◓ U+25D0–U+25D3 since
2.1.x). The title tell is what
catches a Claude running **over SSH**, where the local command is `ssh` (see the
caveat below); a plain remote shell's title is `user@host:path`, with no such glyph.
Both tells are immune to UI changes and to a custom `statusLine` (which replaces the
`? for shortcuts` hint, so an idle Claude pane would otherwise scrape as a plain
shell). The finer split is read two ways, preferring the first. If the pane text carries a
**`⟨state detail pretty t<epoch>⟩` marker** (README: "How status is detected"),
that wins outright — `pane_marker` pulls it out, and `render` ages the epoch every
frame so the elapsed keeps ticking even when whatever printed it has stopped
repainting. Otherwise `pane_scraped` falls back to Claude's UI text: `esc to
interrupt` or a duration-then-token count for `working`, `· done H:MM` for `done`,
`do you want`/`would you like`/`esc to cancel` for `waiting`, plus a spinner check
on the pane *title*. Both glyph sets live in `$GLYPH_SPIN`/`$GLYPH_CLAUDE` at the
top of the script — change them there, not at the two call sites. Last match wins —
the lines above it are previous turns. A Claude pane matching none of it — idle under
a custom statusLine — falls back to `done` precisely *because* the command is
`claude`.

**Never key `done` off `auto mode on` / `shift+tab to cycle` / `? for shortcuts`
again.** Those sit at the bottom of the pane whether Claude is grinding or idle. In
2026-08 they pinned every pane to `done` at the moment both *working* tells (the
title spinner, `esc to interrupt`) left the UI — three tells that looked
independent were all describing one footer, and it got redrawn as a unit. The
marker exists so the next redesign degrades instead of inverting. Both classifiers
go through `pane_marker`/`pane_scraped`, so the patterns live in one place; they
had drifted into two copies, and the dead one kept the broken version.

**Scrape the live UI, not the transcript.** `pane_scraped` reads only the last
`$PANE_TAIL` rows, and anchors `working` to a sparkle glyph in column 0 — the shape
Claude renders the counter line in, which prose doesn't take. Without both, a pane
*discussing* these markers matches its own conversation and sticks there; the
session that first repaired this detector scraped as `● working` forever, off the
prose explaining the pattern. Anything added here inherits the trap: match
something Claude *renders*, in a shape prose doesn't take. The `waiting` scrape is
the weakest on that count — ordinary English, caught only by the `$PANE_TAIL`
window. `pane_scraped` is perl, not awk, because the glyph classes need `\x{…}`;
its program text stays pure ASCII so it matches `-CSD`'s decoded input.

Caveat: a Claude session running **over SSH** reports `pane_current_command == ssh`
locally, so the command tell fails for those. Presence then rests on the title glyph
(`✳`/spinner, above): an *idle* remote Claude is titled `✳ …`, so it resolves to
`○ done` like a local one; a *working* one carries the spinner glyph → `● working`;
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
