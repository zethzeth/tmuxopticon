#!/usr/bin/env bash
# pull.sh — tmuxopticon "Machine" provider.
#
# Answers one question in six lines: *why does this box feel slow right now?*
# CPU, memory, GPU, temperature, stall pressure, and the process eating the most
# CPU — all read locally from /proc + /sys (no network, no secret, no root).
#
# Invoked by the collector as `pull.sh <cachefile>` once a minute, and writes the
# shared cache format (epoch / state / summary / detail lines). See
# examples/provider-template/pull.sh for the contract and README.md in this dir
# for what every abbreviation means.
#
# Two of the numbers are *rates*, not instantaneous readings, so this script
# samples twice around a short sleep (SAMPLE, default 1s): CPU busy% comes from a
# /proc/stat delta, and the `top` process comes from a per-PID utime+stime delta.
# The per-PID delta matters — `ps`'s own %cpu is a lifetime average, which on a
# box with 13 days of uptime happily blames whatever was busy last Tuesday.
#
# bash 3.2 compatible (macOS ships 3.2.57): no ${var^^}, no mapfile, no
# `declare -A`. LC_ALL=C is set on purpose — printf/awk parse "7.79" through
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

gib() { # gib <kB> -> "11.4" under 10 GiB-ish, else "30" (keeps the line narrow)
  awk -v k="${1:-0}" 'BEGIN { g = k / 1048576; if (g < 10) printf "%.1f", g; else printf "%.0f", g }'
}

centi() { # centi <float> -> the value * 100, as an integer (float-free compares)
  awk -v x="${1:-0}" 'BEGIN { printf "%d", x * 100 + 0.5 }'
}

round() { # round <float> -> nearest integer
  awk -v x="${1:-0}" 'BEGIN { printf "%d", x + 0.5 }'
}

