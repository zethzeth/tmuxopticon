#!/usr/bin/env bash
# pull.sh — tmuxopticon "Machine" provider.
#
# Answers one question: *why does this box feel slow right now?* — as a small
# two-column table rather than prose, because the whole point is to read it at a
# glance without parsing sentences.
#
#   col 1  what   7 chars, left      cpu · mem · gpu · temp · net · stall
#   col 2  level  the rest (~22)     a bar + a number, or a rate
#
# Then a spacer row and the three greediest applications, each tagged with the
# resource it is greedy *on*, so "who is eating this machine" is one glance
# rather than a trip to htop.
#
# Everything is read locally from /proc and /sys — no network, no secret, no
# root. Invoked by the collector as `pull.sh <cachefile>`; writes the shared
# cache format (epoch / state / summary / detail lines). The manifest sets
# max_lines, because the default box cap of 6 detail lines is built for a
# headline-plus-notes provider and this one is a table.
#
# Two of the numbers are *rates*, so the script samples twice around a short
# sleep (SAMPLE, default 1s): CPU busy, network throughput, GPU busy, and the
# per-application CPU figures all come from deltas across that window.
#
# bash 3.2 compatible (macOS ships 3.2.57): no ${var^^}, no mapfile, no
# `declare -A`. LC_ALL=C is set on purpose — printf/awk parse floats through
# strtod, which reads a decimal *comma* under e.g. a Danish locale and would
# silently truncate every float to its integer part.

LC_ALL=C; export LC_ALL
set -u

CACHE="${1:?usage: pull.sh <cache-file>}"
SAMPLE="${TMUXOPTICON_MACHINE_SAMPLE:-1}"   # seconds between the two samples
now="$(date +%s)"
tmp="$CACHE.$$"
snapA="$CACHE.psA.$$"
snapB="$CACHE.psB.$$"
trap 'rm -f "$tmp" "$snapA" "$snapB" 2>/dev/null' EXIT INT TERM

write() { # write <state> <summary>   [detail lines on stdin]
  { printf '%s\n%s\n%s\n' "$now" "$1" "$2"; cat; } > "$tmp"
  mv -f "$tmp" "$CACHE" 2>/dev/null
}

# ---------------------------------------------------------------- small helpers

pct() { # pct <part> <whole> -> integer percent (0 when whole is 0 or junk)
  case "${1:-}${2:-}" in ''|*[!0-9]*) printf '0'; return;; esac
  [ "$2" -gt 0 ] || { printf '0'; return; }
  printf '%s' $(( ($1 * 100 + $2 / 2) / $2 ))
}

gib() { # gib <kB> -> "11.4" under 10 GiB-ish, else "30" (keeps the column narrow)
  awk -v k="${1:-0}" 'BEGIN { g = k / 1048576; if (g < 10) printf "%.1f", g; else printf "%.0f", g }'
}

centi() { # centi <float> -> the value * 100, as an integer (float-free compares)
  awk -v x="${1:-0}" 'BEGIN { printf "%d", x * 100 + 0.5 }'
}

BAR_W=8
bar() { # bar <percent> -> a BAR_W-wide fill gauge; the glanceable half of column 2
  local p="${1:-0}" i=0 f out=''
  case "$p" in ''|*[!0-9]*) p=0;; esac
  [ "$p" -gt 100 ] && p=100
  f=$(( (p * BAR_W + 50) / 100 ))
  while [ "$i" -lt "$BAR_W" ]; do
    if [ "$i" -lt "$f" ]; then out="$out█"; else out="$out░"; fi
    i=$(( i + 1 ))
  done
  printf '%s' "$out"
}

rate() { # rate <bytes-per-second> -> "1.2M/s" / "240K/s" / "12B/s"
  awk -v b="${1:-0}" 'BEGIN {
    if      (b >= 1073741824) printf "%.1fG/s", b / 1073741824
    else if (b >= 1048576)    printf "%.1fM/s", b / 1048576
    else if (b >= 1024)       printf "%.0fK/s", b / 1024
    else                      printf "%dB/s",   b
  }'
}

