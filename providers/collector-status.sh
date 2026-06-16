#!/usr/bin/env bash
# collector-status.sh — at-a-glance health of the tmuxopticon status collector.
#
# Prints whether the collector is enabled (the flag + the cron line), then for
# every cache in tmp/: how long ago it was written and its first lines (epoch /
# state / summary), so you can tell which providers are refreshing and what they
# last reported — without digging through the cache files by hand.
#
#   providers/collector-status.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"   # providers/
PLUGIN="$(dirname "$HERE")"                                                # tmuxopticon/
TMP="$PLUGIN/tmp"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon"
FLAG="$CONFIG_DIR/collector.enabled"
MARKER='# tmuxopticon-collector'

# Portable helpers (Linux/GNU first, macOS/BSD fallback).
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
human()      { date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }

# --- switch state ------------------------------------------------------------
if [ -e "$FLAG" ]; then echo "collector:  ENABLED   (flag $FLAG)"
else                    echo "collector:  disabled  (no flag at $FLAG)"; fi

if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
  echo "cron line:  installed"
else
  echo "cron line:  NOT installed  (run collector-start.sh)"
fi

# --- caches ------------------------------------------------------------------
echo
echo "caches in $TMP:"
shopt -s nullglob
caches=("$TMP"/*.cache)
if [ "${#caches[@]}" -eq 0 ]; then
  echo "  (none yet — nothing has been pulled)"
  exit 0
fi

now="$(date +%s)"
for c in "${caches[@]}"; do
  name="$(basename "$c")"
  mtime="$(file_mtime "$c")"
  if [ -n "$mtime" ]; then age="$(( now - mtime ))s ago"; else age='?'; fi
  # First three lines are the shared cache shape: epoch / state / summary.
  epoch=''; state=''; summary=''
  { IFS= read -r epoch; IFS= read -r state; IFS= read -r summary; } < "$c" 2>/dev/null
  case "$epoch" in ''|*[!0-9]*) pulled='(no epoch)';; *) pulled="$(human "$epoch")  ($(( now - epoch ))s ago)";; esac
  printf '\n  %-22s written %s\n' "$name" "$age"
  printf '      state:   %s\n' "${state:-?}"
  printf '      summary: %s\n' "${summary:-?}"
  printf '      pulled:  %s\n' "$pulled"
done