fmt1() { # fmt1 <float> -> one decimal place ("8.64" -> "8.6"), to keep lines narrow
  awk -v x="${1:-0}" 'BEGIN { printf "%.1f", x }'
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

# /proc is the whole Linux story; macOS gets a reduced (but honest) subset.
if [ -r /proc/stat ]; then OS=linux
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then OS=darwin
else
  printf '%s\n%s\n' \
    'needs /proc (Linux) or macOS' \
    'disable MACHINE_PULL_ENABLED in pull.conf' \
    | write err "unsupported platform: $(uname -s 2>/dev/null || echo unknown)"
  exit 0
fi

# Everything below is "set it if we can measure it, leave it empty if we can't".
# Empty means the corresponding detail line is simply not emitted — a machine
# without a GPU counter or a temperature sensor gets a shorter box, not an error.
ncpu=''; load1=''; cpu_busy=''; iowait=''
mem_used_k=''; mem_total_k=''; mem_pct=''; swap_used_k=''; swap_total_k=''
gpu_busy=''; gpu_mhz=''; gpu_mem=''; gpu_temp=''; forks_s=''
cpu_temp=''; ssd_temp=''
psi_cpu=''; psi_io=''; psi_mem=''
disk_pct=''; disk_mount='/'
top1=''; top2=''

# ------------------------------------------------------------------ collectors

collect_linux_pre() { # first half of every delta-based reading
  # /proc/stat line 1: cpu user nice system idle iowait irq softirq steal ...
  read -r _ s_user s_nice s_sys s_idle s_iow s_irq s_soft s_steal _ < /proc/stat
  pre_total=$(( s_user + s_nice + s_sys + s_idle + s_iow + s_irq + s_soft + s_steal ))
  pre_idle=$(( s_idle + s_iow ))
  pre_iow=$s_iow

  # Total forks since boot. Its delta is the *process churn* rate, and it is the
  # one number that explains a box which is pegged in system time while no single
  # process looks busy: thousands of short-lived processes, each too brief to be
  # caught by any two-sample PID diff (including the one below).
  pre_forks="$(awk '/^processes /{ print $2; exit }' /proc/stat)"

  # Intel (xe) exposes GPU *idle* residency in ms; busy% is what it didn't idle.
  gpu_idle_file=''
  for f in /sys/class/drm/card*/device/tile*/gt*/gtidle/idle_residency_ms; do
    [ -r "$f" ] && { gpu_idle_file="$f"; pre_gpu_idle="$(cat "$f")"; break; }
  done

  # Per-PID CPU time, for the "who is eating the CPU" line.
  proc_snapshot "$snapA"
}

collect_linux_post() { # second half — turn the two samples into rates
  read -r _ s_user s_nice s_sys s_idle s_iow s_irq s_soft s_steal _ < /proc/stat
  local post_total post_idle d_total d_idle d_iow
  post_total=$(( s_user + s_nice + s_sys + s_idle + s_iow + s_irq + s_soft + s_steal ))
  post_idle=$(( s_idle + s_iow ))
  d_total=$(( post_total - pre_total ))
  d_idle=$(( post_idle - pre_idle ))
  d_iow=$(( s_iow - pre_iow ))
  if [ "$d_total" -gt 0 ]; then
    cpu_busy="$(pct $(( d_total - d_idle )) "$d_total")"
    iowait="$(pct "$d_iow" "$d_total")"
  fi

  local post_forks
  post_forks="$(awk '/^processes /{ print $2; exit }' /proc/stat)"
  if [ -n "${pre_forks:-}" ] && [ -n "$post_forks" ] && [ "$SAMPLE" -gt 0 ]; then
    forks_s=$(( (post_forks - pre_forks) / SAMPLE ))
    [ "$forks_s" -lt 0 ] && forks_s=''
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
  top_procs
}

proc_snapshot() { # proc_snapshot <outfile> -> "pid ticks comm" for every process
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
  # field N+2 — so utime (14) is f[12] and stime (15) is f[13].
  cat /proc/[0-9]*/stat 2>/dev/null | awk '
    {
      op = index($0, "(")
      cp = 0
      for (i = length($0); i > 0; i--) if (substr($0, i, 1) == ")") { cp = i; break }
      if (op < 2 || cp <= op) next
      n = split(substr($0, cp + 2), f, " ")
      if (n < 13) next
      print substr($0, 1, op - 2), f[12] + f[13], substr($0, op + 1, cp - op - 1)
    }
  ' > "$1"
}

top_procs() { # fill top1/top2 from the two per-PID snapshots
  local hz line
  hz="$(getconf CLK_TCK 2>/dev/null)"; case "$hz" in ''|*[!0-9]*) hz=100;; esac
  # A PID with no baseline in the first snapshot is skipped rather than credited
  # with its lifetime CPU: on a box that forks heavily, PIDs are recycled and a
  # stale/short read would otherwise print a process at several million percent.
  # Processes that live and die entirely inside the window are invisible to any
  # PID diff — that is precisely what the fork-rate reading covers.
  # Below 5% of one core isn't worth a line.
  local i=0
  while read -r line; do
    i=$(( i + 1 ))
    case "$i" in 1) top1="$line";; 2) top2="$line";; esac
  done <<EOF
$(awk -v iv="$SAMPLE" -v hz="$hz" '
    NR == FNR { a[$1] = $2; next }
    {
      if (!($1 in a)) next
      d = $2 - a[$1]
      if (d <= 0) next
      p = d * 100 / (hz * iv)
      if (p < 5) next
      printf "%d %s\n", p + 0.5, substr($3, 1, 8)
    }
  ' "$snapA" "$snapB" 2>/dev/null | sort -rn | head -2)
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
  ssd_temp="$(hwmon_temp_c nvme)"

  gpu_extras
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

hwmon_temp_c() { # hwmon_temp_c <name-glob> -> temp1_input of that chip, in C
  local d
  d="$(hwmon_dir "$1")" || return 0
  milli_c "$d/temp1_input"
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

gpu_extras() { # GPU utilisation/clock/temp, from whichever vendor is present
  local f v
  # NVIDIA: one query answers everything, so it wins outright.
  if command -v nvidia-smi >/dev/null 2>&1; then
    v="$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu \
           --format=csv,noheader,nounits 2>/dev/null | head -1)"
    if [ -n "$v" ]; then
      gpu_busy="$(printf '%s' "$v" | awk -F', *' '{ printf "%d", $1 + 0.5 }')"
      gpu_mem="$(printf '%s' "$v" | awk -F', *' '{ printf "%.1f/%.0fG", $2/1024, $3/1024 }')"
      gpu_temp="$(printf '%s' "$v" | awk -F', *' '{ printf "%d", $4 + 0.5 }')"
      return 0
    fi
  fi
  # AMD: a ready-made busy percentage.
  if [ -z "$gpu_busy" ]; then
    for f in /sys/class/drm/card*/device/gpu_busy_percent; do
      [ -r "$f" ] && { gpu_busy="$(cat "$f" 2>/dev/null)"; break; }
    done
  fi
  # Intel Arc / xe: the busy% came from the idle-residency delta above; the
  # current clock is a useful companion (pinned at min_freq = genuinely idle).
  # It reads 0 while the render engine is powered down, which is not a clock
  # speed — drop it rather than print "0MHz".
  for f in /sys/class/drm/card*/device/tile*/gt*/freq0/act_freq; do
    [ -r "$f" ] || continue
    v="$(cat "$f" 2>/dev/null)"
    case "$v" in ''|0|*[!0-9]*) ;; *) gpu_mhz="$v";; esac
    break
  done
  # AMD/NVIDIA hwmon temp, when we didn't already get one from nvidia-smi.
  [ -z "$gpu_temp" ] && gpu_temp="$(hwmon_temp_c 'amdgpu')"
}

