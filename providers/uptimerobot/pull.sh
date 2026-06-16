#!/usr/bin/env bash
# pull.sh (uptimerobot provider) — fetch Uptime Robot's down/seems-down monitors and write
# them to a tmuxopticon cache file. A "provider": run off-clock by the collector
# (providers/collect.sh, from cron), never from the sidebar's render loop.
#
#   pull.sh <cache-file>
#
# Reads a read-only API key from ~/.config/tmuxopticon/uptimerobot.key (override
# with UPTIME_ROBOT_KEYFILE). Get one from Uptime Robot → Integrations → API:
#   mkdir -p ~/.config/tmuxopticon
#   echo 'u123456-abc…' > ~/.config/tmuxopticon/uptimerobot.key
#
# Cache format (the shared tmuxopticon provider shape):
#   line1  epoch          (for staleness)
#   line2  state          ok | warn | err
#   line3  summary        headline shown next to the icon
#   line4+ detail lines   one down-monitor name each (or a hint on err)
# Written atomically (tmp + mv) so the renderer never sees a half-written file.
set -u

CACHE="${1:?usage: pull.sh <cache-file>}"
KEYFILE="${UPTIME_ROBOT_KEYFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon/uptimerobot.key}"

now="$(date +%s)"
tmp="$CACHE.$$"

write() { # write <state> <summary> [detail-lines-on-stdin]
  { printf '%s\n%s\n%s\n' "$now" "$1" "$2"; cat; } > "$tmp"
  mv -f "$tmp" "$CACHE" 2>/dev/null
}

# No key → say so (with the expected path) instead of failing silently.
key=''
if [ -r "$KEYFILE" ]; then
  key="$(grep -m1 -E '^[[:space:]]*[^#[:space:]]' "$KEYFILE" 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$key" ]; then
  disp="$KEYFILE"; case "$disp" in "$HOME"/*) disp="~${disp#"$HOME"}";; esac
  printf '%s\n' "$disp" | write err 'no API key'
  exit 0
fi

# statuses=8-9 is "seems down" + "down" — only the unresolved issues.
resp="$(curl -fsS -m 10 -X POST https://api.uptimerobot.com/v2/getMonitors \
          -d "api_key=$key" -d 'format=json' -d 'statuses=8-9' 2>/dev/null)"

if [ -z "$resp" ]; then
  : | write err 'no response'
elif ! printf '%s' "$resp" | jq -e '.stat=="ok"' >/dev/null 2>&1; then
  msg="$(printf '%s' "$resp" | jq -r '.error.message // "api error"' 2>/dev/null)"
  : | write err "${msg:-api error}"
else
  count="$(printf '%s' "$resp" | jq -r '.monitors | length' 2>/dev/null)"
  case "$count" in ''|*[!0-9]*) count=0;; esac
  if [ "$count" -eq 0 ]; then
    : | write ok 'all systems up'
  else
    printf '%s' "$resp" | jq -r '.monitors[].friendly_name' 2>/dev/null \
      | write warn "$count down"
  fi
fi