hwmon_dir() { # hwmon_dir <name-glob> -> first /sys/class/hwmon entry with that name
  local d n
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    n="$(cat "$d/name" 2>/dev/null)"
    # shellcheck disable=SC2254  # the glob is the point
    case "$n" in $1) printf '%s' "$d"; return 0;; esac
  done
  return 1
}

# ------------------------------------------------------------------ platform

if [ -r /proc/stat ]; then OS=linux
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then OS=darwin
else
  printf '%s\n%s\n' \
    'needs /proc (Linux) or macOS' \
    'disable MACHINE_PULL_ENABLED in pull.conf' \
    | write err "unsupported platform: $(uname -s 2>/dev/null || echo unknown)"
  exit 0
fi

# "Set it if we can measure it, leave it empty if we can't" — an empty value
# means the row is not emitted at all, so hardware without a sensor draws a
# shorter table rather than a row of zeros pretending to be a reading.
ncpu=''; load1=''; cpu_busy=''
mem_used_k=''; mem_total_k=''; mem_pct=''; swap_used_k=''; swap_total_k=''
gpu_busy=''; cpu_temp=''
psi_cpu=''; psi_io=''; psi_mem=''
disk_pct=''; net_rx=''; net_tx=''; forks_s=''; swapin_s=''; dev_busy=''
top1=''; top2=''; top3=''

# ------------------------------------------------------------------ collectors

net_bytes() { # -> "rx tx" totalled over physical interfaces
  # Virtual interfaces are excluded because they double-count: traffic through a
  # bridge or a container veth also crosses the real NIC, and loopback isn't
  # network at all.
  #
  # Split on the COLON, never on whitespace-with-fixed-offsets. /proc/net/dev
  # right-pads the interface name to 6 characters, so a short name gets a space
  # before its first counter and a long one (`wlp0s20f3:`) does not — field
  # numbering shifts per interface, and an offset-based parse silently reports
  # packet counts as byte counts. Everything after the colon is the 16 counters,
  # of which #1 is rx bytes and #9 is tx bytes.
  awk '
    NR > 2 {
      p = index($0, ":")
      if (p == 0) next
      name = substr($0, 1, p - 1); gsub(/[ \t]/, "", name)
      if (name ~ /^(lo|docker|veth|br-|virbr|tun|tap|wg|vmnet|tailscale)/) next
      n = split(substr($0, p + 1), f, " ")
      if (n < 16) next
      rx += f[1]; tx += f[9]
    }
    END { printf "%d %d", rx + 0, tx + 0 }
  ' /proc/net/dev 2>/dev/null
}

collect_linux_pre() { # first half of every delta-based reading
  read -r _ s_user s_nice s_sys s_idle s_iow s_irq s_soft s_steal _ < /proc/stat
  pre_total=$(( s_user + s_nice + s_sys + s_idle + s_iow + s_irq + s_soft + s_steal ))
  pre_idle=$(( s_idle + s_iow ))

  # The kernel's fork counter since boot. NB it counts every clone(), so threads
  # land in here alongside processes — call it "task spawns", not "processes".
  # Its delta is the churn rate, and it is the one number that explains a box
  # pegged in system time while no single process looks busy: thousands of
  # short-lived tasks, far too brief for any two-sample PID diff to catch.
  pre_forks="$(awk '/^processes /{ print $2; exit }' /proc/stat)"

  # Pages faulted back IN from swap, and how busy the block device is. These are
  # the two readings that actually track *felt* slowness; see the verdict block
  # for why the io pressure figure alone does not.
  pre_swpin="$(awk '/^pswpin /{ print $2; exit }' /proc/vmstat)"
  pre_devticks="$(awk '{ t += $10 } END { print t + 0 }' /sys/block/nvme*/stat /sys/block/sd*/stat 2>/dev/null)"

  set -- $(net_bytes); pre_rx="${1:-0}"; pre_tx="${2:-0}"

  # Intel (xe) exposes GPU *idle* residency in ms; busy% is what it didn't idle.
  gpu_idle_file=''
  for f in /sys/class/drm/card*/device/tile*/gt*/gtidle/idle_residency_ms; do
    [ -r "$f" ] && { gpu_idle_file="$f"; pre_gpu_idle="$(cat "$f")"; break; }
  done

  proc_snapshot "$snapA"
}

