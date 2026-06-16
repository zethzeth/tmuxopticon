#!/usr/bin/env bash
# collector-stop.sh — turn the tmuxopticon status collector OFF (the default).
#
# Removes the cron line that runs collect.sh (idempotent) and clears the enable
# flag. With the collector off the sidebar's status panel shows a single
# "⊘ Cron-checker disabled" notice instead of provider boxes. Re-enable any time
# with collector-start.sh.
#
# No sudo: this edits *your* user crontab only.
set -u

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon"
FLAG="$CONFIG_DIR/collector.enabled"
MARKER='# tmuxopticon-collector'

# Only rewrite the crontab when our marker is actually present, so we never clear
# an empty crontab or disturb unrelated lines (grep -vF drops only our tagged one).
if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
  crontab -l 2>/dev/null | grep -vF "$MARKER" | crontab -
  echo "cron:  removed"
else
  echo "cron:  not installed (nothing to remove)"
fi

rm -f "$FLAG"
echo "flag:  cleared  (collector DISABLED)"
echo
echo "The sidebar will show '⊘ Cron-checker disabled' (prefix o twice to refresh)."
