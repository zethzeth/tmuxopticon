#!/usr/bin/env bash
# tmuxopticon.sh — a toggleable left tmux sidebar that watches every session
# at once: split counts and live Claude Code status (working / waiting / done).
#
# Single file, no daemon. Subcommands:
#   toggle      open the sidebar pane (left) in the current window — plus the
#               full `reset` fix (warm every session, snap widths) so cycling
#               sessions afterwards doesn't flash — or close it everywhere
#   ensure      open the sidebar in the current window if globally active
#               (fired from tmux hooks so the drawer follows the focused window)
#   reset       open the sidebar in every session's active window (no focus
#               change) + snap every sidebar back to @tmuxopticon-width —
#               the "fix it everywhere" command after a monitor change
#   render      the redraw loop (runs inside the sidebar pane; not called by hand)
#   jump  <N>   switch to the Nth session as listed in the sidebar (1-based)
#   click <Y>   switch to the session on pane row Y (used by the mouse binding)
#   kill  <N>   kill the Nth session, with a y/n confirm
#   killcur     kill the current session after hopping to the next one
#               (wraps), so the client isn't detached; y/n confirm
#   help        print the key bindings (also: -h, --help)
#
# The bottom status panel reads provider cache files written *outside* this
# process by providers/collect.sh (a cron job). Which providers show is driven
# by ~/.config/tmuxopticon/pull.conf (the *_PULL_ENABLED flags); render only
# reads the matching tmp/<id>.cache files. See providers/ and CLAUDE.md.
#
# tmux options (set with `set -g <option> <value>`):
#   @tmuxopticon-width          sidebar width in columns    (default 26)
#   @tmuxopticon-interval       redraw interval in seconds  (default 2)
#   @tmuxopticon-provider-stale seconds before a provider cache is flagged stale
#                               (default 180)
#   @tmuxopticon-host-aliases   ';'-separated from=to pairs rewriting ugly
#                               hostnames in SSH-pane paths (default: none)
set -u
export LC_ALL="${LC_ALL:-en_US.UTF-8}"   # char-accurate truncation of UTF-8 glyphs

SIDEBAR_TITLE='tmuxopticon'
HEADER_ROWS=0   # no header; the first session block starts at row 0
BLOCK_ROWS=5    # rows per session block: jump / title / status / branch / blank

# colours (SGR): status coloured by state, branch dimmed
C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
C_CUR=$'\033[1;7m'   # active session header: bold + reverse (a highlighted chip)
C_DONE=$'\033[32m'   # green
C_WORK=$'\033[33m'   # yellow
C_WAIT=$'\033[35m'   # purple
C_NVIM=$'\033[36m'   # cyan — a split running nvim/vim
C_REMOTE=$'\033[34m' # blue — an SSH pane (host-prefixed path)
C_NOTE=$'\033[95m'   # bright purple — the per-session note (prefix m); brighter
                     # than C_WAIT's purple, and clear of C_WORK's yellow
C_BLOCKED=$'\033[1;31m' # bold red — a note starting with "BLOCK…" (you're stuck)
C_DOWN=$'\033[31m'   # red — a status provider reporting trouble (e.g. a down monitor)
C_ALERT=$'\033[1;97;41m'  # bold bright-white ON red — the loud error banner text
C_ALERTBAR=$'\033[41m'    # solid red background — the error banner's top/bottom bars
SELF="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)/$(basename "$0")"
ROWMAP="/tmp/tmuxopticon.rows.${UID:-0}"   # row -> session-index map (for click)

# Status panel at the bottom of the sidebar. The render loop NEVER touches the
# network: providers run off-clock from cron (providers/collect.sh) and each
# writes a tiny cache file; render only reads them. pull.conf says which are on.
PULL_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon/pull.conf"
PLUGIN_TMP="$(dirname "$SELF")/tmp"   # where the collector drops <id>.cache files
# The provider registry: which status boxes exist isn't hardcoded here — render()
# walks every provider.conf (bundled + ~/.config/tmuxopticon/providers.d/). This
# only globs the filesystem; it never sources pull.conf (the loop must keep its
# env clean), so it's safe to call each frame.
TMUXOPTICON_PLUGIN="$(dirname "$SELF")"
# shellcheck source=lib/providers.sh
. "$(dirname "$SELF")/lib/providers.sh"
# Master on/off switch for the collector, written by providers/collector-start.sh
# / collector-stop.sh. Absent = OFF (the default); render then shows a single
# "Cron-checker disabled" notice instead of provider boxes.
COLLECTOR_FLAG="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon/collector.enabled"

opt() { # opt <@option> <default>
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"
}

apply_host_aliases() { # rewrite ugly hostnames in a path via @tmuxopticon-host-aliases
  # The option is a ';'-separated list of from=to pairs, e.g.
  #   set -g @tmuxopticon-host-aliases 'ip-10-13-99-46=zeod;10.0.0.5=db'
  # Each `from` is substring-replaced with `to` (so an SSH path's "host:" prefix
  # gets a friendly alias). Empty option -> the path is returned untouched. This
  # keeps personal hostnames out of the shared engine — set them in your own conf.
  local p="$1" spec pair from to oldifs
  spec="$(opt @tmuxopticon-host-aliases '')"
  [ -n "$spec" ] || { printf '%s' "$p"; return; }
  oldifs="$IFS"; IFS=';'
  for pair in $spec; do
    IFS="$oldifs"
    case "$pair" in *=*) from="${pair%%=*}"; to="${pair#*=}"; [ -n "$from" ] && p="${p//$from/$to}";; esac
    IFS=';'
  done
  IFS="$oldifs"
  printf '%s' "$p"
}