collect_linux_post() { # second half — turn the two samples into rates
  read -r _ s_user s_nice s_sys s_idle s_iow s_irq s_soft s_steal _ < /proc/stat
  local post_total post_idle d_total d_idle post_forks
  post_total=$(( s_user + s_nice + s_sys + s_idle + s_iow + s_irq + s_soft + s_steal ))
  post_idle=$(( s_idle + s_iow ))
  d_total=$(( post_total - pre_total ))
  d_idle=$(( post_idle - pre_idle ))
  [ "$d_total" -gt 0 ] && cpu_busy="$(pct $(( d_total - d_idle )) "$d_total")"

  post_forks="$(awk '/^processes /{ print $2; exit }' /proc/stat)"
  if [ -n "${pre_forks:-}" ] && [ -n "$post_forks" ] && [ "$SAMPLE" -gt 0 ]; then
    forks_s=$(( (post_forks - pre_forks) / SAMPLE ))
    [ "$forks_s" -lt 0 ] && forks_s=''
  fi

  local post_swpin post_devticks
  post_swpin="$(awk '/^pswpin /{ print $2; exit }' /proc/vmstat)"
  if [ -n "${pre_swpin:-}" ] && [ -n "$post_swpin" ] && [ "$SAMPLE" -gt 0 ]; then
    swapin_s=$(( (post_swpin - pre_swpin) / SAMPLE ))
    [ "$swapin_s" -lt 0 ] && swapin_s=''
  fi
  post_devticks="$(awk '{ t += $10 } END { print t + 0 }' /sys/block/nvme*/stat /sys/block/sd*/stat 2>/dev/null)"
  if [ -n "${pre_devticks:-}" ] && [ -n "$post_devticks" ] && [ "$SAMPLE" -gt 0 ]; then
    dev_busy=$(( (post_devticks - pre_devticks) / (10 * SAMPLE) ))   # io_ticks are ms
    [ "$dev_busy" -lt 0 ] && dev_busy=''
    [ -n "$dev_busy" ] && [ "$dev_busy" -gt 100 ] && dev_busy=100
  fi

  local post_rx post_tx
  set -- $(net_bytes); post_rx="${1:-0}"; post_tx="${2:-0}"
  if [ "$SAMPLE" -gt 0 ] && [ "$post_rx" -ge "${pre_rx:-0}" ]; then
    net_rx=$(( (post_rx - pre_rx) / SAMPLE ))
    net_tx=$(( (post_tx - pre_tx) / SAMPLE ))
  fi

  if [ -n "$gpu_idle_file" ]; then
    local d_gpu_idle window_ms busy
    d_gpu_idle=$(( $(cat "$gpu_idle_file") - pre_gpu_idle ))
    window_ms=$(( SAMPLE * 1000 ))
    if [ "$d_gpu_idle" -ge 0 ] && [ "$window_ms" -gt 0 ]; then
      busy=$(( 100 - (d_gpu_idle * 100 / window_ms) ))
      [ "$busy" -lt 0 ] && busy=0
      [ "$busy" -gt 100 ] && busy=100
      gpu_busy="$busy"
    fi
  fi

  proc_snapshot "$snapB"
}

