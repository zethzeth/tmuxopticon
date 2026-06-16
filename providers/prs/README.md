# Open PRs provider (bring your own puller)

This provider ships a manifest but **no puller** — on purpose. *Which* PRs are
"waiting on you" is service- and workplace-specific (GitHub org, auth, query),
so the actual fetch script lives **outside** this repo and you point the plugin
at it. That keeps tmuxopticon generic.

## Wire it up

1. Write a puller anywhere (in your own work-tooling repo, say). It is invoked
   as `your-puller <cachefile>` and must write the shared cache format:

   ```
   <epoch>                     line 1: UNIX time of this pull (staleness check)
   info                        line 2: state — ok | info | warn | err
   Open PRs: 4 across 4 repos  line 3: the one-line summary
   ...                         line 4+: optional dimmed detail lines
   ```

   Use the neutral **`info`** state — a PR count is an FYI, not a health alarm,
   so the box never lights red over it.

2. In `~/.config/tmuxopticon/pull.conf`:

   ```sh
   PRS_PULL_ENABLED=true
   PRS_PULL_CMD=/abs/path/to/your-prs-pull.sh
   ```

`provider.conf` here sets `pull_cmd_var=PRS_PULL_CMD`, so the collector resolves
the puller from that variable. `throttle_min=7` spaces the pulls out (the `prs`
command this was built against has a tight rate limit a once-a-minute pull blows
through); a manual `collector-run.sh --force` bypasses the throttle.
