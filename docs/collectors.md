# tmuxopticon status collectors (cron → tmp/ caches → sidebar)

Goal: feed the boxes at the bottom of the tmuxopticon sidebar — **Uptime Robot**,
**Open PRs**, **Slack alarms** — without ever letting the redraw loop touch the
network. A single cron job pulls each enabled provider once a minute into a cache
file; the sidebar only reads those caches.

```
cron (every minute)
  └─ providers/collect.sh              walks the registry (lib/providers.sh),
       │                               reads ~/.config/tmuxopticon/pull.conf
       ├─ uptimerobot/pull.sh      →  tmp/uptime_robot.cache
       ├─ <your PRS_PULL_CMD>      →  tmp/prs.cache
       └─ slack/slack-alarm-watch  →  tmp/slack.cache
                                        ▲
            tmuxopticon render ─────────┘  (reads only; never fetches)
```

Every cache uses the same shape, written atomically:

```
line 1  epoch          (unix seconds — staleness check)
line 2  state          ok | warn | err
line 3  summary        the headline shown next to the icon
line 4+ detail lines   dimmed, indented (optional)
```

The sidebar maps `ok → ○` (green), `info → •` (neutral — a count/FYI, e.g. Open
PRs), `warn → ●` (red), and renders `err` as a **full-width red banner** (so a
real failure can't be missed). It shows `Last sync: H:MM (N min ago)` when a
cache's epoch is older than `@tmuxopticon-provider-stale` (default 180s) — the
tell that cron stopped.

## 1. Enable the providers you want

Copy the template and flip the flags:

```sh
mkdir -p ~/.config/tmuxopticon
cp /path/to/tmuxopticon/examples/pull.conf.example ~/.config/tmuxopticon/pull.conf
$EDITOR ~/.config/tmuxopticon/pull.conf
```

```sh
SLACK_PULL_ENABLED=true
UPTIME_ROBOT_PULL_ENABLED=true
PRS_PULL_ENABLED=true

# Absolute path to the PRs puller (work-specific, lives outside this repo)
PRS_PULL_CMD=/home/you/code/your-work-tooling/scripts/tmuxopticon-prs-pull.sh
```

A flag is "on" only when set to exactly `true`, `1`, or `yes`. A provider also
stays silent until its prerequisite exists (key / token / command below), so you
can enable a flag before finishing its setup.

## 2. Start the collector (off by default)

The collector ships **off**. Turn it on with the start script — it installs the
once-a-minute cron line for you (idempotently) and sets the enable flag:

```sh
/path/to/tmuxopticon/providers/collector-start.sh   # ON  — installs cron + flag
/path/to/tmuxopticon/providers/collector-stop.sh    # OFF — removes cron + flag
/path/to/tmuxopticon/providers/collector-status.sh  # inspect: flag, cron, caches
```

**You only run `collector-start.sh` once.** crontab entries persist across logins
and reboots — they are *not* reset when you log out, so there's nothing to redo
each session. Start/stop just let you pause and resume without editing crontab.

While the collector is stopped the sidebar's status panel shows a single
`⊘ Cron-checker disabled` line instead of provider boxes (the tell that it's off
on purpose, not broken). `collect.sh` also self-checks the flag, so even a
stray cron line does nothing once you've stopped.

> Prefer to wire cron yourself? The line `collector-start.sh` installs is just
> `* * * * * /path/to/tmuxopticon/providers/collect.sh >/dev/null 2>&1` (tagged
> with a `# tmuxopticon-collector` comment). You'd still need to
> `touch ~/.config/tmuxopticon/collector.enabled` for the collector to run.

With no `pull.conf` the collector is a quiet no-op, so it's safe to start before
configuring any providers.

> **cron's environment is minimal.** `collect.sh` exports a sane `PATH`
> (`~/.local/bin:/usr/local/bin:/usr/bin:/bin`) so `curl`, `jq`, `zsh`, and `gh`
> resolve. If a tool of yours lives elsewhere, extend that line in `collect.sh`.

## 3. Per-provider setup

### Uptime Robot

Create a **read-only** API key (Uptime Robot → *Integrations* → *API*) and drop
it where the puller looks — out of the repo:

```sh
echo 'u123456-yourreadonlykey' > ~/.config/tmuxopticon/uptimerobot.key
```

The puller (`providers/uptimerobot/pull.sh`) reports the monitors that are down
(statuses "down" + "seems down"). With the flag on but no key it writes
`⚠ no API key`.

### Open PRs

`PRS_PULL_CMD` points at a script **you** provide that takes a cache-file path as
`$1` and writes the cache format above. It's kept outside this (personal) repo
when the command is work-specific. A minimal one:

```sh
#!/usr/bin/env bash
set -u
OUT="${1:?cache path}"
now="$(date +%s)"
n="$(your-command-that-prints-a-count)"
state=ok; [ "$n" -gt 0 ] 2>/dev/null && state=warn
printf '%s\n%s\nOpen PRs: %s\n' "$now" "$state" "$n" > "$OUT.$$"
mv -f "$OUT.$$" "$OUT"
```

### Slack alarms

See [slack-alarm-watch.md](slack-alarm-watch.md) for the one-time Slack-app
setup that produces the user token. Put the token + channel list in
`~/.config/tmuxopticon/slack.env` (from `providers/slack/slack.env.example`). The
collector runs `slack/slack-alarm-watch.sh poll` for you each minute.

## 4. Verify

```sh
# run the collector by hand and inspect the caches it writes. --force bypasses
# the off-by-default collector.enabled gate (collector-run.sh does the same, with
# a written-ages summary).
/path/to/tmuxopticon/providers/collect.sh --force
ls -la /path/to/tmuxopticon/tmp/
cat   /path/to/tmuxopticon/tmp/uptime_robot.cache
```

A provider you enabled but haven't finished configuring writes no cache (or an
`err` one), and the sidebar simply doesn't draw its box until a cache appears.
In tmux, toggle the sidebar off and on (`prefix o` twice) to pick up the boxes;
they'll show in **every** session's sidebar, since render no longer fetches.

