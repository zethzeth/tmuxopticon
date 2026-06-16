#!/usr/bin/env bash
# collector-run.sh — run the status collector ONCE, right now, on demand.
#
# Same work cron does every minute (collect.sh), but synchronous and with
# feedback — for when you just changed something and don't want to wait for the
# next tick to see the sidebar catch up. Runs with `--force`, so it refreshes
# even if the collector is currently stopped (an explicit manual run beats the
# on/off flag). collect.sh's own single-flight lock + per-puller timeouts still
# apply, so this can't stack on top of a cron run mid-flight.
#
# No sudo, no cron changes — this just executes the pullers once.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"   # providers/
PLUGIN="$(dirname "$HERE")"                                                # tmuxopticon/
TMP="$PLUGIN/tmp"

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

echo "Running the tmuxopticon collector once…"
"$HERE/collect.sh" --force
echo "Done."

# Show what got refreshed so you can confirm the pull actually landed.
shopt -s nullglob
caches=("$TMP"/*.cache)
if [ "${#caches[@]}" -eq 0 ]; then
  echo "(no caches yet — is a provider enabled in ~/.config/tmuxopticon/pull.conf?)"
  exit 0
fi

now="$(date +%s)"
echo
echo "caches in $TMP:"
for c in "${caches[@]}"; do
  mtime="$(file_mtime "$c")"
  if [ -n "$mtime" ]; then age="$(( now - mtime ))s ago"; else age='?'; fi
  printf '  %-22s written %s\n' "$(basename "$c")" "$age"
done
echo
echo "Toggle the sidebar off/on (prefix o twice) to redraw it now."