proc_snapshot() { # proc_snapshot <outfile> -> "pid ticks rss_pages comm" per process
  # `cat`, not `awk <glob>`, is load-bearing: processes exit between the glob
  # expanding and the file being opened, and **mawk aborts the entire run** on
  # the first ENOENT (gawk only warns). That silently truncated the snapshot to
  # the low-numbered PIDs, which then made every long-running process look
  # brand-new in the second sample and report its whole lifetime as one second
  # of CPU. `cat` skips what vanished and keeps going.
  #
  # /proc/<pid>/stat field 2 is the comm in parentheses and may itself contain
  # spaces and parens, so slice on the FIRST "(" and the LAST ")" rather than
  # trusting whitespace fields. After that, field N of the remainder is stat
  # field N+2 — utime (14) is f[12], stime (15) is f[13], rss (24) is f[22].
  cat /proc/[0-9]*/stat 2>/dev/null | awk '
    {
      op = index($0, "(")
      cp = 0
      for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ")") { cp = i; break }
      if (op < 2 || cp <= op) next
      n = split(substr($0, cp + 2), f, " ")
      if (n < 22) next
      print substr($0, 1, op - 2), f[12] + f[13], f[22], substr($0, op + 1, cp - op - 1)
    }
  ' > "$1"
}

top_procs() { # fill top1..top3 with "<metric> <name> <value>" for the greediest apps
  local hz pagesize line i=0
  hz="$(getconf CLK_TCK 2>/dev/null)"; case "$hz" in ''|*[!0-9]*) hz=100;; esac
  pagesize="$(getconf PAGESIZE 2>/dev/null)"; case "$pagesize" in ''|*[!0-9]*) pagesize=4096;; esac
  [ -n "$mem_total_k" ] || return 0
  [ -n "$ncpu" ] || return 0

  # Aggregated **by program name**, not by PID: a browser is fifty processes and
  # "which application is eating this machine" is the question being asked, so
  # brave's forty renderers should add up to one row saying "brave".
  #
  # The three rows are picked to guarantee COVERAGE, not just ranking: the
  # biggest CPU consumer, the biggest memory consumer, then whichever of either
  # is next. A pure "top 3 by share of the box" ranking looked right and read
  # badly — RAM is measured against 30 GB while one core is only an eighth of
  # the machine, so on a CPU-pegged box all three rows came back `mem` and the
  # thing actually burning the CPU never appeared.
  #
  # A PID with no baseline in the first snapshot is skipped rather than credited
  # with its lifetime CPU: on a box that forks heavily, PIDs are recycled and a
  # stale read would otherwise print a process at several million percent.
  while read -r line; do
    i=$(( i + 1 ))
    case "$i" in 1) top1="$line";; 2) top2="$line";; 3) top3="$line";; esac
  done <<EOF
$(awk -v iv="$SAMPLE" -v hz="$hz" -v ps="$pagesize" -v ncpu="$ncpu" -v memk="$mem_total_k" '
    function cpuval(n) { return sprintf("%d%%", cpu[n] * 100 / (hz * iv) + 0.5) }
    function memval(n,   mk) {
      mk = rss[n] * ps / 1024
      return (mk >= 10485760) ? sprintf("%dG", mk / 1048576 + 0.5) \
                              : sprintf("%.1fG", mk / 1048576)
    }
    function cpushare(n) { return cpu[n] * 100 / (hz * iv) / ncpu }
    function memshare(n) { return rss[n] * ps / 1024 * 100 / memk }
    function label(n) { gsub(/[ \t]+/, ".", n); return substr(n, 1, 13) }

    NR == FNR { a[$1] = $2; next }
    {
      name = $4
      for (i = 5; i <= NF; i++) name = name " " $i        # comm may contain spaces
      if ($1 in a) { d = $2 - a[$1]; if (d > 0) cpu[name] += d }
      rss[name] += $3
      seen[name] = 1
    }
    END {
      bc = ""; bm = ""
      for (n in seen) {
        if (bc == "" || cpushare(n) > cpushare(bc)) bc = n
        if (bm == "" || memshare(n) > memshare(bm)) bm = n
      }
      if (bc != "" && cpushare(bc) >= 1) print "cpu", label(bc), cpuval(bc)
      if (bm != "" && memshare(bm) >= 1) print "mem", label(bm), memval(bm)

      # Third row: the next biggest of either resource, excluding the two above.
      b3 = ""; b3s = 0; b3m = ""
      for (n in seen) {
        if (n == bc || n == bm) continue
        cs = cpushare(n); ms = memshare(n)
        s  = (cs >= ms) ? cs : ms
        if (s > b3s) { b3s = s; b3 = n; b3m = (cs >= ms) ? "cpu" : "mem" }
      }
      if (b3 != "" && b3s >= 1) print b3m, label(b3), (b3m == "cpu" ? cpuval(b3) : memval(b3))
    }
  ' "$snapA" "$snapB" 2>/dev/null)
EOF
}

