#!/usr/bin/env bash
# collector-start.sh — turn the tmuxopticon status collector ON.
#
# Installs the once-a-minute cron line that runs collect.sh (idempotent — never
# duplicates it) and drops the enable flag the collector + sidebar both read.
# The collector ships OFF by default; run this once to start it.
#
# crontab entries persist across logins and reboots, so you do NOT run this every
# login — only when you want to (re)enable. Stop again with collector-stop.sh.
#
# No sudo: this edits *your* user crontab only.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"   # providers/
COLLECT="$HERE/collect.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon"
FLAG="$CONFIG_DIR/collector.enabled"
MARKER='# tmuxopticon-collector'                       # tags our line so we never touch others
CRON_LINE="* * * * * $COLLECT >/dev/null 2>&1 $MARKER"

mkdir -p "$CONFIG_DIR"

# Idempotent install: if our marker line is already present, leave it; otherwise
# strip any stale copy and append a fresh one. `crontab -l` errors when the user
# has no crontab yet — 2>/dev/null + empty stdin to the filter handles that.
if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
  echo "cron:  already installed"
else
  { crontab -l 2>/dev/null | grep -vF "$MARKER"; printf '%s\n' "$CRON_LINE"; } | crontab -
  echo "cron:  installed  →  $CRON_LINE"
fi

: > "$FLAG"                                             # presence = ON
echo "flag:  $FLAG  (collector ENABLED)"
echo
echo "The status panel will start filling in within a minute."
echo "Toggle the sidebar off/on (prefix o twice) to refresh its view."
