#!/usr/bin/env bash
# slack-alarm-watch.sh — poll Slack "alarm" channels as a plain workspace member
# and surface new messages (minus false-alarm filters) into a tiny cache file
# that the tmuxopticon sidebar renders. Built to run from cron once a minute.
#
# Why this exists: I keep Slack's own notifications off, but my boss insists a
# couple of alarm channels stay watched. A user token (xoxp-…) from a small
# internal Slack app lets a non-admin read channel history over the Web API;
# this script does the polling so the alarms show up in my terminal sidebar
# instead of as desktop noise. See guides/slack-alarm-watch.md for the one-time
# Slack-app setup that produces the token.
#
# A tmuxopticon "provider": it feeds the sidebar's Alarms box but, like the rest
# of the plugin, stays self-contained — config and secrets live under
# ~/.config/tmuxopticon/ (next to uptimerobot.key), NOT in the dotfiles repo.
# Copy providers/slack/slack.env.example -> ~/.config/tmuxopticon/slack.env and fill it
# in. With no config file the script is a quiet no-op.
#
# Subcommands:
#   poll      (default) one polling pass — fetch new messages, filter, rewrite
#             the cache. This is what cron runs.
#   test      sanity-check the token + channel config (calls auth.test) and
#             print what's configured. Run this once after setup.
#   list      print the currently-active alarms (what the sidebar shows).
#   clear     acknowledge / clear all active alarms (empties the active store).
#
# Notes / limits:
#   - You must be a *member* of each channel you list (a user token only reads
#     history for channels you're in). Private channels also need groups:history.
#   - One page (up to ~200 msgs) is fetched per channel per pass. At one alarm a
#     minute that's ample; a huge burst in a single minute could drop the middle
#     of the burst (the cursor still advances to the newest seen). Fine for alarms.
#   - "Active" alarms auto-expire after SLACK_ALARM_TTL and can be wiped with
#     `clear`. New, non-filtered messages get appended each pass.
set -u

# Config + secrets live under tmuxopticon's own config dir (kept out of the repo,
# like the Uptime Robot key) — never in a sibling dotfiles file.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon"
ENV_FILE="${SLACK_ALARM_ENV:-$CONFIG_DIR/slack.env}"

# --- config (from slack.env, with defaults) ----------------------------------
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

TOKEN="${SLACK_TOKEN:-}"
CHANNELS="${SLACK_ALARM_CHANNELS:-}"     # space-separated "ID" or "ID:label" tokens
TTL="${SLACK_ALARM_TTL:-86400}"          # seconds an alarm stays "active" (default 24h)
MAX="${SLACK_ALARM_MAX:-50}"             # cap on stored active alarms
IGNORE_FILE="${SLACK_ALARM_IGNORE:-$CONFIG_DIR/slack-alarm-ignore.txt}"
CACHE="${SLACK_ALARM_CACHE:-/tmp/tmuxopticon.alarms.${UID:-0}}"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/slack-alarm-watch"
ACTIVE="$STATE_DIR/active.tsv"           # epoch \t label \t text  (one alarm per line)
LOCK="$STATE_DIR/lock"                   # single-flight guard (a mkdir'd dir)

API='https://slack.com/api'

die() { printf 'slack-alarm-watch: %s\n' "$*" >&2; exit 1; }

now_epoch() { date +%s; }

# Write the cache file the sidebar reads, atomically, in the shared tmuxopticon
# provider format so the renderer draws it like any other provider:
#   line1  epoch (for staleness)   line2  state ok|warn|err   line3  summary
#   then one display line per active alarm, newest first (body kept unless err).
write_cache() { # write_cache <state> <summary> [body-on-stdin]
  local state="$1" summary="$2" tmp="$CACHE.$$"
  { printf '%s\n%s\n%s\n' "$(now_epoch)" "$state" "$summary"; [ "$state" != err ] && cat; } > "$tmp"
  mv -f "$tmp" "$CACHE" 2>/dev/null
}