collect_linux_static() { # the readings that need no delta
  ncpu="$(nproc 2>/dev/null)"
  case "$ncpu" in ''|*[!0-9]*) ncpu="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)";; esac
  case "$ncpu" in ''|0|*[!0-9]*) ncpu=1;; esac

  read -r load1 _ < /proc/loadavg

  local mt ma st sf
  mt="$(awk '/^MemTotal:/     { print $2; exit }' /proc/meminfo)"
  ma="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)"
  st="$(awk '/^SwapTotal:/    { print $2; exit }' /proc/meminfo)"
  sf="$(awk '/^SwapFree:/     { print $2; exit }' /proc/meminfo)"
  if [ -n "${mt:-}" ] && [ -n "${ma:-}" ]; then
    mem_total_k="$mt"; mem_used_k=$(( mt - ma ))
    mem_pct="$(pct "$mem_used_k" "$mt")"
  fi
  [ -n "${st:-}" ] && [ -n "${sf:-}" ] && { swap_total_k="$st"; swap_used_k=$(( st - sf )); }

  # PSI — the closest thing the kernel has to "did this actually hurt?". `some`
  # is "at least one task stalled", `full` is "everything stalled"; avg60 rides
  # the same one-minute clock as the collector. I/O uses `full` because a single
  # blocked reader is normal, while a fully stalled box is not.
  psi_cpu="$(psi_field /proc/pressure/cpu    some avg60)"
  psi_io="$(psi_field  /proc/pressure/io     full avg60)"
  psi_mem="$(psi_field /proc/pressure/memory some avg60)"

  cpu_temp="$(cpu_temp_c)"
  [ -z "$gpu_busy" ] && gpu_busy="$(gpu_busy_other)"
  disk_usage
}

psi_field() { # psi_field <file> <some|full> <avgN> -> integer percent
  [ -r "$1" ] || return 0
  awk -v want="$2" -v key="$3" '
    $1 == want {
      for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == key) { printf "%d", kv[2] + 0.5; exit } }
    }
  ' "$1" 2>/dev/null
}

milli_c() { # milli_c <file> -> whole degrees C, sanity-checked
  local v
  v="$(cat "$1" 2>/dev/null)" || return 0
  case "$v" in ''|*[!0-9-]*) return 0;; esac
  v=$(( v / 1000 ))
  [ "$v" -gt 0 ] && [ "$v" -lt 150 ] && printf '%s' "$v"
}

cpu_temp_c() { # the CPU package temperature, by decreasing trustworthiness
  local pat d f lbl
  for pat in coretemp k10temp zenpower; do
    d="$(hwmon_dir "$pat")" || continue
    for f in "$d"/temp*_label; do            # prefer the package/die sensor
      [ -r "$f" ] || continue
      lbl="$(cat "$f" 2>/dev/null)"
      case "$lbl" in
        'Package id 0'|Tctl|Tdie) milli_c "${f%_label}_input"; return 0;;
      esac
    done
    milli_c "$d/temp1_input"; return 0
  done
  for f in /sys/class/thermal/thermal_zone*/type; do   # ACPI fallback
    [ -r "$f" ] || continue
    case "$(cat "$f" 2>/dev/null)" in
      x86_pkg_temp|acpitz) milli_c "${f%type}temp"; return 0;;
    esac
  done
}

