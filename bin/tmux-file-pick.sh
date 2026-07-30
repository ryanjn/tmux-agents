#!/usr/bin/env bash
# Dispatcher for prefix + f — the file browser for whatever the agent in this
# pane is working on.
#
#   tmux-file-pick.sh PANE [CLIENT]
#
# ~/.tmux.conf passes '#{pane_id}' and '#{client_tty}'. Both are expanded by tmux
# against the pane and client that pressed the key, which is the only reliable
# way to know either: a popup's command gets neither $TMUX_PANE nor a resolvable
# current client. See tmux-agent-pick.sh for the full story.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PANE="${1:-}"
CLIENT="${2:-}"
[ -n "$CLIENT" ] || CLIENT=$(tmux display-message -p '#{client_tty}' 2>/dev/null)
[ -n "$PANE" ] || PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null)

if ! command -v fzf >/dev/null 2>&1; then
  # No dependency-free fallback here, unlike the agent picker. display-menu can
  # show a handful of labelled actions; it cannot be a file browser over a few
  # thousand paths, and pretending otherwise would be worse than saying so.
  tmux display-message "file browser needs fzf — brew install fzf"
  exit 0
fi

ROOT=$(tmux display-message -p -t "$PANE" '#{pane_current_path}' 2>/dev/null)
[ -n "$ROOT" ] || ROOT="$HOME"

tmux display-popup -c "$CLIENT" \
  -e "TMUX_FILE_ROOT=$ROOT" \
  -e "TMUX_FILE_PANE=$PANE" \
  -e "TMUX_AGENT_CLIENT=$CLIENT" \
  -E -w 90% -h 80% "$DIR/tmux-file-picker.sh"

# Always succeed — same reasoning as tmux-agent-pick.sh: run-shell reports a
# non-zero popup as "'…/tmux-file-pick.sh' returned 1" on the status line, and
# Esc out of fzf is exit 130.
exit 0