disk_usage() { # root filesystem fullness — the other classic "why is it broken"
  local line
  line="$(df -P / 2>/dev/null | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
  case "$line" in ''|*[!0-9]*) return 0;; esac
  disk_pct="$line"
}

collect_darwin() { # macOS: same shape, fewer sensors (no PSI, no free GPU counter)
  ncpu="$(sysctl -n hw.ncpu 2>/dev/null)"
  case "$ncpu" in ''|*[!0-9]*) ncpu=1;; esac
  load1="$(sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }')"

  local memsize pagesize
  memsize="$(sysctl -n hw.memsize 2>/dev/null)"
  pagesize="$(sysctl -n hw.pagesize 2>/dev/null)"; case "$pagesize" in ''|*[!0-9]*) pagesize=4096;; esac
  if [ -n "${memsize:-}" ]; then
    mem_total_k=$(( memsize / 1024 ))
    # "Available" on macOS ~= free + inactive + speculative pages.
    local freepages
    freepages="$(vm_stat 2>/dev/null | awk -v ps="$pagesize" '
      /Pages free/          { gsub(/\./, "", $3); f += $3 }
      /Pages inactive/      { gsub(/\./, "", $3); f += $3 }
      /Pages speculative/   { gsub(/\./, "", $3); f += $3 }
      END { printf "%d", f }')"
    if [ -n "$freepages" ] && [ "$freepages" -gt 0 ] 2>/dev/null; then
      mem_used_k=$(( mem_total_k - (freepages * pagesize / 1024) ))
      mem_pct="$(pct "$mem_used_k" "$mem_total_k")"
    fi
  fi

  # CPU busy: `ps` totals are lifetime averages here too, but macOS has no
  # /proc to diff, so take the top-of-list reading `top` already computes.
  cpu_busy="$(top -l 2 -n 0 -s 1 2>/dev/null | awk -F'[ ,%]+' '/^CPU usage/ { u = $3; s = $5 } END { printf "%d", u + s + 0.5 }')"
  case "$cpu_busy" in ''|0) cpu_busy='';; esac

  local line p c i=0
  while read -r p c; do
    i=$(( i + 1 ))
    line="$(printf '%s %s' "$(round "$p")" "$(basename "$c" 2>/dev/null | cut -c1-8)")"
    case "$i" in 1) top1="$line";; 2) top2="$line";; esac
  done <<EOF
$(ps -Ao pcpu=,comm= -r 2>/dev/null | head -2)
EOF

  # Temperature needs a helper (Apple's SMC isn't readable unprivileged).
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
warn_if() { # warn_if <condition-already-evaluated:0|1> <reason>
  [ "$1" = 1 ] || return 0
  state=warn; [ -z "$reason" ] && reason="$2"
}
gte() { # gte <a> <b> -> echoes 1 when a >= b, else 0 (empty a = 0)
  case "${1:-}" in ''|*[!0-9]*) printf '0'; return;; esac
  [ "$1" -ge "$2" ] && printf '1' || printf '0'
}

mem_avail_pct=''
[ -n "$mem_pct" ] && mem_avail_pct=$(( 100 - mem_pct ))

