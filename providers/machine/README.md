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
 • cpu 80% · mem 37% · 59°C
   cpu 80%  load 9.2/8 · 1966f/s
   mem 11/30G · swap 11G
   gpu 17% · 800MHz
   tmp cpu 59° · ssd 49°
   psi c18 i5 m0 · dsk 16%
   top s1-agent 36% · ghostty 20%
```

## Legend

The box is deliberately terse — 30-odd columns per line. Here is every
abbreviation.

### The headline (next to the icon)

| Icon | State | Means |
| --- | --- | --- |
| green `○` | ok | Comfortable. Nothing is near a limit. |
| neutral `•` | info | Working hard — high load, hot, or busy — but nothing is *stalling*. This is a normal state for a dev box mid-build. |
| red `●` | warn | Degraded, and the headline **names the culprit**: `slow: io stall 22%`, `slow: memory 94%`, `slow: cpu 93°C`, `slow: disk 95%`. |

When the state is `ok` or `info` the headline is just the three numbers you
check first: `cpu 80% · mem 37% · 59°C`.

### The detail lines

| Field | Reads | Means |
| --- | --- | --- |
| `cpu 80%` | `/proc/stat` delta | Percent of all cores busy over a 1-second sample. Excludes I/O wait — this is real work, not waiting on disk. |
| `load 9.2/8` | `/proc/loadavg` | 1-minute load average over core count. Above 1:1 means more runnable work than cores. Unlike `cpu%` it counts tasks blocked on disk too. |
| `1966f/s` | `/proc/stat` `processes` delta | **Task spawns per second.** The kernel's fork counter increments on every `clone()`, so this counts new *threads* as well as new processes. Only shown above 100/s. Tens per second is normal; hundreds or thousands is a runaway poll loop, and it is the usual explanation for a box pegged in *system* time while no single process looks busy — those tasks are far too short-lived for any sampler to attribute. |
| `mem 11/30G` | `/proc/meminfo` | Used / total RAM, where "used" is `MemTotal - MemAvailable` (so cache that can be reclaimed doesn't count as used). |
| `swap 11G` | `/proc/meminfo` | Swap in use. Only shown above 256 MiB. Swap being *used* is fine; swap growing while memory pressure rises is not. |
| `gpu 17%` | vendor-specific | GPU busy. NVIDIA via `nvidia-smi`, AMD via `gpu_busy_percent`, Intel Arc / `xe` via the inverse of idle residency. Absent on hardware with no unprivileged counter. |
| `800MHz` | `xe` `act_freq` | Current GPU clock (Intel only). Sitting at `min_freq` means genuinely idle. Hidden when the render engine is powered down (it reads 0, which isn't a clock speed). |
| `1.2/8G` | `nvidia-smi` | VRAM used / total (NVIDIA only), shown instead of the clock. |
| `tmp cpu 59°` | `coretemp` / `k10temp` / ACPI | CPU package temperature. Sustained 90°C+ means thermal throttling — the machine is slow *because* it is hot. |
| `ssd 49°` | `nvme` hwmon | NVMe drive temperature. |
| `psi c18 i5 m0` | `/proc/pressure/*` | **Pressure Stall Information** — the percentage of the last 60 seconds that work was *actually lost* waiting for `c`pu, disk `i`/o, or `m`emory. This is the truest "is it slow" number on the box: `cpu 100%` with `psi c0` is a machine doing its job, while `psi i40` is a machine you are waiting on. `i` uses the kernel's `full` metric (everything stalled), `c` and `m` use `some` (at least one task stalled). Linux only. |
| `iowait 12%` | `/proc/stat` | Shown *instead of* `psi` on kernels without pressure stall info. |
| `dsk 16%` | `df /` | Root filesystem fullness. |
| `top claude 36%` | per-PID CPU delta | The two processes that burned the most CPU during the sample window, as a percentage of one core (so 200% = two cores' worth). Only processes above 5% are listed, so this line vanishes when load is spread thin. |

## Thresholds

`warn` (red, and the reason becomes the headline), in priority order:

| Condition | Threshold |
| --- | --- |
| memory stall | `psi` memory ≥ 5% |
| io stall | `psi` io (full) ≥ 15% |
| cpu stall | `psi` cpu ≥ 25% |
| memory | ≥ 92% used |
| cpu temperature | ≥ 90°C |
| disk | ≥ 92% full |

`info` (busy, not hurting): load ≥ core count, cpu ≥ 85%, memory ≥ 80%,
temperature ≥ 80°C, disk ≥ 85%, or forks ≥ 300/s. Otherwise `ok`.

## Notes on accuracy

Two numbers are **rates**, so the puller samples twice around a 1-second sleep
(`TMUXOPTICON_MACHINE_SAMPLE` overrides the interval): CPU busy, and the `top`
processes. The per-process figure is deliberately *not* `ps`'s own `%cpu`, which
is a lifetime average — on a box with two weeks of uptime that happily blames
whatever was busy last Tuesday.

The trade-off of a PID diff is that processes which are born *and* die inside
the window are invisible to it. That is not a gap so much as a division of
labour: those are exactly what the `f/s` fork rate counts.

The whole box is one minute stale at worst, because the collector runs from cron
once a minute and `render` never fetches (see the repo README). For a live view
while you are actively chasing something, reach for `htop` — this box is for
noticing, not for profiling.

## macOS

Reduced but honest: cpu / load / memory / disk / top processes work. No PSI (a
Linux kernel feature), no fork rate, and no GPU counter. Temperature requires
`osx-cpu-temp` on `PATH` (Apple's SMC isn't readable unprivileged); without it
the `tmp` line is simply omitted.
