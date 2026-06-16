#!/usr/bin/env bash
# lib/providers.sh — tmuxopticon's provider registry.
#
# Sourced by BOTH the collector (providers/collect.sh) and the sidebar
# (tmuxopticon.sh) so that neither hardcodes *which* status providers exist.
# This is the seam that makes the status panel extensible: add a provider by
# dropping a directory, never by editing the engine.
#
# A provider is a directory containing a `provider.conf` manifest. Discovery
# scans two roots and merges them:
#
#   $PLUGIN/providers/*/provider.conf              bundled, ships with the repo
#   ~/.config/tmuxopticon/providers.d/*/provider.conf   the user's own, out of repo
#
# The second root is the whole point: a `git pull` on the plugin never touches
# user providers, and adding one needs zero core edits — drop a dir under
# providers.d/, set its flag in pull.conf, done.
#
# Manifest keys (provider.conf — simple key=value, '#' comments allowed):
#   id            cache basename; the puller writes tmp/<id>.cache        (required)
#   title         box heading shown in the sidebar            (default: the id)
#   flag          the pull.conf gate, e.g. UPTIME_ROBOT_PULL_ENABLED      (required)
#   pull          puller script, run as `pull <cachefile>`; relative paths
#                 resolve against the provider dir       (omit for a BYO command)
#   pull_cmd_var  name of a pull.conf variable holding an absolute puller path,
#                 used when the puller lives OUTSIDE the repo (e.g. PRS_PULL_CMD).
#                 Only consulted when `pull` is empty.
#   order         stacking order in the panel, low = top           (default: 50)
#   timeout       hard per-pull timeout in seconds                 (default: 45)
#   throttle_min  minutes to wait between pulls, 0 = every run     (default: 0)
#
# Every puller obeys one contract: invoked as `<puller> <cachefile>`, it writes
# the shared cache format (epoch / state / summary / detail lines) to that path.
# See README.md "Adding a provider".

# Resolve the plugin root + user config dir once (callers may pre-set either).
_PROVIDERS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
TMUXOPTICON_PLUGIN="${TMUXOPTICON_PLUGIN:-$(dirname "$_PROVIDERS_LIB_DIR")}"
TMUXOPTICON_CONFIG_DIR="${TMUXOPTICON_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon}"

manifest_field() { # manifest_field <file> <key> [default] -> the value, trimmed
  local f="$1" k="$2" def="${3:-}" v
  v="$(grep -m1 -E "^[[:space:]]*$k[[:space:]]*=" "$f" 2>/dev/null \
        | sed -E "s/^[[:space:]]*$k[[:space:]]*=[[:space:]]*//; s/[[:space:]]*\$//")"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$def"
}

# Field separator for provider_rows. The ASCII unit separator (0x1F), NOT a tab:
# tab is IFS-whitespace, so `read` would coalesce the two delimiters around an
# empty middle field (e.g. a BYO provider's blank `pull`) and shift every column
# left. 0x1F is non-whitespace, so empty fields survive. Readers must split on it:
#   while IFS=$'\037' read -r order id title flag pull pcv timeout throttle dir
TMUXOPTICON_FS=$'\037'

provider_rows() { # one $TMUXOPTICON_FS-separated row per provider, sorted by order then id:
  #   order · id · title · flag · pull · pull_cmd_var · timeout · throttle_min · dir
  # `pull` is absolutized against the provider dir when it's a relative path.
  # Globs that match nothing expand to the literal pattern; the -r guard drops it.
  local mf dir id title flag pull pcv timeout throttle order fs="$TMUXOPTICON_FS"
  {
    for mf in "$TMUXOPTICON_PLUGIN"/providers/*/provider.conf \
              "$TMUXOPTICON_CONFIG_DIR"/providers.d/*/provider.conf; do
      [ -r "$mf" ] || continue
      dir="$(dirname "$mf")"
      id="$(manifest_field "$mf" id)";    [ -n "$id" ] || continue
      title="$(manifest_field "$mf" title "$id")"
      flag="$(manifest_field "$mf" flag)"
      pull="$(manifest_field "$mf" pull)"
      pcv="$(manifest_field "$mf" pull_cmd_var)"
      timeout="$(manifest_field "$mf" timeout 45)"
      throttle="$(manifest_field "$mf" throttle_min 0)"
      order="$(manifest_field "$mf" order 50)"
      case "$pull" in ''|/*) ;; *) pull="$dir/$pull";; esac   # relative -> provider dir
      printf "%s${fs}%s${fs}%s${fs}%s${fs}%s${fs}%s${fs}%s${fs}%s${fs}%s\n" \
        "$order" "$id" "$title" "$flag" "$pull" "$pcv" "$timeout" "$throttle" "$dir"
    done
  } | sort -t"$fs" -k1,1n -k2,2
}
