#!/usr/bin/env bash
# collect.sh — tmuxopticon's status collector. Runs once a minute from cron,
# reads ~/.config/tmuxopticon/pull.conf, and for each ENABLED provider runs its
# puller, which overwrites a cache file in tmuxopticon's tmp/ folder. The sidebar
# render loop only ever *reads* those caches, so the network never blocks a redraw.
#
# Install (paste via `crontab -e`):
#   * * * * * /path/to/tmuxopticon/providers/collect.sh >/dev/null 2>&1
#
# Which providers exist is NOT hardcoded here — it comes from the registry
# (lib/providers.sh): every directory with a provider.conf, both bundled
# (providers/*/) and user-supplied (~/.config/tmuxopticon/providers.d/*/). To add
# a provider, drop a dir + manifest and set its flag in pull.conf; this file does
# not change. With no pull.conf this is a quiet no-op.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"   # providers/
PLUGIN="$(dirname "$HERE")"                                                # tmuxopticon/
TMP="$PLUGIN/tmp"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon"
CONF="$CONFIG_DIR/pull.conf"

# cron's PATH is minimal — make sure the tools the pullers need resolve.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# The registry (provider discovery). It self-derives the plugin root from its own
# location, but we're already sure of it — pass it through to skip the guesswork.
TMUXOPTICON_PLUGIN="$PLUGIN"
# shellcheck source=../lib/providers.sh
. "$PLUGIN/lib/providers.sh"

# Master on/off switch (providers/collector-start.sh / collector-stop.sh write it).
# Absent flag = OFF, which is the shipped default — bail before doing any work so a
# leftover cron line can't keep pulling once you've stopped the collector.
# `--force` (collector-run.sh's on-demand refresh) bypasses the flag: a manual run
# is explicit intent, so honour it even when the collector is otherwise stopped.
if [ "${1:-}" != "--force" ]; then
  [ -e "$CONFIG_DIR/collector.enabled" ] || exit 0
fi

[ -r "$CONF" ] || exit 0
mkdir -p "$TMP"

# Trusted, user-owned config (like slack.env) — source it for the *_PULL_ENABLED
# flags + any *_CMD vars (e.g. PRS_PULL_CMD). Short-lived process, so sourcing is
# fine here (the render loop, which must not pollute its env, greps it instead).
# shellcheck disable=SC1090
. "$CONF"

# single-flight: don't stack a new minute's run on top of a wedged one.
LOCK="$TMP/.collect.lock"
[ -n "$(find "$LOCK" -prune -mmin +5 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# Walk the registry. For each provider that pull.conf has enabled, run its puller
# into tmp/<id>.cache under a hard timeout. `throttle_min` (minutes between pulls)
# generalizes what used to be a bespoke PR special-case — the stamp records every
# *attempt*, so a rate-limited failure still backs off the full window instead of
# hammering each minute. `--force` bypasses every throttle.
force=''; [ "${1:-}" = "--force" ] && force=1
while IFS=$'\037' read -r order id title flag pull pcv timeout throttle dir; do
  [ -n "$id" ] && [ -n "$flag" ] || continue
  [ "${!flag:-}" = true ] || continue              # gated off in pull.conf -> skip

  # Resolve the puller: a bundled script (`pull`), else an external command named
  # by a pull.conf var (`pull_cmd_var`, e.g. PRS_PULL_CMD -> /abs/path).
  cmd="$pull"
  [ -z "$cmd" ] && [ -n "$pcv" ] && cmd="${!pcv:-}"
  [ -n "$cmd" ] && [ -x "$cmd" ] || continue        # nothing runnable -> stay silent

  # throttle: skip if the last attempt is younger than throttle_min (unless --force).
  case "$throttle" in ''|*[!0-9]*) throttle=0;; esac
  if [ "$throttle" -gt 0 ]; then
    stamp="$TMP/.$id.lastrun"
    if [ -z "$force" ] && [ -e "$stamp" ] && [ -z "$(find "$stamp" -mmin +"$throttle" 2>/dev/null)" ]; then
      continue
    fi
    touch "$stamp"
  fi

  case "$timeout" in ''|*[!0-9]*) timeout=45;; esac
  timeout "$timeout" "$cmd" "$TMP/$id.cache"
done < <(provider_rows)

exit 0