ordered_sessions() { # canonical order, shared by render / jump / click
  # Oldest-first, so a freshly created session lands at the *bottom* of the
  # sidebar instead of jumping to the top. tmux's default list order is
  # alphabetical by name, which floats new auto-numbered sessions (0, 1, …) up;
  # sorting by #{session_created} (a UNIX timestamp) gives stable creation order.
  tmux list-sessions -F '#{session_created} #{session_name}' 2>/dev/null \
    | sort -n -s -k1,1 \
    | sed 's/^[0-9]* //'
}

split_count() { # split_count <session> -> pane count excluding the sidebar itself
  tmux list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | grep -vcx "$SIDEBAR_TITLE"
}

session_status() { # -> working|waiting|done|""  (worst-case across the session's panes)
  local sess="$1" worst='' pane content
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)"
    if printf '%s' "$content" | grep -qiF 'esc to interrupt'; then
      printf 'working'; return
    elif printf '%s' "$content" | grep -qiE 'do you want|would you like|esc to cancel'; then
      worst='waiting'
    elif printf '%s' "$content" | grep -qiE 'shift\+tab to cycle|\? for shortcuts|auto mode on'; then
      [ "$worst" = 'waiting' ] || worst='done'
    fi
  done < <(tmux list-panes -t "$sess" -F '#{pane_id} #{pane_title}' 2>/dev/null \
             | awk -v t="$SIDEBAR_TITLE" '$2 != t { print $1 }')
  printf '%s' "$worst"
}