## Adding your own provider

Providers are a **registry** (`lib/providers.sh`): the engine names none of them,
so a new box is a drop-in directory — no core edits.

```sh
# copy the template out of the repo, where a git pull won't clobber it
cp -r /path/to/tmuxopticon/examples/provider-template \
      ~/.config/tmuxopticon/providers.d/weather
$EDITOR ~/.config/tmuxopticon/providers.d/weather/provider.conf   # id/title/flag/order…
$EDITOR ~/.config/tmuxopticon/providers.d/weather/pull.sh         # write the cache format
```

Then turn it on in `pull.conf` with the `flag` name your manifest declares:

```sh
echo 'WEATHER_PULL_ENABLED=true' >> ~/.config/tmuxopticon/pull.conf
/path/to/tmuxopticon/providers/collect.sh --force   # pull once now
```

The collector writes `tmp/<id>.cache` and the sidebar draws the box at the
manifest's `order`. Confirm discovery any time with:

```sh
cd /path/to/tmuxopticon && bash -c '. lib/providers.sh; provider_rows'
```

See `lib/providers.sh` for the full manifest reference and
`providers/prs/` for the "puller lives outside the repo" (`pull_cmd_var`) pattern.

## Troubleshooting

- **Box never appears** — is the flag exactly `true`/`1`/`yes`? Did the cache
  file get written (`ls tmp/`)? Is the cron line installed (`crontab -l`)?
- **`Last sync: …`** — cron isn't running `collect.sh`. Check `crontab -l`, the path
  in the cron line, and that `collect.sh` is executable.
- **Uptime Robot `⚠ no API key`** — the key file is missing/empty at
  `~/.config/tmuxopticon/uptimerobot.key`.
- **Open PRs `⚠ prs failed` / nothing** — the `PRS_PULL_CMD` couldn't run under
  cron's env (often `gh` not on PATH or not authenticated). Run the puller by
  hand first; then check it works from a minimal shell.