gpu_busy_other() { # NVIDIA / AMD utilisation, when the Intel idle-delta found none
  local f v
  if command -v nvidia-smi >/dev/null 2>&1; then
    v="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)"
    [ -n "$v" ] && { printf '%d' "$v" 2>/dev/null || true; return 0; }
  fi
  for f in /sys/class/drm/card*/device/gpu_busy_percent; do
    [ -r "$f" ] && { cat "$f" 2>/dev/null; return 0; }
  done
}

disk_usage() { # root filesystem fullness — only ever shown when it's getting real
  local line
  line="$(df -P / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  case "$line" in ''|*[!0-9]*) return 0;; esac
  disk_pct="$line"
}

collect_darwin() { # macOS: same table, fewer sensors (no PSI, no fork rate, no GPU)
  ncpu="$(sysctl -n hw.ncpu 2>/dev/null)"
  case "$ncpu" in ''|*[!0-9]*) ncpu=1;; esac
  load1="$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')"

  local memsize pagesize freepages
  memsize="$(sysctl -n hw.memsize 2>/dev/null)"
  pagesize="$(sysctl -n hw.pagesize 2>/dev/null)"; case "$pagesize" in ''|*[!0-9]*) pagesize=4096;; esac
  if [ -n "${memsize:-}" ]; then
    mem_total_k=$(( memsize / 1024 ))
    freepages="$(vm_stat 2>/dev/null | awk '
      /Pages free/        { gsub(/\./, "", $3); f += $3 }
      /Pages inactive/    { gsub(/\./, "", $3); f += $3 }
      /Pages speculative/ { gsub(/\./, "", $3); f += $3 }
      END { printf "%d", f }')"
    if [ -n "$freepages" ] && [ "$freepages" -gt 0 ] 2>/dev/null; then
      mem_used_k=$(( mem_total_k - (freepages * pagesize / 1024) ))
      mem_pct="$(pct "$mem_used_k" "$mem_total_k")"
    fi
  fi

  cpu_busy="$(top -l 2 -n 0 -s 1 2>/dev/null | awk -F'[ ,%]+' '/^CPU usage/ { u = $3; s = $5 } END { printf "%d", u + s + 0.5 }')"
  case "$cpu_busy" in ''|0) cpu_busy='';; esac

  # No /proc to diff, so lean on ps — its %cpu is a decaying average here rather
  # than the lifetime average Linux reports, which is close enough to useful.
  local p c m i=0
  while read -r p m c; do
    [ -n "${c:-}" ] || continue
    i=$(( i + 1 ))
    line="$(awk -v p="$p" -v m="$m" -v n="$(basename "$c" 2>/dev/null)" -v memk="${mem_total_k:-1}" '
      BEGIN {
        ms = m * 100 / memk
        if (p >= ms) printf "cpu %s %d%%", substr(n, 1, 13), p + 0.5
        else         printf "mem %s %.1fG", substr(n, 1, 13), m / 1048576
      }')"
    case "$i" in 1) top1="$line";; 2) top2="$line";; 3) top3="$line";; esac
  done <<EOF
$(ps -Ao pcpu=,rss=,comm= -r 2>/dev/null | head -3)
EOF

  command -v osx-cpu-temp >/dev/null 2>&1 && \
    cpu_temp="$(osx-cpu-temp 2>/dev/null | awk '{ printf "%d", $1 + 0.5 }')"
  case "${cpu_temp:-}" in ''|0) cpu_temp='';; esac

  disk_usage
}

# ------------------------------------------------------------------- collect

if [ "$OS" = linux ]; then
  collect_linux_pre
  sleep "$SAMPLE"
  collect_linux_post
  collect_linux_static
  top_procs
else
  collect_darwin
fi

# ------------------------------------------------------------ verdict + state