pane_path() { # <pane_id> -> the pane's path for display
  # Prefer @cwd (set by ubuntu/tmux/update-pane-cwd.sh): it already reads as
  # "host:~/path" for SSH panes and "~/path" for local ones. Fall back to the
  # local pane cwd (mac has no @cwd) with $HOME collapsed to ~.
  local pane="$1" p host rest
  p="$(tmux display-message -p -t "$pane" '#{@cwd}' 2>/dev/null)"
  [ -n "$p" ] || p="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  p="$(apply_host_aliases "$p")"   # friendly aliases for ugly hostnames (user-configured)
  # Collapse $HOME -> ~ . Peel off any "host:" prefix first so SSH paths collapse
  # too. The ~ stays inside double quotes so bash doesn't tilde-expand it back.
  case "$p" in *:*) host="${p%%:*}:"; rest="${p#*:}";; *) host=''; rest="$p";; esac
  case "$rest" in "$HOME"/*) rest="~${rest#"$HOME"}";; "$HOME") rest='~';; esac
  printf '%s%s' "$host" "$rest"
}

session_pane_rows() { # one "<pane_index>\t<status>\t<path>" line per non-sidebar pane.
  # pane_index is tmux's own per-window number (what `prefix q` / the pane border
  # show), so the sidebar row lines up with the on-screen pane. status is
  # working|waiting|done (Claude panes) or nvim|remote|local (plain terminals).
  # path comes from pane_path (host:~/path on SSH).
  local sess="$1" line pidx pane rest cmd title content stat ppath claude
  while IFS= read -r line; do
    pidx="${line%% *}"; line="${line#* }"   # peel pane_index, then pane_id, then
    pane="${line%% *}"; rest="${line#* }"   # the command, leaving pane_title
    cmd="${rest%% *}";  title="${rest#* }"  # (which may itself contain spaces)
    [ -n "$pane" ] || continue
    ppath="$(pane_path "$pane")"
    # Is this a Claude Code pane? The foreground command is the robust tell —
    # tmux reports pane_current_command as `claude`. Unlike the footer text this
    # survives a custom statusLine, which replaces the "? for shortcuts" hint we
    # used to key idle/done off. (During a tool call the command briefly changes,
    # but then Claude is *working* and the title/footer checks below catch it.)
    claude=0; case "$cmd" in claude|claude-code) claude=1;; esac
    # A Claude pane over SSH reports cmd=ssh, so the command tell fails. But Claude
    # also stamps the pane *title* with its own glyph — `✳` (U+2733) when idle/ready,
    # a braille spinner while working — and that propagates through ssh/tmux. Either
    # marker means "this is Claude", so an idle remote session resolves to `done`
    # (via the claude=1 branch below) instead of falling through to `⇄ remote`. A
    # plain remote shell's title is `user@host:path`, with no such glyph.
    if printf '%s' "$title" | perl -CSD -ne 'exit(/[\x{2733}\x{2800}-\x{28ff}]/?0:1)' 2>/dev/null; then claude=1; fi
    # working: Claude animates a braille spinner (U+2800–U+28FF) in the pane title.
    # The title isn't truncated by pane width, so this survives narrow splits where
    # the footer's "esc to interrupt" gets cut off (leaving only the "done" markers).
    if printf '%s' "$title" | perl -CSD -ne 'exit(/[\x{2800}-\x{28ff}]/?0:1)' 2>/dev/null; then stat=working
    else
      content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)"
      if   printf '%s' "$content" | grep -qiF 'esc to interrupt'; then stat=working
      elif printf '%s' "$content" | grep -qiE 'do you want|would you like|esc to cancel'; then stat=waiting
      elif printf '%s' "$content" | grep -qiE 'shift\+tab to cycle|\? for shortcuts|auto mode on'; then stat=done
      elif [ "$claude" = 1 ]; then stat=done   # a Claude pane sitting idle: command says claude, no working/waiting cue
      else
        # Not a Claude pane — label the terminal itself. nvim wins on the
        # foreground command; an SSH pane shows a "host:" prefix in its path
        # (set via @cwd); everything else is a plain local shell.
        case "$cmd" in
          nvim|vim|view|nvi) stat=nvim;;
          *) case "$ppath" in *:*) stat=remote;; *) stat=local;; esac;;
        esac
      fi
    fi
    printf '%s\t%s\t%s\n' "$pidx" "$stat" "$ppath"
  done < <(tmux list-panes -t "$sess" -F '#{pane_index} #{pane_id} #{pane_current_command} #{pane_title}' 2>/dev/null | awk -v t="$SIDEBAR_TITLE" '$4 != t { print }')
}

session_title() { # -> active pane title, blank for default/uninteresting ones
  local sess="$1" title host shost
  title="$(tmux display-message -p -t "$sess" '#{pane_title}' 2>/dev/null)"
  host="$(tmux display-message -p '#{host}' 2>/dev/null)"
  case "$title" in "$host"|"$SIDEBAR_TITLE"|'') return;; esac
  # drop any leading icon/spinner glyph + spaces so the real text shows from col 1
  title="$(printf '%s' "$title" | sed -E 's/^[^[:alnum:]]+//')"
  # drop a leading "user@localhost:" — the shell's default title is
  # user@host:path, and the local user+host is pure noise in the sidebar.
  # Match both the full hostname and its short form (mac: Foo.local vs Foo).
  # Runs after the icon strip so the "~" of the remaining path survives.
  shost="${host%%.*}"
  case "$title" in
    "${USER:-}@${host}:"*)  title="${title#"${USER:-}@${host}:"}";;
    "${USER:-}@${shost}:"*) title="${title#"${USER:-}@${shost}:"}";;
  esac
  printf '%s' "$title"
}

session_label() { # the manual session name if you set one, else the (Claude) pane title
  local sess="$1"
  case "$sess" in ''|*[!0-9]*) printf '%s' "$sess"; return;; esac  # non-numeric = you renamed it
  session_title "$sess"                                            # numeric/auto = show pane title
}

session_note() { # -> the session's note (@tmuxopticon-note), if any
  # Stored as a per-session tmux user option, set via `prefix m` (see the
  # bindings in tmuxopticon.tmux). No files: the note survives a rename
  # (options ride the session, not its name) and dies with the session —
  # which is the right lifetime for "Next step: …" / "BLOCKED: …" jottings.
  tmux show-option -qv -t "$1" @tmuxopticon-note 2>/dev/null
}

wrap_note() { # wrap_note <text> <width> — split a note into sidebar-width lines
  # Notes are never truncated: text word-wraps at <width>, and a single word
  # longer than <width> (a URL, a path) is hard-split rather than cut off.
  # A literal "\n" typed into the note forces a line break — tmux's
  # command-prompt is single-line, so that two-character sequence is the only
  # way to author a break by hand. ${#…} is char-accurate for UTF-8 (LC_ALL).
  local text="$1" w="$2" seg line word
  [ "$w" -ge 1 ] || w=1
  while IFS= read -r seg; do
    [ -n "$seg" ] || { printf '\n'; continue; }   # explicit \n\n = a blank line
    line=''
    local -a words=()
    read -ra words <<< "$seg"
    for word in "${words[@]}"; do
      if [ -z "$line" ]; then line="$word"
      elif [ $(( ${#line} + 1 + ${#word} )) -le "$w" ]; then line="$line $word"
      else printf '%s\n' "$line"; line="$word"
      fi
      while [ "${#line}" -gt "$w" ]; do printf '%s\n' "${line:0:w}"; line="${line:w}"; done
    done
    [ -n "$line" ] && printf '%s\n' "$line"
  done <<< "${text//\\n/$'\n'}"
  return 0
}

current_session() { # the session owning this sidebar pane
  tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null
}

# --- Status providers (read-only) --------------------------------------------
# A provider is just a cache file in tmp/, written by providers/collect.sh off a
# cron clock. tmuxopticon never fetches anything itself — it reads the cache and
# draws a box. pull.conf's *_PULL_ENABLED flags decide which boxes appear.
#
# Cache format (shared by every provider):
#   line1  epoch          (for the staleness check)
#   line2  state          ok | warn | err
#   line3  summary        the headline shown next to the icon
#   line4+ detail lines   shown dimmed + indented (optional)

pull_enabled() { # pull_enabled <KEY> — true if pull.conf sets KEY to true/1/yes
  [ -r "$PULL_CONF" ] || return 1
  grep -qE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*(true|1|yes)[[:space:]]*$" "$PULL_CONF"
}

provider_box() { # provider_box <title> <cachefile> <tw> -> the box lines (divider+title+body)
  local title="$1" cache="$2" tw="$3"
  [ -r "$cache" ] || return 0          # enabled but nothing pulled yet -> stay quiet
  local stale now epoch state summary line details=() idx=0 shown=0 max=6 div age icon col bar pad staleline synctime
  stale="$(opt @tmuxopticon-provider-stale 180)"       # cron refreshes ~every 60s; flag if cold
  printf -v div '%*s' "$tw" ''; div="${div// /─}"
  # Read the whole cache first, so the renderer can pick a layout from the state
  # (an `err` gets the loud full-width banner below, not the one-line treatment).
  while IFS= read -r line; do
    case "$idx" in 0) epoch="$line";; 1) state="$line";; 2) summary="$line";; *) details+=("$line");; esac
    idx=$((idx + 1))
  done < "$cache"
  now="$(date +%s)"; case "${epoch:-}" in ''|*[!0-9]*) epoch=0;; esac
  age=$(( now - epoch ))
  # Only call out a cold cache once it's older than the stale threshold (default
  # 3 min). Show the wall-clock time of the last sync + how long ago, in minutes.
  staleline=''
  if [ "$age" -ge "$stale" ]; then
    synctime="$(date -d "@$epoch" '+%-H:%M' 2>/dev/null || date -r "$epoch" '+%H:%M' 2>/dev/null)"
    staleline="${C_WAIT} Last sync: ${synctime} ($(( age / 60 )) min ago)${C_RESET}"
  fi

  if [ "${state:-}" = err ]; then
    # ERROR: scream. A block of red — solid bars top & bottom and reverse-video
    # (red-background) lines between, so the whole box draws the eye, not a glyph.
    printf -v bar '%*s' "$tw" ''                                  # tw spaces -> a solid red bar
    bline() { local s=" $1"; printf -v s '%-*s' "$tw" "${s:0:tw}"; printf '%s\n' "${C_ALERT}${s}${C_RESET}"; }
    printf '%s\n' "${C_ALERTBAR}${bar}${C_RESET}"                 # top bar
    bline "⚠ ${title} — ERROR"
    bline "⚠ ${summary}"
    for line in "${details[@]}"; do                              # details, still on red
      [ "$shown" -ge "$max" ] && break
      [ -n "$line" ] && bline "  ${line}"; shown=$((shown + 1))
    done
    printf '%s\n' "${C_ALERTBAR}${bar}${C_RESET}"                 # bottom bar
    [ -n "$staleline" ] && printf '%s\n' "$staleline"
    return 0
  fi

  printf '%s\n' "${C_DIM}${div}${C_RESET}"
  printf '%s\n' "${C_BOLD} ${title:0:tw}${C_RESET}"
  [ -n "$staleline" ] && printf '%s\n' "$staleline"   # cron stopped?
  case "${state:-}" in                                  # icon + colour by state
    ok)   icon='○'; col="$C_DONE";;
    info) icon='•'; col="$C_RESET";;                    # neutral: a count/FYI, not a health verdict
    warn) icon='●'; col="$C_DOWN";;
    *)    icon='·'; col="$C_DIM";;
  esac
  printf '%s\n' "${col} ${icon} ${summary:0:$((tw-3))}${C_RESET}"
  for line in "${details[@]}"; do                       # detail lines: dimmed, indented, capped
    [ "$shown" -ge "$max" ] && break
    [ -n "$line" ] && printf '%s\n' "${C_DIM}   ${line:0:$((tw-3))}${C_RESET}"
    shown=$((shown + 1))
  done
  [ "${#details[@]}" -gt "$max" ] && printf '%s\n' "${C_DIM}   +$(( ${#details[@]} - max )) more${C_RESET}"
  return 0
}

render_frame() { # build + paint one frame (called from render, inside a subshell)
  local w h tw EOL=$'\033[K\n'
  w="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_width}' 2>/dev/null)"
  [ -n "$w" ] || w="$(opt @tmuxopticon-width 26)"
  h="$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_height}' 2>/dev/null)"
  case "$h" in ''|*[!0-9]*) h=40;; esac
  tw=$(( w - 1 )); [ "$tw" -lt 1 ] && tw=1           # usable text width (no indent)
  local div; printf -v div '%*s' "$tw" ''; div="${div// /─}"   # per-frame divider rule

  # Status panel (bottom-anchored). Each enabled provider's cache (written by
  # the cron collector) becomes a box; build them now so we know how many rows
  # to reserve at the bottom. Order top→bottom: Uptime Robot, Open PRs, Alarms
  # (alarms sit at the very bottom — closest to the bottom = most visible).
  local boxlines=() bl bh=0
  if [ -e "$COLLECTOR_FLAG" ]; then
    # Collector ON: one box per enabled provider, drawn in registry order (the
    # manifests' `order` field, low=top — Uptime Robot, Open PRs, then Alarms at
    # the very bottom, closest to the edge = most visible). provider_box draws
    # nothing for a provider whose cache doesn't exist yet, so enabled-but-unpulled
    # stays silent. The registry walk is filesystem-only — no pull.conf sourcing.
    local pf_order pf_id pf_title pf_flag pf_rest
    while IFS=$'\037' read -r pf_order pf_id pf_title pf_flag pf_rest; do
      [ -n "$pf_id" ] && [ -n "$pf_flag" ] || continue
      pull_enabled "$pf_flag" || continue
      while IFS= read -r bl; do boxlines+=("$bl"); bh=$((bh + 1)); done < <(provider_box "$pf_title" "$PLUGIN_TMP/$pf_id.cache" "$tw")
    done < <(provider_rows)
  else
    # Collector OFF (the default): nothing is being pulled, so any cached boxes
    # would only show stale data. Draw one quiet notice instead — re-enable with
    # providers/collector-start.sh.
    boxlines+=("${C_DIM}${div}${C_RESET}")
    boxlines+=("${C_DIM} ⊘ Cron-checker disabled${C_RESET}")
    bh=2
  fi
  if [ "$bh" -gt 0 ]; then          # two blank rows under the lowest box, so the
    boxlines+=('' ''); bh=$((bh + 2))   # panel doesn't clash with the tmux status bar
  fi
  local avail=$h; [ "$bh" -gt 0 ] && avail=$(( h - bh ))
  [ "$avail" -lt 1 ] && avail=1                       # rows the session list may use

  # --- build the frame + a row->session map, then paint once (no flicker) ---
  # \033[K clears each line to its end; \033[J clears any leftover rows below.
  local out='' rows='' cur s idx=0 mark jump name nb hdr note ncol nfirst npfx nline pidx stat ppath seg segp col pad budget gap line numpfx nlen=3 prow=0
  cur="$(current_session)"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ "$prow" -ge "$avail" ] && break               # list filled the space above the box
    idx=$((idx + 1))
    mark=' '; [ "$s" = "$cur" ] && mark='▶'
    if [ "$idx" -le 9 ]; then jump="[$idx]"; else jump='[ ]'; fi
    name="$(session_label "$s")"; [ -n "$name" ] || name="$s"   # friendly name, else raw session
    # truncate the name to the room *left of* the "▶[N]  " prefix (7 cols on
    # the active row — mark+jump+chip space+2 gaps — 6 on the rest), so a long
    # title never overflows the sidebar width and wraps onto the next row.
    if [ "$s" = "$cur" ]; then                          # make the active session pop
      nb=$(( tw - 7 )); [ "$nb" -lt 1 ] && nb=1
      hdr="${C_CUR}${mark}${jump} ${C_RESET}  ${C_BOLD}${name:0:nb}${C_RESET}"
    else
      nb=$(( tw - 6 )); [ "$nb" -lt 1 ] && nb=1
      hdr="${mark}${jump}  ${name:0:nb}"
    fi
    out+="${hdr}${EOL}"; rows+="${idx}"$'\n'; prow=$((prow + 1))      # header: ▶[N]  name
    # The session's note ("Next step: …"), right under its name — your own
    # jotting about where this session is at, so you don't have to read the
    # Claude wall of text to re-orient. "BLOCK…" notes turn bold red. Notes
    # are never cut off: wrap_note word-wraps them over as many rows as
    # needed (a typed "\n" forces a break); continuations indent under the ✎.
    note="$(session_note "$s")"
    if [ -n "$note" ]; then
      # NB: no ${note^^} here — case-conversion is bash 4+, and macOS's
      # /bin/bash is 3.2, where it's a fatal "bad substitution".
      case "$note" in [Bb][Ll][Oo][Cc][Kk]*) ncol="$C_BLOCKED";; *) ncol="$C_NOTE";; esac
      nfirst=1
      while IFS= read -r nline; do
        [ "$prow" -ge "$avail" ] && break 2         # no room left before the box
        if [ "$nfirst" = 1 ]; then npfx=' ✎ '; nfirst=0; else npfx='   '; fi
        out+="${ncol}${npfx}${nline}${C_RESET}${EOL}"; rows+="${idx}"$'\n'; prow=$((prow + 1))
      done < <(wrap_note "$note" $(( tw - 3 )))
    fi
    # one line per split: "<icon> <label>   <path>" — Claude state for Claude
    # panes, terminal type (nvim/remote/shell) for the rest.
    while IFS=$'\t' read -r pidx stat ppath; do
      [ "$prow" -ge "$avail" ] && break 2           # no room left before the box
      case "$stat" in
        working) seg="${C_WORK}● working${C_RESET}";   segp='● working';;
        waiting) seg="${C_WAIT}◐ waiting${C_RESET}";   segp='◐ waiting';;
        done)    seg="${C_DONE}○ done${C_RESET}";      segp='○ done';;
        nvim)    seg="${C_NVIM}N nvim${C_RESET}";       segp='N nvim';;
        remote)  seg="${C_REMOTE}⇄ remote${C_RESET}";  segp='⇄ remote';;
        local)   seg="${C_DIM}\$ shell${C_RESET}";     segp='$ shell';;
        *)       seg=''; segp='';;
      esac
      # Lead each pane row with tmux's pane_index (right-aligned in 2 cols) — the
      # same number `prefix q` flashes and the pane border shows, so a row maps to
      # an on-screen pane at a glance. nlen=3 accounts for "NN " in the width math.
      printf -v numpfx '%2s ' "$pidx"
      if [ -n "$segp" ]; then                           # Claude pane: status column + path
        col=10; pad=$(( col - ${#segp} )); [ "$pad" -lt 1 ] && pad=1
        budget=$(( tw - nlen - col )); [ "$budget" -lt 1 ] && budget=1
        printf -v gap '%*s' "$pad" ''
        line="${C_DIM}${numpfx}${C_RESET}${seg}${gap}${C_DIM}${ppath:0:budget}${C_RESET}"
      else                                              # non-Claude pane: just the path
        budget=$(( tw - nlen )); [ "$budget" -lt 1 ] && budget=1
        line="${C_DIM}${numpfx}${ppath:0:budget}${C_RESET}"
      fi
      out+="${line}${EOL}"; rows+="${idx}"$'\n'; prow=$((prow + 1))
    done < <(session_pane_rows "$s")
    [ "$prow" -ge "$avail" ] && break               # skip the divider if we're out of room
    out+="${C_DIM}${div}${C_RESET}${EOL}"; rows+="${idx}"$'\n'; prow=$((prow + 1))  # divider between sessions
  done < <(ordered_sessions)
  printf '%s' "$rows" > "$ROWMAP.$$" 2>/dev/null && mv -f "$ROWMAP.$$" "$ROWMAP" 2>/dev/null
  printf '\033[H%s\033[J' "$out"                     # home, paint, clear list + gap below
  if [ "$bh" -gt 0 ]; then                           # pin the status box to the bottom rows
    local boxstart=$(( h - bh + 1 )) boxout='' bi
    [ "$boxstart" -lt 1 ] && boxstart=1
    for bi in "${boxlines[@]}"; do boxout+="${bi}"$'\033[K'$'\n'; done
    printf '\033[%d;1H%s' "$boxstart" "${boxout%$'\n'}"   # no trailing newline -> no scroll
  fi
  return 0
}

render() {
  printf '\033[?25l'                                   # hide cursor
  trap 'printf "\033[?25h\033[2J\033[H"; exit 0' TERM INT HUP
  # A pane resize (monitor swap, switching to a session whose background window
  # gets re-sized to the client, a manual drag) delivers WINCH: repaint right
  # away instead of letting tmux's reflow of the old frame sit garbled for up
  # to a full interval. The trap body is a no-op — its mere arrival makes the
  # `wait` below return early, and the loop paints a fresh frame.
  trap ':' WINCH
  local interval rc napper
  while :; do
    interval="$(opt @tmuxopticon-interval 2)"        # read live so changes apply at once
    # Each frame runs in a subshell so a hard shell error (bad substitution,
    # set -u on an unbound var, a syntax-level surprise in odd input) kills
    # only that frame, not this loop — a crash used to close the sidebar pane
    # outright. On failure, paint the error where the frame would have gone
    # and keep ticking; the next frame gets a fresh try.
    ( render_frame ); rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '\033[H%s\033[K\n%s\033[K\n\033[J' \
        "${C_ALERT} ⚠ render failed (exit ${rc}) ${C_RESET}" \
        "${C_DIM} retrying every ${interval}s…${C_RESET}"
    fi
    # Nap via background sleep + wait, NOT a plain foreground sleep: bash only
    # runs a trap after the foreground command finishes, so a plain sleep would
    # swallow the WINCH until the tick ended. `wait` returns the moment a
    # trapped signal lands; the leftover sleep is reaped so they can't pile up.
    sleep "$interval" & napper=$!
    wait "$napper" 2>/dev/null
    kill "$napper" 2>/dev/null || true
  done
}

sidebar_active() { [ "$(opt @tmuxopticon-active 0)" = 1 ]; }

in_current_window() { # -> sidebar pane id in the current window, if any
  tmux list-panes -F '#{pane_id} #{pane_title}' 2>/dev/null \
    | awk -v t="$SIDEBAR_TITLE" '$2 == t { print $1; exit }'
}

open_here() { # open the sidebar in the current window, keep focus on the work pane
  local width; width="$(opt @tmuxopticon-width 26)"
  # -f spans the full window height (not just the active pane), so the sidebar
  # is a true left column that sits beside any existing splits instead of
  # carving one of them in half. -b puts it on the left, -h is a side split.
  tmux split-window -fhb -l "$width" "exec '$SELF' render"
  tmux select-pane -T "$SIDEBAR_TITLE"
  tmux last-pane 2>/dev/null || true
}

kill_everywhere() { # remove every sidebar pane across all sessions/windows
  tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null \
    | awk -v t="$SIDEBAR_TITLE" '$2 == t { print $1 }' \
    | while IFS= read -r p; do tmux kill-pane -t "$p" 2>/dev/null || true; done
}

warm_everywhere() { # open the sidebar in every session's active window, focus untouched
  # Pre-pays the "first visit splits a fresh pane" flash: after this, cycling
  # sessions lands on sidebars that are already rendering. split-window -d
  # keeps the client where it is; zoomed windows are skipped (unzooming a
  # deliberately zoomed pane from the background would be rude — `ensure`
  # handles those on arrival, as it always has).
  sidebar_active || return 0
  local width sess have zoomed prev new
  width="$(opt @tmuxopticon-width 26)"
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    zoomed="$(tmux display-message -p -t "=$sess:" '#{window_zoomed_flag}' 2>/dev/null)"
    [ "$zoomed" = 1 ] && continue
    have="$(tmux list-panes -t "=$sess:" -F '#{pane_id} #{pane_title}' 2>/dev/null \
      | awk -v t="$SIDEBAR_TITLE" '$2 == t { print $1; exit }')"
    [ -n "$have" ] && continue
    prev="$(tmux display-message -p -t "=$sess:" '#{pane_id}' 2>/dev/null)"
    new="$(tmux split-window -dfhb -l "$width" -t "=$sess:" -P -F '#{pane_id}' "exec '$SELF' render" 2>/dev/null)" || continue
    [ -n "$new" ] || continue
    # select-pane -T selects the pane as a side effect of titling it, so put
    # the window's active pane back where it was.
    tmux select-pane -t "$new" -T "$SIDEBAR_TITLE" 2>/dev/null
    [ -n "$prev" ] && tmux select-pane -t "$prev" 2>/dev/null
  done < <(ordered_sessions)
  return 0
}

reset_width() { # warm every session, then snap every sidebar to @tmuxopticon-width.
  # Client resizes (docking, projector, monitor swap) make tmux rescale panes
  # proportionally, so the sidebar drifts from its configured width. The render
  # loop re-reads pane_width every tick, so resizing alone is a full refresh.
  warm_everywhere
  local width; width="$(opt @tmuxopticon-width 26)"
  tmux list-panes -a -F '#{pane_id} #{pane_title}' 2>/dev/null \
    | awk -v t="$SIDEBAR_TITLE" '$2 == t { print $1 }' \
    | while IFS= read -r p; do tmux resize-pane -t "$p" -x "$width" 2>/dev/null || true; done
}

ensure() { # ensure the sidebar exists in the current window, if globally active.
  # Fired from tmux hooks on every window/session change so the drawer follows
  # the focused window. No-op when inactive or already present, so it's cheap
  # and safe to call repeatedly.
  sidebar_active || return 0
  [ -z "$(in_current_window)" ] && open_here
  return 0
}

toggle() { # global on/off switch
  if sidebar_active; then
    tmux set-option -g @tmuxopticon-active 0
    kill_everywhere
  else
    tmux set-option -g @tmuxopticon-active 1
    [ -z "$(in_current_window)" ] && open_here
    # Toggling on applies the full `prefix O` fix by itself: warm every other
    # session's active window (so cycling sessions later doesn't flash a fresh
    # split) and snap all sidebars to the configured width.
    reset_width
  fi
}

jump() { # jump <N>  (1-based index into the canonical order); no-op if absent
  local n="${1:-}" s
  case "$n" in ''|*[!0-9]*) return 0;; esac
  s="$(ordered_sessions | sed -n "${n}p")"
  [ -n "$s" ] && tmux switch-client -t "$s"
  return 0
}

step() { # step <1|-1>  next/prev session in the sidebar's canonical order, wrapping
  # Deliberately NOT tmux's own `switch-client -n`: that cycles alphabetically,
  # which diverges from the creation-order list the sidebar shows.
  local dir="${1:-1}" cur list n idx target
  cur="$(current_session)"
  list="$(ordered_sessions)"
  n="$(printf '%s\n' "$list" | grep -c .)"
  [ "$n" -gt 1 ] || return 0
  idx="$(printf '%s\n' "$list" | grep -nxF -- "$cur" | cut -d: -f1)"
  [ -n "$idx" ] || idx=1
  idx=$(( (idx - 1 + dir + n) % n + 1 ))
  target="$(printf '%s\n' "$list" | sed -n "${idx}p")"
  [ -n "$target" ] && tmux switch-client -t "$target"
  return 0
}

click() { # click <Y>  (0-based pane row); resolve the session via the row map
  local y="${1:-}" idx
  case "$y" in ''|*[!0-9]*) return 0;; esac
  idx="$(sed -n "$((y + 1))p" "$ROWMAP" 2>/dev/null)"
  [ -n "$idx" ] && jump "$idx"
  return 0
}

killn() { # kill <N>: kill the Nth session in the list, with a y/n confirm
  local n="${1:-}" s
  case "$n" in ''|*[!0-9]*) return 0;; esac
  s="$(ordered_sessions | sed -n "${n}p")"
  [ -n "$s" ] && tmux confirm-before -p "kill session '$s'? (y/n)" "kill-session -t '$s'"
  return 0
}

killcur() { # kill the current session, first hopping to the next one (wraps)
  # Plain `kill-session` on the attached session detaches the client — you saw
  # off the branch you're sitting on. So: switch to the next session in the
  # sidebar's canonical order (wrapping past the end), THEN kill the old one.
  local cur list n idx target
  cur="$(current_session)"
  [ -n "$cur" ] || return 0
  list="$(ordered_sessions)"
  n="$(printf '%s\n' "$list" | grep -c .)"
  if [ "$n" -le 1 ]; then # nowhere to hop — plain kill, client detaches
    tmux confirm-before -p "kill session '$cur'? (last one — will detach) (y/n)" "kill-session -t '$cur'"
    return 0
  fi
  idx="$(printf '%s\n' "$list" | grep -nxF -- "$cur" | cut -d: -f1)"
  [ -n "$idx" ] || idx=1
  target="$(printf '%s\n' "$list" | sed -n "$(( idx % n + 1 ))p")"
  tmux confirm-before -p "kill session '$cur'? (y/n)" \
    "switch-client -t '$target' ; kill-session -t '$cur'"
  return 0
}

help() { # print the key bindings (querying tmux for the live prefix key)
  local p disp
  p="$(tmux show-option -gv prefix 2>/dev/null)"; p="${p:-C-b}"
  disp="${p/C-/Ctrl+}"; disp="${disp/M-/Alt+}"   # C-Space -> Ctrl+Space
  cat <<EOF
${C_BOLD}tmuxopticon${C_RESET} — a live left sidebar watching every tmux session.
claude per split:  ${C_WORK}● working${C_RESET}   ${C_WAIT}◐ waiting${C_RESET}   ${C_DONE}○ done${C_RESET}
plain  per split:  ${C_NVIM}N nvim${C_RESET}   ${C_REMOTE}⇄ remote${C_RESET}   ${C_DIM}\$ shell${C_RESET}

prefix is ${C_BOLD}${disp}${C_RESET} — press & release it, then the key below.

  ${C_BOLD}Sidebar${C_RESET}
    prefix o          toggle the sidebar on/off (global) — turning it on also
                      opens it in every other session, so cycling sessions
                      won't flash a fresh split
    prefix O          fix the sidebar everywhere: open it in every session
                      (pre-paying the first-visit flash) and snap them all
                      back to the configured width (after docking, monitor
                      swaps, projector meetings…)
    click a row       jump to that session
    pane numbers      each split row is led by its tmux pane number —
                      the same one ${C_BOLD}prefix q${C_RESET} flashes and the pane border shows

  ${C_BOLD}Jump${C_RESET}
    prefix 1 … 9      jump to the Nth session in the list
    prefix n / p      next / previous session in the list (wraps)

  ${C_BOLD}Sessions${C_RESET}
    prefix t          rename the current session
    prefix m          set/edit the session's note (${C_NOTE}✎${C_RESET} under its name in
                      the sidebar). Prefilled for editing; submit empty to
                      clear. Long notes word-wrap — nothing is cut off — and
                      a typed \n forces a line break. A note starting with
                      "BLOCK" goes ${C_BLOCKED}bold red${C_RESET} — e.g. "BLOCKED: no local db".

  ${C_BOLD}Kill${C_RESET}  (prefix K opens a kill table, then:)
    prefix K 1 … 9    kill the Nth session                        (with confirm)
    prefix K K        kill current session + hop to next (wraps)  (with confirm)
    prefix K a        kill ALL sessions but this one              (with confirm)

  ${C_BOLD}Status box${C_RESET}  (bottom of the sidebar — fed by the cron collector)
    Start/stop the collector (off by default) with
      ${C_DIM}providers/collector-start.sh${C_RESET} / ${C_DIM}collector-stop.sh${C_RESET}   (${C_DIM}collector-status.sh${C_RESET} to inspect)
    While stopped the box reads ${C_DIM}⊘ Cron-checker disabled${C_RESET}.
    Providers are pulled by ${C_BOLD}providers/collect.sh${C_RESET} (run once a minute from
    cron) into ${C_DIM}tmp/<id>.cache${C_RESET}; the sidebar just renders them. Turn each
    one on in ${C_DIM}~/.config/tmuxopticon/pull.conf${C_RESET}:
      ${C_DIM}SLACK_PULL_ENABLED=true${C_RESET}        Slack alarm channels  → Alarms box
      ${C_DIM}UPTIME_ROBOT_PULL_ENABLED=true${C_RESET} Uptime Robot monitors → Uptime Robot box
      ${C_DIM}PRS_PULL_ENABLED=true${C_RESET}          open PRs to review    → Open PRs box
    Icons:  ${C_DONE}○ ok${C_RESET}   • info   ${C_DOWN}● needs attention${C_RESET}   ${C_ALERT} ⚠ ERROR ${C_RESET}   ${C_WAIT}Last sync: …${C_RESET} (cron stopped)

  ${C_BOLD}Config${C_RESET}  (set -g in your .tmux.conf)
    @tmuxopticon-width           sidebar width in columns       (default 34)
    @tmuxopticon-interval        redraw interval in seconds      (default 1)
    @tmuxopticon-provider-stale  secs before a cache is "stale"  (default 180)
    @tmuxopticon-host-aliases    from=to;… aliases for SSH-path hostnames
    @tmuxopticon-default-keys    set 'off' to bind the keys yourself
EOF
}

cmd="${1:-toggle}"; [ $# -gt 0 ] && shift
case "$cmd" in
  toggle) toggle;;
  ensure) ensure;;
  reset)  reset_width;;
  render) render;;
  jump)   jump "${1:-}";;
  next)   step 1;;
  prev)   step -1;;
  click)  click "${1:-}";;
  kill)   killn "${1:-}";;
  killcur) killcur;;
  help|-h|--help) help;;
  *) printf 'usage: %s {toggle|ensure|reset|render|jump N|next|prev|click Y|kill N|killcur|help}\n' "$SELF" >&2; exit 2;;
esac
