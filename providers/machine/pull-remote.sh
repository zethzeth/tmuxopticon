#!/usr/bin/env bash
# pull-remote.sh — the Machine provider, pointed at ANOTHER box.
#
#   pull-remote.sh <cache-file> <ssh-host>
#
# Same table, same legend, same thresholds as the local Machine box — the only
# difference is *whose* /proc was read. The sibling `pull.sh` is deliberately
# self-contained (no sourcing, no helper files, no config: just /proc, /sys and
# process tables), which is what makes this possible: we stream that exact file
# to the host with `bash -s` and run it there. Nothing is installed on the
# remote, and nothing can drift out of sync — the puller running over there is
# this checkout's file, on every tick.
#
# The remote keeps no state: pull.sh writes its cache to a `mktemp` path, we
# `cat` it back over the same ssh channel, and it is deleted.
#
# One provider *directory* per host, not a list of hosts in here: the sidebar
# draws one box per provider, and a box's title, stacking order and enabled-flag
# are manifest fields. Two boxes means two manifests. A provider that wants a
# remote box supplies the host and execs this:
#
#   #!/usr/bin/env bash
#   exec "$PLUGIN/providers/machine/pull-remote.sh" "$1" "myhost"
#
# Cost is one ssh per collector tick, so give the host a ControlMaster /
# ControlPersist block in ~/.ssh/config — that turns a ~1s handshake into a
# ~0.1s reuse. The manifest `timeout` must cover the handshake *plus* pull.sh's
# own sampling window (TMUXOPTICON_MACHINE_SAMPLE, 1s).
#
# bash 3.2 compatible, like the rest of the plugin.

set -u

CACHE="${1:?usage: pull-remote.sh <cache-file> <ssh-host>}"
HOST="${2:?usage: pull-remote.sh <cache-file> <ssh-host>}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
PULLER="$HERE/pull.sh"
CONNECT_TIMEOUT="${TMUXOPTICON_MACHINE_SSH_TIMEOUT:-8}"

# The epoch line is written from the LOCAL clock on purpose. It is the staleness
# marker the sidebar reads ("Last sync: H:MM"), so it has to be measured on the
# same clock as the reader — keeping the remote's `now` would make a box with a
# skewed clock look permanently stale, or permanently fresh, forever.
now="$(date +%s)"
tmp="$CACHE.$$"
errf="$CACHE.err.$$"
trap 'rm -f "$tmp" "$errf" 2>/dev/null' EXIT INT TERM

write() { # write <state> <summary>   [detail lines on stdin]
  { printf '%s\n%s\n%s\n' "$now" "$1" "$2"; cat; } > "$tmp"
  mv -f "$tmp" "$CACHE" 2>/dev/null
}

[ -r "$PULLER" ] || {
  printf 'expected %s\n' "$PULLER" | write err "machine puller missing"
  exit 0
}

# `bash -s -- "$f"` takes the script from stdin (this ssh channel, fed by the
# redirect below) and hands the cache path to it as $1. pull.sh prints nothing
# on stdout, so the only thing coming back down the pipe is the `cat`.
remote='f="$(mktemp -t tmuxopticon-machine.XXXXXX)" || exit 1
bash -s -- "$f" >/dev/null 2>&1; rc=$?
cat "$f" 2>/dev/null
rm -f "$f"
exit $rc'

# BatchMode: this runs from cron, so anything that would prompt must fail rather
# than hang. ConnectTimeout bounds a host that never answers — and the keepalives
# bound the other one, a session that connects and *then* stalls (sleeping
# laptop, dead VPN, wedged host), which ConnectTimeout does nothing about. Both
# are deliberately shorter than the manifest's `timeout`, because that outer
# `timeout` signals this script and leaves the ssh child to linger.
out="$(ssh -o BatchMode=yes -o ConnectTimeout="$CONNECT_TIMEOUT" \
           -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
           "$HOST" "$remote" < "$PULLER" 2>"$errf")"
rc=$?

state="$(printf '%s\n' "$out" | sed -n 2p)"
summary="$(printf '%s\n' "$out" | sed -n 3p)"

# Unreachable is `warn`, NOT `err`, and that is a judgement rather than an
# oversight: `err` paints the full-width red banner, which is for something
# broken. A laptop that is off the VPN, closed-lid or on hotel wifi cannot see
# the host, and that is an ordinary daily state — it should read as "no answer",
# not as an incident. What it must never do is stay silently green on the last
# good reading, which is why it writes a fresh cache instead of just exiting.
if [ "$rc" -ne 0 ] || [ -z "$state" ] || [ -z "$summary" ]; then
  reason="$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -n 1 | sed -e 's/^[[:space:]]*//')"
  [ -n "$reason" ] || reason="no reading from $HOST"
  printf '%s\n' "$reason" | write warn "unreachable"
  exit 0
fi

# Everything from line 4 down is the table, verbatim — this script deliberately
# does not reformat or re-threshold a single row, so the remote box and the
# local one stay readable with one legend (providers/machine/README.md).
printf '%s\n' "$out" | tail -n +4 | write "$state" "$summary"
