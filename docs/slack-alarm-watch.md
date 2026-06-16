# Reading Slack alarm channels as a plain user (terminal sidebar)

Goal: keep Slack's own notifications **off**, but still see the handful of
alarm channels the boss insists on — surfaced quietly in the tmuxopticon
sidebar instead of as desktop popups. A cron job polls Slack once a minute,
filters out false alarms, and writes a cache the sidebar renders.

You do **not** need to be a Slack admin to *read* messages. You need a
**user token** (`xoxp-…`) from a small "internal" Slack app. The only step
that might need an admin is *installing* the app, if your workspace requires
approval for app installs — a one-time ask.

> Rate limits: in 2025 Slack throttled `conversations.history` to 15 msgs /
> 1 request per minute — but only for apps *distributed outside* the Slack
> Marketplace. An **internal app** (created and installed only in your own
> workspace, never distributed) keeps the old limits, so once-a-minute
> polling is fine.

## 1. Create the Slack app + get a user token

1. Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**.
   Name it anything ("alarm-reader"), pick your workspace.
2. Left sidebar → **OAuth & Permissions**.
3. Scroll to **Scopes → User Token Scopes** (the *User* table, not Bot) and add:
   - `channels:history` — read messages in public channels
   - `channels:read` — resolve channel info
   - `groups:history` — **only if** any alarm channel is private
   - `users:read` — optional, nicer sender names
4. Scroll up → **Install to Workspace** → Allow. (If you see "request
   approval", that's the admin ask — your boss/admin approves it once.)
5. Back on **OAuth & Permissions**, copy the **User OAuth Token** — it starts
   with `xoxp-`. Treat it like a password.

## 2. Find the channel IDs

For each alarm channel: open it in Slack → click the channel name at the top
→ **About** tab → the **Channel ID** (starts with `C…`) is at the very bottom.
You must be a *member* of each channel for a user token to read its history.

## 3. Configure `slack.env`

Config + the token live under tmuxopticon's own config dir (kept out of the
repo, next to `uptimerobot.key`):

```sh
mkdir -p ~/.config/tmuxopticon
cp providers/slack/slack.env.example ~/.config/tmuxopticon/slack.env
```

Edit `~/.config/tmuxopticon/slack.env` and set:

```sh
SLACK_TOKEN=xoxp-your-token-here
SLACK_ALARM_CHANNELS="C0PROD123:prod-alerts C0DB456:db"   # ID:label, space-separated
```

The `:label` after each ID is just the short name shown in the sidebar; omit
it to show the raw ID.

Verify it works:

```sh
providers/slack/slack-alarm-watch.sh test
```

Expect `OK — authenticated as <you> in workspace <name>` and your channel list.

## 4. Filter false alarms

Copy the template, then edit `~/.config/tmuxopticon/slack-alarm-ignore.txt` —
one case-insensitive regex per line. Any new message matching a pattern is
dropped before it reaches the sidebar. Edits apply on the next poll (within a
minute).

```sh
cp providers/slack/slack-alarm-ignore.example.txt ~/.config/tmuxopticon/slack-alarm-ignore.txt
```

Examples:

```
resolved
back to normal
^heartbeat
test alert
```

## 5. Run it every minute via cron

Add this line to your crontab (`crontab -e`, or run the one-liner below — no
sudo needed, it's your user crontab):

```cron
* * * * * /path/to/tmuxopticon/providers/slack/slack-alarm-watch.sh poll >/dev/null 2>&1
```

Non-interactive install:

```sh
( crontab -l 2>/dev/null; echo '* * * * * /path/to/tmuxopticon/providers/slack/slack-alarm-watch.sh poll >/dev/null 2>&1' ) | crontab -
```

## 6. See it in the sidebar

The watcher writes `/tmp/tmuxopticon.alarms.$UID`, which the tmuxopticon
**Alarms** box reads automatically — no tmux config needed (the box's default
cache path matches). Toggle the sidebar with `prefix o`; the Alarms box appears
at the bottom showing `○ no alarms` when clear, or `● N alarms` with the latest
lines when something fires. If cron stops, it shows `⚠ stale`.

## Day-to-day

(`P=/path/to/tmuxopticon/providers/slack/slack-alarm-watch.sh`)

- `$P list` — print the active alarms.
- `$P clear` — acknowledge / clear them all (they also auto-expire after
  `SLACK_ALARM_TTL`, default 24h).
- Add an alias in `~/.zshrc.extra` if you clear often, e.g.
  `alias salarm-clear='/path/to/tmuxopticon/providers/slack/slack-alarm-watch.sh clear'`.

## Notes / limits

- Reads only channels you're a **member** of. Private channels need
  `groups:history`.
- One page (~200 msgs) per channel per pass — ample at one alarm/minute; a
  huge burst inside a single minute could skip the middle of the burst.
- The token is a **secret** living in `~/.config/tmuxopticon/slack.env` (outside
  the repo). If it leaks, revoke it on the app's **OAuth & Permissions** page
  and reinstall.
