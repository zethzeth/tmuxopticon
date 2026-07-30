#!/usr/bin/env bash
# install.sh — point this clone's git hooks at hooks/.
#
# Git never clones hooks, so every checkout has to opt in once. `core.hooksPath`
# does it for the whole directory in one setting, so a hook added here later
# needs no second install.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
REPO="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)"

cd "$REPO"
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }
git config core.hooksPath hooks
chmod +x hooks/pre-commit 2>/dev/null || true

echo "hooks installed: core.hooksPath -> hooks/"
echo
echo "  pre-commit  blocks staged credentials, workspace IDs, and any word in"
echo "              your private denylist from reaching this PUBLIC repo."
echo
words="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon/private-words"
words2="${XDG_CONFIG_HOME:-$HOME/.config}/tmuxopticon/providers.d/private-words"
if [ -r "$words" ]; then
  echo "  denylist:   $words"
elif [ -r "$words2" ]; then
  echo "  denylist:   $words2"
else
  echo "  denylist:   none yet — structural checks only."
  echo "              Create $words (one regex per line) to add your own names,"
  echo "              employer, internal domains. It stays out of this repo."
fi