# Three levels, mapped onto the renderer's existing vocabulary:
#   ok   green ○  comfortable
#   info neutral •  working hard, but nothing is actually stalling
#   warn red    ●  degraded — and the summary names the culprit
#
# The warn checks run in priority order and the FIRST hit becomes the headline,
# because "slow: memory 94%" is a diagnosis and "slow" on its own is not. PSI
# leads: it measures time actually lost to waiting, which is what "slow" means.
# A high load average on a dev box is normal and only ever reaches `info`.
state=ok
reason=''
warn_if() { # warn_if <0|1> <reason>
  [ "$1" = 1 ] || return 0
  state=warn; [ -z "$reason" ] && reason="$2"
}
gte() { # gte <a> <b> -> echoes 1 when a >= b, else 0 (empty a = 0)
  case "${1:-}" in ''|*[!0-9]*) printf '0'; return;; esac
  [ "$1" -ge "$2" ] && printf '1' || printf '0'
}

# IO pressure is NOT a warn trigger, and this is the correction of a real
# mistake. `full` means "every non-idle task is stalled" — so the FEWER tasks
# want to run, the easier it is to hit. On an interactive desktop that is mostly
# waiting for you, it inflates: measured on this box at 48% while the machine
# was snappy and every mechanism behind it had just been fixed (swap-out 4339 ->
# 0 pages/s, major faults 480 -> 84/s). It moved the *wrong way* as the machine
# got better, because it got quieter. `some` is no better — it was 56% at the
# same moment. Left in the `stall` row because it is genuinely useful once you
# have a suspect; taken out of the verdict because on its own it cried wolf.
#
# What replaces it is the mechanism, not the symptom: pages being faulted back
# in from swap is what you actually wait for, and a saturated device is what a
# real storage problem looks like. Both are things you can act on.
warn_if "$(gte "$psi_mem" 5)"   "memory stall ${psi_mem}%"
warn_if "$(gte "$swapin_s" 400)" "swap thrash $(( ${swapin_s:-0} * 4 / 1024 ))M/s"
[ "$(gte "$dev_busy" 60)" = 1 ] && warn_if "$(gte "$psi_io" 40)" "disk busy ${dev_busy}%"
warn_if "$(gte "$psi_cpu" 25)"  "cpu stall ${psi_cpu}%"
warn_if "$(gte "$mem_pct" 92)"  "memory ${mem_pct}%"
warn_if "$(gte "$cpu_temp" 90)" "cpu ${cpu_temp}°C"
warn_if "$(gte "$disk_pct" 92)" "disk ${disk_pct}%"

if [ "$state" = ok ]; then
  # Busy-but-fine. Load is compared against core count in hundredths so this
  # stays integer-only: 8 cores at load 8.0 is exactly saturated.
  busy=0
  [ -n "$load1" ] && [ "$(centi "$load1")" -ge $(( ncpu * 100 )) ] && busy=1
  [ "$(gte "$cpu_busy" 85)" = 1 ] && busy=1
  [ "$(gte "$mem_pct"  80)" = 1 ] && busy=1
  [ "$(gte "$cpu_temp" 80)" = 1 ] && busy=1
  [ "$(gte "$disk_pct" 85)" = 1 ] && busy=1
  [ "$(gte "$forks_s" 300)" = 1 ] && busy=1   # a spawn storm is never "idle"
  [ "$busy" = 1 ] && state=info
fi

if [ "$state" = warn ]; then
  summary="slow: $reason"
else
  summary=''
  [ -n "$cpu_busy" ] && summary="cpu ${cpu_busy}%"
  [ -n "$mem_pct"  ] && summary="${summary:+$summary · }mem ${mem_pct}%"
  [ -n "$cpu_temp" ] && summary="${summary:+$summary · }${cpu_temp}°C"
  [ -z "$summary" ] && summary='no readings available'
fi

# -------------------------------------------------------------- the table
#
# Two columns at ~30 usable characters: a 7-wide label, then the level. Rows
# whose numbers are unavailable are skipped entirely.
#
# Deliberately NOT shown by default, because on a developer machine they are
# almost never the reason anything feels slow, and every row costs sidebar
# height that the session list would otherwise use:
#   - disk fullness      slow-moving; surfaces only from 85%
#   - swap in use        alarming-looking and rarely actionable on its own;
#                        surfaces only once memory is actually stalling
#   - NVMe temperature   effectively never the problem
#   - GPU clock speed    a number, not a signal
#   - load average       what people reach for, but `stall cpu` says the same
#                        thing in a form you don't have to divide by core count

