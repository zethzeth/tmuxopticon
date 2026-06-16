#!/usr/bin/env bash
# pull.sh — a tmuxopticon provider puller (template).
#
# The collector invokes this as `pull.sh <cachefile>` once a minute (subject to
# the manifest's throttle_min) and gives it a hard timeout. Do your fetch, then
# write the SHARED CACHE FORMAT to $1 — atomically, so the sidebar never reads a
# half-written file. The render loop only ever reads this cache; it never fetches.
#
# Cache format:
#   line1  epoch        UNIX time of this pull          (staleness check)
#   line2  state        ok | info | warn | err
#   line3  summary      one-line headline next to the icon
#   line4+ detail lines dimmed, indented (do NOT prepend spaces — render indents)
#
# State -> icon:  ok = green ○ · info = neutral • (a count/FYI, never red) ·
#                 warn = red ● · err = a loud full-width red banner.
set -u

CACHE="${1:?usage: pull.sh <cache-file>}"
now="$(date +%s)"
tmp="$CACHE.$$"

write() { # write <state> <summary>   [detail lines on stdin]
  { printf '%s\n%s\n%s\n' "$now" "$1" "$2"; cat; } > "$tmp"
  mv -f "$tmp" "$CACHE" 2>/dev/null
}

# --- replace everything below with your real check ---------------------------
# Example: report OK with a couple of detail lines.
printf '%s\n%s\n' 'first detail line' 'second detail line' | write ok 'all good'
