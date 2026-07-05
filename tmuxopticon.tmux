#!/usr/bin/env bash
#----------------------------------------------------------------------
# tmuxopticon — a toggleable left sidebar that watches every tmux session
# at once: split counts + live Claude Code status (working/waiting/done).
#
# Self-contained and path-independent: it locates its own directory, so
# you can clone this folder anywhere. Wire it up from your .tmux.conf:
#
#   run-shell /path/to/tmuxopticon/tmuxopticon.tmux
#
# Or, with tpm (https://github.com/tmux-plugins/tpm):
#
#   set -g @plugin 'youruser/tmuxopticon'
#
# Requires: tmux 3.x, bash, perl, git.
#----------------------------------------------------------------------
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
SCRIPT="$CURRENT_DIR/tmuxopticon.sh"

# --- defaults (override these in your own .tmux.conf if you like) -----
tmux set -gq @tmuxopticon-width    '34'
tmux set -gq @tmuxopticon-interval '1'
# Friendly aliases for ugly hostnames in SSH-pane paths, ';'-separated from=to
# pairs (off by default — this is where personal hostnames live, NOT in the
# engine):  set -g @tmuxopticon-host-aliases 'ip-10-13-99-46=zeod;10.0.0.5=db'
#
# The bottom status boxes are fed by providers/collect.sh (a cron job) and chosen
# in ~/.config/tmuxopticon/pull.conf — no tmux options needed to enable them.

# Keep the drawer following the focused window/session while it's toggled on.
# 'ensure' is a no-op when inactive or already present, so these hooks can live
# permanently — switching windows, opening new ones, and jumping sessions all
# re-home the sidebar into wherever you land. (Hooks stay even if you disable the
# default keys below — they're how the drawer follows focus, not a binding.)
tmux set-hook -g after-select-window    "run-shell \"'$SCRIPT' ensure\""
tmux set-hook -g after-new-window       "run-shell \"'$SCRIPT' ensure\""
tmux set-hook -g client-session-changed "run-shell \"'$SCRIPT' ensure\""

# --- default key bindings ---------------------------------------------
# Opt out wholesale to bind your own:  set -g @tmuxopticon-default-keys 'off'
# (set this BEFORE the run-shell line that sources this file). Then wire the
# subcommands yourself — e.g.  bind o run-shell "/path/to/tmuxopticon.sh toggle".
case "$(tmux show-option -gqv @tmuxopticon-default-keys)" in
  off|false|0|no|none) return 0 2>/dev/null || exit 0;;
esac

# Toggle the left sidebar on/off (global switch)
tmux bind o run-shell "'$SCRIPT' toggle"

# Name the current SESSION (persists, shows in the sidebar and in 'prefix s')
tmux bind t command-prompt -p "session name:" "rename-session '%%'"

# Kill a session: 'prefix K' then its sidebar number; 'prefix K K' kills the
# current one; 'prefix K a' kills every session EXCEPT the current one
tmux bind K switch-client -T tmuxopticon-kill
tmux bind -T tmuxopticon-kill 1 run-shell "'$SCRIPT' kill 1"
tmux bind -T tmuxopticon-kill 2 run-shell "'$SCRIPT' kill 2"
tmux bind -T tmuxopticon-kill 3 run-shell "'$SCRIPT' kill 3"
tmux bind -T tmuxopticon-kill 4 run-shell "'$SCRIPT' kill 4"
tmux bind -T tmuxopticon-kill 5 run-shell "'$SCRIPT' kill 5"
tmux bind -T tmuxopticon-kill 6 run-shell "'$SCRIPT' kill 6"
tmux bind -T tmuxopticon-kill 7 run-shell "'$SCRIPT' kill 7"
tmux bind -T tmuxopticon-kill 8 run-shell "'$SCRIPT' kill 8"
tmux bind -T tmuxopticon-kill 9 run-shell "'$SCRIPT' kill 9"
tmux bind -T tmuxopticon-kill K confirm-before -p "kill current session? (y/n)" kill-session
tmux bind -T tmuxopticon-kill a confirm-before -p "kill ALL other sessions? (y/n)" "kill-session -a"
tmux bind -T tmuxopticon-kill Any switch-client -T root

# Jump to the Nth session as listed in the sidebar (top = 1)
tmux bind 1 run-shell "'$SCRIPT' jump 1"
tmux bind 2 run-shell "'$SCRIPT' jump 2"
tmux bind 3 run-shell "'$SCRIPT' jump 3"
tmux bind 4 run-shell "'$SCRIPT' jump 4"
tmux bind 5 run-shell "'$SCRIPT' jump 5"
tmux bind 6 run-shell "'$SCRIPT' jump 6"
tmux bind 7 run-shell "'$SCRIPT' jump 7"
tmux bind 8 run-shell "'$SCRIPT' jump 8"
tmux bind 9 run-shell "'$SCRIPT' jump 9"

# Click a session row in the sidebar to switch to it
tmux bind -n MouseDown1Pane if-shell -F -t '=' '#{==:#{pane_title},tmuxopticon}' "run-shell \"'$SCRIPT' click #{mouse_y}\"" "select-pane -t '=' ; send -M"
