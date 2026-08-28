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
   dwnl    ↓ 660B/s
   upl     ↑   1K/s
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

- **`dwnl` / `upl`** — bytes per second right now, down and up. There is no
  honest "100%" to bar against (link speed isn't knowable), so they're rates —
  and for the same reason they are never coloured. `0 K/s` is not automatically
  healthy and `300 K/s` is not automatically a problem; the row that actually
  judges a link is `lag`, below.
- **`spawn`** — new tasks per second. Same reason.

They take a line each rather than sharing one because direction is half the
diagnosis. Two rates on one row read as a single fact — "the network is doing
240K" — and that is precisely the reading that hides which way it is going. On
a box you are watching over ssh, `upl` is very largely *your own screen*, so a
terminal that cannot keep up looks quite different from a download that cannot.

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
| `dwnl` / `upl` | `/proc/net/dev` delta | Throughput now, down and up, summed over physical interfaces. Loopback, docker, veth, bridges, VPN and tailscale are excluded — a container's traffic also crosses the real NIC, so counting both would double it. |
| `stall` | `/proc/pressure/*` | **Informational, not a verdict — see the warning below.** The percentage of the last 60 seconds that work was *actually lost* waiting for cpu, disk io, or memory. `cpu 100%` with `stall cpu 0` is a machine doing its job; `stall io 40` is a machine you are waiting on. `io` uses the kernel's `full` metric (everything stalled), `cpu` and `mem` use `some` (at least one task stalled). Linux only. |
| `spawn` | `/proc/stat` `processes` delta | New tasks per second. The counter increments on every `clone()`, so threads count too. Shown only above 500/s. Tens per second is normal; thousands is a runaway poll loop — and it is the usual explanation for a box pegged in *system* time while no single process looks busy, because those tasks are far too short-lived for any sampler to catch. |

### `link` and `lag` — the rows about the *connection*, not the box

Every other row answers "is this **box** slow". These two answer the question
the box cannot: **"is the link to it slow"** — and when you are reading the
table over ssh from somewhere else, that is just as often the thing that
actually hurts. A completely idle machine on a lossy path types like treacle,
and every `/proc` reading on it stays green the whole time it happens.

They appear **only when `pull.sh` is running over ssh**, which is exactly what
`pull-remote.sh` arranges for a remote box. Locally `SSH_CONNECTION` is unset,
no socket is inspected, and the rows are simply never drawn.

| What | Reads | Means |
| --- | --- | --- |
| `link` | `ss -ti`, delta | Round-trip time to the client, and the share of bytes retransmitted **during the sample window**. Green under 60 ms and 0.5%; red past 150 ms or 2%. Loss is omitted entirely below 64 KB sent in the window — an idle session sends few enough packets that one retransmit reads as 4%, and a row glowing red about a healthy link is worse than a row that admits it didn't measure enough to have an opinion. |
| `lag` | `ss -ti` Send-Q ÷ delivery rate | **How long your next keystroke waits before its echo can even leave the box.** Green under 50 ms, red past 200 ms. Barred 0–500 ms. |

`lag` is the one to read. Send-Q is every byte the kernel still owes you —
already written by the shell over there, not yet acknowledged over here.
Divided by the rate the path is really delivering, it stops being a volume and
becomes a **time**, and that time is the answer to "why is this terminal
behaving like that". It is also what makes `upl` interpretable: 300 K/s next to
`lag 4ms` is a link doing its job, and 300 K/s next to `lag 800ms` is a link
that has become a queue you are sitting in.

Nothing extra is measured to get any of it. The kernel on the remote side is
already keeping a full TCP record of the connection carrying the reading;
`ss -ti` just hands it over. Loss is a **delta across the sample window** rather
than the socket's lifetime counters, for the usual reason every other rate here
is: a `ControlMaster` socket lives for minutes, and lifetime loss reports a
burst from ten minutes ago as though it were happening now.

A `lag` over 300 ms is the **first** thing that can claim the headline, ahead of
every check about the box itself — `slow: ssh lag 869ms`. That is deliberate,
and it is the one case where a machine whose own readings are perfectly healthy
should still read as slow, because that is the truth of trying to use it.

> **Whose socket?** The ssh connection back to this client with the deepest send
> queue. Under `ControlMaster` the interactive session and the puller are
> usually the *same* TCP connection; where they aren't, the busiest one is the
> one whose backlog your next keystroke would queue behind — which is the thing
> worth measuring. Loss is summed across all of them, since they share a path.

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

## Watching another box

The same table can be drawn for a machine you are *not* sitting at — a dev box,
a build host, a VPS — as its own box in the sidebar, so "is that thing strained
right now?" is a glance instead of an ssh.

`pull-remote.sh <cache-file> <ssh-host>` does it, and installs nothing on the
remote: `pull.sh` is self-contained, so it is streamed over the ssh channel with
`bash -s`, run there, and its cache is `cat` back and deleted. The puller
running on the remote is therefore always this checkout's file — there is no
second copy to keep up to date.

It's one provider directory per host, because a box's title, stacking order and
enable-flag are manifest fields. Drop this under
`~/.config/tmuxopticon/providers.d/machine-<host>/`:

```sh
# provider.conf
id=machine_devbox
title=devbox            # the box heading — name it after the host
flag=MACHINE_DEVBOX_PULL_ENABLED
pull=pull.sh
order=16                # 16 = directly under the local Machine box (15)
timeout=25              # ssh handshake + pull.sh's 1s sampling window
max_lines=0             # same reason as the local box: it's a table
```

```sh
# pull.sh
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
exec "$HERE/../../tmuxopticon/providers/machine/pull-remote.sh" "$1" "devbox"
```

(that relative path assumes the provider dir is a symlink into a repo beside the
plugin — point it at wherever your checkout actually is)

then `MACHINE_DEVBOX_PULL_ENABLED=true` in `pull.conf`. Notes:

- **Give the host a `ControlMaster` block** in `~/.ssh/config`. The collector
  connects once a minute; with `ControlPersist` that is a ~0.1s reuse instead of
  a ~1s handshake.
- **Key auth only.** The puller runs from cron under `BatchMode=yes`, so
  anything that would prompt fails instead of hanging.
- **The epoch is rewritten with the local clock**, so `Last sync` stays honest
  even if the remote's clock is skewed.
- **Unreachable is `warn`, not `err`** — a red dot and the ssh error as the
  detail line, not the full-width red banner. Being off the VPN is an ordinary
  daily state, not an incident. And it is never silently the last good reading.
- The remote reading is only as good as what `pull.sh` can see there: a
  container or a VM without PSI simply draws a shorter table (see **Legend**).

## macOS

Reduced but honest: cpu, memory, disk, and the application rows work. No `stall`
(a Linux kernel feature), no `spawn`, no `net`, and no GPU counter. Temperature
requires `osx-cpu-temp` on `PATH` (Apple's SMC isn't readable unprivileged);
without it the `temp` row is simply omitted.