# Render the active store into the cache (newest first, capped, "HH:MM label text").
# state is warn when any alarm is active (so the sidebar lights it ●), else ok.
refresh_cache() {
  local count body state summary plural
  count="$(wc -l < "$ACTIVE" 2>/dev/null | tr -d ' ')"; count="${count:-0}"
  body="$(sort -t$'\t' -k1,1nr "$ACTIVE" 2>/dev/null | awk -F'\t' '
    { t=strftime("%H:%M", $1+0); lbl=($2=="" ? "" : "#" $2 " ");
      line = t " " lbl $3; if (length(line) > 200) line=substr(line,1,200);
      print line }')"
  if [ "$count" -gt 0 ] 2>/dev/null; then
    state=warn; plural=s; [ "$count" -eq 1 ] && plural=''
    summary="$count alarm$plural"
  else
    state=ok; summary='no alarms'
  fi
  printf '%s' "$body" | write_cache "$state" "$summary"
}

# True if $1 (a message's text) matches any pattern in the ignore file.
is_false_alarm() {
  [ -r "$IGNORE_FILE" ] || return 1
  local text="$1" pat
  while IFS= read -r pat; do
    case "$pat" in ''|'#'*) continue;; esac     # skip blanks + comments
    printf '%s' "$text" | grep -qiE -- "$pat" && return 0
  done < "$IGNORE_FILE"
  return 1
}

