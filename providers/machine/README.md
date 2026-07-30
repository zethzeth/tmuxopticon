# Machine — local performance box

Answers one question at a glance: **why does this box feel slow right now?**

Unlike the other bundled providers this one touches no network and needs no
secret. It reads `/proc`, `/sys` and process tables, so it works out of the box
on Linux and in reduced form on macOS.

Enable it in `~/.config/tmuxopticon/pull.conf`:

```sh
MACHINE_PULL_ENABLED=true
```

## What it looks like

```
─────────────────────────────────
 Machine
 • cpu 68% · mem 35% · 58°C
   cpu     █████░░░  68%
   mem     ███░░░░░  35%  11/30G
   gpu     █░░░░░░░  13%
   temp    ███░░░░░  58°C
   net     ↓ 660B/s ↑   1K/s
   stall   cpu 8   io 11  mem 0
   spawn   1890/s

   cpu     s1-agent         23%
   mem     chrome          4.3G
   mem     code            1.2G
```

Two columns: a 7-character **what**, then the **level**. Below the spacer, the
same two columns describe *applications* instead of the machine — the resource
each one is greedy on, then its name and its number.

## How to read the level

Wherever a reading is a percentage of something finite, it gets a **bar**. The
bar is the part you read; the number is there when you want precision. A bar
that's a third full means a third of the ceiling is gone, whatever the metric —
so `cpu`, `mem`, `gpu` and `temp` are all comparable at a glance without
reading a single digit.

`temp` is scaled **30°C → 100°C**, not 0 → 100. Nothing runs at 0°C, and a bar
that never leaves its first third is decoration rather than a gauge. A full bar
means you are at the thermal limit and the CPU is throttling itself.

Two levels have no meaningful ceiling, so they show raw values instead:

- **`net`** — bytes per second right now, `↓` down and `↑` up. There is no
  honest "100%" to bar against (link speed isn't knowable), so it's a rate.
- **`spawn`** — new tasks per second. Same reason.

### The one that isn't obvious: `11/30G`

That's **11 GB in use out of 30 GB installed** — the same information as the
`35%` next to it, in absolute terms, for when the question is "can I open
another VM" rather than "am I close to the edge". Read the bar first; the pair
is there for when the percentage isn't enough.

"In use" means `MemTotal − MemAvailable`, so disk cache — which the kernel
hands back the instant anything wants it — is *not* counted as used. This is
the number that matches how much room you actually have, and it is usually much
lower than what `free` or a system monitor reports.

## Legend

### The headline (next to the icon)

| Icon | State | Means |
| --- | --- | --- |
| green `○` | ok | Comfortable. Nothing is near a limit. |
| neutral `•` | info | Working hard — high load, hot, or busy — but nothing is *stalling*. This is a normal state for a dev box mid-build. |
| red `●` | warn | Degraded, and the headline **names the culprit**: `slow: io stall 22%`, `slow: memory 94%`, `slow: cpu 93°C`, `slow: disk 95%`. |

### The machine rows

| What | Reads | Means |
| --- | --- | --- |
| `cpu` | `/proc/stat` delta | Percent of all cores busy over a 1-second sample. Excludes I/O wait — this is real work, not waiting on disk. |
| `mem` | `/proc/meminfo` | Percent of RAM in use, plus used/installed in GB. See above. |
| `gpu` | vendor-specific | GPU busy. NVIDIA via `nvidia-smi`, AMD via `gpu_busy_percent`, Intel Arc / `xe` via the inverse of idle residency. Absent on hardware with no unprivileged counter. |
| `temp` | `coretemp` / `k10temp` / ACPI | CPU package temperature, barred 30–100°C. Sustained 90°C+ means the machine is slow *because* it is hot. |
| `net` | `/proc/net/dev` delta | Throughput now, summed over physical interfaces. Loopback, docker, veth, bridges, VPN and tailscale are excluded — a container's traffic also crosses the real NIC, so counting both would double it. |
| `stall` | `/proc/pressure/*` | **Informational, not a verdict — see the warning below.** The percentage of the last 60 seconds that work was *actually lost* waiting for cpu, disk io, or memory. `cpu 100%` with `stall cpu 0` is a machine doing its job; `stall io 40` is a machine you are waiting on. `io` uses the kernel's `full` metric (everything stalled), `cpu` and `mem` use `some` (at least one task stalled). Linux only. |
| `spawn` | `/proc/stat` `processes` delta | New tasks per second. The counter increments on every `clone()`, so threads count too. Shown only above 500/s. Tens per second is normal; thousands is a runaway poll loop — and it is the usual explanation for a box pegged in *system* time while no single process looks busy, because those tasks are far too short-lived for any sampler to catch. |

### The rows that only appear when they matter

| What | Appears when | Means |
| --- | --- | --- |
| `swap` | memory is stalling, or RAM ≥ 85% | GB of memory pushed out to disk. Swap merely being *occupied* is normal — the kernel parks idle pages there and never looks back — so it stays hidden until it is plausibly the reason you're waiting. |
| `disk` | root filesystem ≥ 85% full | Barred like the others. |
| `dsk` | always, when measurable | How busy the block device actually is (`io_ticks`). This is the row that makes `stall io` interpretable: a high stall next to a near-idle device means nothing is really waiting on storage. |

### The application rows

Three rows under the spacer, each tagged with the resource that application is
greedy on:

| Column | Means |
| --- | --- |
| what | `cpu` or `mem` — which resource this app is topping. |
| name | The **program**, aggregated across all its processes. A browser is fifty processes; this adds them up into one row, because "which application is eating my machine" is the question. |
| value | For `cpu`, percent of **one core** — so 200% means two cores' worth. For `mem`, resident memory in GB. |

They are picked for **coverage, not ranking**: the biggest CPU consumer, the
biggest memory consumer, then whichever is next. A straight "top 3 by share of
the machine" reads badly — RAM is measured against 30 GB while one core is only
an eighth of the box, so on a CPU-pegged machine all three rows came back `mem`
and the thing actually burning the CPU never appeared.

Memory here is RSS, which double-counts memory shared between an application's
processes. It is the standard "how much is this using" figure and the right one
for comparing applications, but don't expect the rows to sum to the `mem` row.

## Thresholds

`warn` (red, and the reason becomes the headline), in priority order:

| Condition | Threshold |
| --- | --- |
| memory stall | `stall` memory ≥ 5% |
| swap thrash | ≥ 400 pages/s faulted back in from swap |
| disk saturated | device ≥ 60% busy **and** `stall` io ≥ 40% |
| cpu stall | `stall` cpu ≥ 25% |
| memory | ≥ 92% used |
| cpu temperature | ≥ 90°C |
| disk | ≥ 92% full |

`info` (busy, not hurting): load ≥ core count, cpu ≥ 85%, memory ≥ 80%,
temperature ≥ 80°C, disk ≥ 85%, or spawns ≥ 300/s. Otherwise `ok`.

## Why `stall io` never turns the box red

It used to, and that was wrong. PSI's `full` means *every non-idle task is
stalled* — so the **fewer** tasks want to run, the easier it is to hit. On an
interactive desktop that spends most of its time waiting for you, it inflates.

Measured here: after fixing a genuine swap-thrashing problem — swap-out went
from 4,339 to **0** pages/s and major faults from ~480 to ~84/s, and the machine
went from sluggish to snappy — `stall io` *rose* from 31% to 48%. It moved the
wrong way precisely because the machine got quieter. `some` was no better: 56%
at the same moment.

So the verdict now watches the **mechanism** instead of the symptom: pages
faulted back in from swap (what you actually wait for) and a genuinely saturated
device (what a real storage problem looks like). `stall io` stays on screen
because it is valuable *once you have a suspect* — just read it next to `dsk`.

## What is deliberately *not* shown

Every row costs sidebar height that the session list would otherwise use, and on
a developer machine these are almost never the reason anything feels slow:

- **load average** — the number everyone reaches for, but `stall cpu` says the
  same thing without needing to be divided by the core count. Still used for the
  `info` verdict, just not displayed.
- **NVMe temperature** — effectively never the problem.
- **GPU clock speed** — a number, not a signal.
- **disk fullness / swap** — kept, but hidden until they cross a threshold
  (above).

## Notes on accuracy

Four numbers are **rates**, so the puller samples twice around a 1-second sleep
(`TMUXOPTICON_MACHINE_SAMPLE` overrides the interval): cpu, net, gpu, and the
per-application cpu figures. The per-application number is deliberately *not*
`ps`'s own `%cpu`, which is a lifetime average — on a box with two weeks of
uptime that happily blames whatever was busy last Tuesday.

The trade-off of a PID diff is that processes which are born *and* die inside
the window are invisible to it. That is not a gap so much as a division of
labour: those are exactly what `spawn` counts.

The whole box is one minute stale at worst, because the collector runs from cron
once a minute and `render` never fetches (see the repo README). For a live view
while you are actively chasing something, reach for `htop` — this box is for
noticing, not for profiling.

## macOS

Reduced but honest: cpu, memory, disk, and the application rows work. No `stall`
(a Linux kernel feature), no `spawn`, no `net`, and no GPU counter. Temperature
requires `osx-cpu-temp` on `PATH` (Apple's SMC isn't readable unprivileged);
without it the `temp` row is simply omitted.