details=''
add() { details="${details}${1}
"; }
row() { # row <label> <level…>  — the two-column contract, in one place
  add "$(printf '%-7s %s' "$1" "$2")"
}

# TEMPERATURE is scaled 30°C→100°C rather than 0→100: nothing runs at 0°C, and
# a bar that never leaves its first third is not a gauge, it's decoration.
temp_pct() {
  local t="$1" p
  p=$(( (t - 30) * 100 / 70 ))
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  printf '%s' "$p"
}

[ -n "$cpu_busy" ] && row cpu  "$(bar "$cpu_busy") $(printf '%3s%%' "$cpu_busy")"

if [ -n "$mem_pct" ]; then
  memlvl="$(bar "$mem_pct") $(printf '%3s%%' "$mem_pct")"
  [ -n "$mem_used_k" ] && [ -n "$mem_total_k" ] && \
    memlvl="$memlvl  $(gib "$mem_used_k")/$(gib "$mem_total_k")G"
  row mem "$memlvl"
fi

[ -n "$gpu_busy" ] && row gpu "$(bar "$gpu_busy") $(printf '%3s%%' "$gpu_busy")"

[ -n "$cpu_temp" ] && row temp "$(bar "$(temp_pct "$cpu_temp")") $(printf '%3s' "$cpu_temp")°C"

[ -n "$net_rx" ] && row net "$(printf '↓%7s ↑%7s' "$(rate "$net_rx")" "$(rate "$net_tx")")"

# Swap only earns a row once memory is genuinely under pressure. Swap merely
# being *occupied* is normal — the kernel parks idle pages there and never
# looks back; it only matters when it's the reason you're waiting.
if [ "$(gte "$swapin_s" 50)" = 1 ]; then
  # Actively faulting pages back in — this is the row that means "you are
  # waiting on swap right now", as opposed to swap merely being occupied.
  row swap "$(rate $(( swapin_s * 4096 ))) in$([ -n "${swap_used_k:-}" ] && printf '  %sG out' "$(gib "$swap_used_k")")"
elif [ -n "${swap_used_k:-}" ] && [ "${swap_used_k:-0}" -gt 262144 ] && \
   { [ "$(gte "$psi_mem" 1)" = 1 ] || [ "$(gte "$mem_pct" 85)" = 1 ]; }; then
  row swap "$(gib "$swap_used_k")G paged out"
fi

if [ -n "$psi_cpu" ] || [ -n "$psi_io" ] || [ -n "$psi_mem" ]; then
  # io here is FYI, not a verdict — see the warn block. `dsk` is the device's
  # real utilisation, which is what tells you whether a high io figure means
  # anything: 48% stall with a 7%-busy disk is an idle machine, not a sick one.
  row stall "$(printf 'cpu %-3s io %-3s mem %s' "${psi_cpu:-0}" "${psi_io:-0}" "${psi_mem:-0}")"
  [ -n "$dev_busy" ] && row dsk "$(bar "$dev_busy") $(printf '%3s%%' "$dev_busy") busy"
fi

[ "$(gte "$forks_s" 500)" = 1 ] && row spawn "${forks_s}/s"
[ "$(gte "$disk_pct" 85)" = 1 ] && row disk "$(bar "$disk_pct") $(printf '%3s%%' "$disk_pct")"

# The greediest applications, set apart by a spacer row. Each is tagged with the
# resource it is greedy ON, so the label column keeps its meaning all the way
# down the box — the app name in column 2 is what marks these rows as different.
if [ -n "$top1" ]; then
  add ''
  for t in "$top1" "$top2" "$top3"; do
    [ -n "$t" ] || continue
    set -- $t
    add "$(printf '%-7s %-13s %6s' "$1" "$2" "${3:-}")"
  done
fi

printf '%s' "$details" | write "$state" "$summary"
exit 0