# Fetch one channel's new messages (since its stored cursor) and emit, oldest
# first, "epoch<TAB>text" lines for each kept alarm. Advances the cursor.
poll_channel() { # poll_channel <channel-id> <label>
  local ch="$1" label="$2" cursor cfile resp ok ts txt newcur=''
  cfile="$STATE_DIR/cursor.$ch"
  if [ -r "$cfile" ]; then cursor="$(cat "$cfile" 2>/dev/null)"; else cursor=''; fi
  # First time we ever see a channel: start from "now" so we don't dump backlog.
  if [ -z "$cursor" ]; then printf '%s.000000\n' "$(now_epoch)" > "$cfile"; return 0; fi

  resp="$(curl -fsS -m 15 -G "$API/conversations.history" \
            -H "Authorization: Bearer $TOKEN" \
            --data-urlencode "channel=$ch" \
            --data-urlencode "oldest=$cursor" \
            --data-urlencode 'inclusive=false' \
            --data-urlencode 'limit=200' 2>/dev/null)"
  [ -n "$resp" ] || { printf '%s\n' "$cursor" > "$cfile"; return 1; }
  ok="$(printf '%s' "$resp" | jq -r '.ok' 2>/dev/null)"
  if [ "$ok" != true ]; then
    printf '%s\n' "$cursor" > "$cfile"
    printf '%s' "$resp" | jq -r '.error // "api error"' 2>/dev/null >> "$STATE_DIR/last-error"
    return 1
  fi

  # Advance the cursor to the newest message in this page (messages are
  # newest-first, so [0] is newest) — regardless of whether it survives the
  # subtype/false-alarm filters, so we never re-fetch the same page.
  newcur="$(printf '%s' "$resp" | jq -r '.messages[0].ts // empty' 2>/dev/null)"

  # Emit kept alarms oldest-first as "ts<TAB>text". Join/leave/topic noise is
  # dropped inside jq so the @tsv line is exactly two fields — important because
  # IFS=$'\t' collapses an empty middle field (tab is IFS-whitespace), which
  # would otherwise shift text into the wrong variable.
  while IFS=$'\t' read -r ts txt; do
    [ -n "$ts" ] || continue
    # jq @tsv escaped tabs/newlines to literal \t \n — normalise for one-line storage.
    txt="$(printf '%s' "$txt" | sed -E 's/\\[nt]/ /g; s/  +/ /g; s/^ +//; s/ +$//')"
    [ -n "$txt" ] || continue
    is_false_alarm "$txt" && continue
    printf '%s\t%s\n' "${ts%%.*}" "$txt"         # epoch-seconds <TAB> cleaned text
  done < <(printf '%s' "$resp" | jq -r '
            .messages | reverse[]
            | select(((.subtype // "") | test("^channel_(join|leave|topic|purpose|name|archive|unarchive)$")) | not)
            | [.ts, (.text // "")] | @tsv' 2>/dev/null)

  # Persist the advanced cursor (else leave it untouched for the next pass).
  [ -n "$newcur" ] && printf '%s\n' "$newcur" > "$cfile"
  return 0
}

cmd_poll() {
  [ -n "$TOKEN" ] || exit 0                       # not configured yet → quiet no-op for cron
  [ -n "$CHANNELS" ] || exit 0
  command -v jq  >/dev/null 2>&1 || die 'jq not found'
  command -v curl >/dev/null 2>&1 || die 'curl not found'
  mkdir -p "$STATE_DIR"

  # single-flight: a lock older than 5 min is stale (a wedged run) — steal it.
  [ -n "$(find "$LOCK" -prune -mmin +5 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 0
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

  touch "$ACTIVE"
  # Expire alarms older than the TTL (self-cleaning so the box doesn't grow forever).
  local now tmp="$ACTIVE.$$"
  now="$(now_epoch)"
  awk -F'\t' -v now="$now" -v ttl="$TTL" 'now - $1 <= ttl' "$ACTIVE" > "$tmp" 2>/dev/null && mv -f "$tmp" "$ACTIVE"

  # Poll each configured channel; append any new alarms.
  local tok ch label new
  for tok in $CHANNELS; do
    ch="${tok%%:*}"; label="${tok#*:}"; [ "$label" = "$ch" ] && label=''
    new="$(poll_channel "$ch" "$label")"
    if [ -n "$new" ]; then
      # prefix each "epoch<TAB>text" with the channel label → "epoch<TAB>label<TAB>text"
      printf '%s\n' "$new" | awk -F'\t' -v l="$label" 'NF{ print $1 "\t" l "\t" $2 }' >> "$ACTIVE"
    fi
  done

  # Cap to the newest MAX entries, then rewrite the cache.
  if [ "$(wc -l < "$ACTIVE" 2>/dev/null)" -gt "$MAX" ]; then
    sort -t$'\t' -k1,1nr "$ACTIVE" | head -n "$MAX" > "$tmp" && mv -f "$tmp" "$ACTIVE"
  fi
  refresh_cache
}

cmd_test() {
  [ -n "$TOKEN" ] || die "SLACK_TOKEN is empty — set it in $ENV_FILE"
  command -v jq >/dev/null 2>&1 || die 'jq not found'
  local resp ok who team
  resp="$(curl -fsS -m 15 -H "Authorization: Bearer $TOKEN" "$API/auth.test" 2>/dev/null)"
  ok="$(printf '%s' "$resp" | jq -r '.ok' 2>/dev/null)"
  if [ "$ok" != true ]; then
    die "auth.test failed: $(printf '%s' "$resp" | jq -r '.error // "no/blocked response"' 2>/dev/null)"
  fi
  who="$(printf '%s' "$resp" | jq -r '.user' 2>/dev/null)"
  team="$(printf '%s' "$resp" | jq -r '.team' 2>/dev/null)"
  printf 'OK — authenticated as %s in workspace %s\n' "$who" "$team"
  printf 'Channels configured: %s\n' "${CHANNELS:-<none — set SLACK_ALARM_CHANNELS>}"
  printf 'Ignore file: %s%s\n' "$IGNORE_FILE" "$( [ -r "$IGNORE_FILE" ] && echo '' || echo '  (none yet)')"
  printf 'Cache file: %s\n' "$CACHE"
  printf 'Active store: %s\n' "$ACTIVE"
}

cmd_list() {
  [ -r "$ACTIVE" ] || { echo '(no active alarms)'; return 0; }
  sort -t$'\t' -k1,1nr "$ACTIVE" | awk -F'\t' '
    { printf "%s  %s%s\n", strftime("%Y-%m-%d %H:%M", $1+0), ($2=="" ? "" : "#" $2 " "), $3 }'
}

cmd_clear() {
  mkdir -p "$STATE_DIR"; : > "$ACTIVE"
  refresh_cache
  echo 'Cleared active alarms.'
}

case "${1:-poll}" in
  poll)  cmd_poll;;
  test)  cmd_test;;
  list)  cmd_list;;
  clear) cmd_clear;;
  -h|--help|help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//';;
  *) die "unknown command '${1}' (try: poll | test | list | clear)";;
esac
