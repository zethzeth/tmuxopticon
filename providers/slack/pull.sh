#!/usr/bin/env bash
# pull.sh — registry adapter for the Slack alarm provider.
#
# The registry invokes every puller the same way: `pull.sh <cachefile>`.
# slack-alarm-watch.sh predates that contract — it takes its cache path from
# $SLACK_ALARM_CACHE and does a polling pass via its `poll` subcommand. Bridge
# the two so the Slack provider looks like any other, and slack-alarm-watch.sh
# keeps its own CLI (poll/test/list/clear) untouched.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
exec env SLACK_ALARM_CACHE="${1:?usage: pull.sh <cache-file>}" "$HERE/slack-alarm-watch.sh" poll