warn_if "$(gte "$psi_mem" 5)"   "memory stall ${psi_mem}%"
warn_if "$(gte "$psi_io" 15)"   "io stall ${psi_io}%"
warn_if "$(gte "$psi_cpu" 25)"  "cpu stall ${psi_cpu}%"
[ -n "$mem_avail_pct" ] && warn_if "$(gte $(( 100 - mem_avail_pct )) 92)" "memory ${mem_pct}%"
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
  [ "$(gte "$forks_s" 300)" = 1 ] && busy=1   # a fork storm is never "idle"
  [ "$busy" = 1 ] && state=info
fi

# ------------------------------------------------------------------- summary

if [ "$state" = warn ]; then
  summary="slow: $reason"
else
  summary=''
  [ -n "$cpu_busy" ] && summary="cpu ${cpu_busy}%"
  [ -n "$mem_pct"  ] && summary="${summary:+$summary · }mem ${mem_pct}%"
  [ -n "$cpu_temp" ] && summary="${summary:+$summary · }${cpu_temp}°C"
  [ -z "$summary" ] && summary='no readings available'
fi

# -------------------------------------------------------------- detail lines
#
# Six lines max (the renderer caps there) at ~30 columns each, in the order you
# want them when something is wrong: what's loaded, what's full, what's hot,
# what's stalling, and who's to blame. Every line is skipped when its numbers
# are unavailable, so a box with no sensors just gets a shorter panel.

details=''
add() { details="${details}${1}
"; }

line=''
[ -n "$cpu_busy" ] && line="cpu ${cpu_busy}%"
[ -n "$load1" ] && line="${line:+$line  }load $(fmt1 "$load1")/${ncpu}"
# Process churn only earns space on the line when it's actually abnormal. A
# handful of forks a second is every shell prompt on earth; hundreds is a
# runaway poll loop, and it's the difference between "busy" and "thrashing".
[ "$(gte "$forks_s" 100)" = 1 ] && line="${line:+$line }· ${forks_s}f/s"
[ -n "$line" ] && add "$line"

line=''
if [ -n "$mem_used_k" ] && [ -n "$mem_total_k" ]; then
  line="mem $(gib "$mem_used_k")/$(gib "$mem_total_k")G"
fi
if [ -n "${swap_used_k:-}" ] && [ "${swap_used_k:-0}" -gt 262144 ]; then   # >256 MiB
  line="${line:+$line · }swap $(gib "$swap_used_k")G"
fi
[ -n "$line" ] && add "$line"

line=''
[ -n "$gpu_busy" ] && line="gpu ${gpu_busy}%"
[ -n "$gpu_mem"  ] && line="${line:+$line · }${gpu_mem}"
[ -n "$gpu_mhz" ] && [ -z "$gpu_mem" ] && line="${line:+$line · }${gpu_mhz}MHz"
[ -n "$gpu_temp" ] && line="${line:+$line · }${gpu_temp}°C"
[ -n "$line" ] && add "$line"

line=''
[ -n "$cpu_temp" ] && line="tmp cpu ${cpu_temp}°"
[ -n "$ssd_temp" ] && line="${line:+$line · }ssd ${ssd_temp}°"
[ -n "$line" ] && add "$line"

line=''
if [ -n "$psi_cpu" ] || [ -n "$psi_io" ] || [ -n "$psi_mem" ]; then
  line="psi c${psi_cpu:-0} i${psi_io:-0} m${psi_mem:-0}"
elif [ -n "$iowait" ]; then
  line="iowait ${iowait}%"          # macOS/older kernels: no PSI, so show this
fi
[ -n "$disk_pct" ] && line="${line:+$line · }dsk ${disk_pct}%"
[ -n "$line" ] && add "$line"

# `top` lines arrive as "<pct> <name>"; flip them so the number reads as a value.
fmt_top() { set -- $1; [ -n "${2:-}" ] && printf '%s %s%%' "$2" "$1"; }
line=''
[ -n "$top1" ] && line="top $(fmt_top "$top1")"
[ -n "$top2" ] && line="${line:+$line · }$(fmt_top "$top2")"
[ -n "$line" ] && add "$line"

printf '%s' "$details" | write "$state" "$summary"
exit 0
