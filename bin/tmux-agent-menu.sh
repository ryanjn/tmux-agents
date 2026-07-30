#!/usr/bin/env bash
# tmux-agent-menu — a cursor-navigable picker for every Claude Code agent.
#
# Bound to prefix + a in ~/.tmux.conf. Arrow keys move, Enter jumps to that
# agent, Esc cancels; 1-9 jump directly. Below the list: n starts a new agent,
# s starts one alongside the agent you're currently in, x opens a kill menu.
#
# Uses tmux's built-in display-menu rather than fzf so it has zero
# dependencies. See GHOSTTY-TMUX-README.md for the fzf version, which adds a
# live preview of each agent's screen.
#
#   tmux-agent-menu.sh              the agent menu
#   tmux-agent-menu.sh --kill-menu  same list, but picking one kills it
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO="$DIR/tmux-agent-do.sh"

# Reuse the classifier from the shell helpers — one source of truth for what
# counts as an agent and whether it's working.
# The shell helpers hold the agent classifier and the session/kill logic, so this
# and the picker share one definition of what an agent is. Found relative to this
# script rather than at a fixed path: the repo has to work wherever it is cloned.
HELPERS="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/agents.sh"
if [ -r "$HELPERS" ]; then
  # shellcheck disable=SC1090
  . "$HELPERS"
fi

if ! declare -F _t_agent_display >/dev/null 2>&1; then
  tmux display-message "agent menu: helpers not found at $HELPERS"
  exit 1
fi

mode="${1:-}"
rows=$(_t_agent_display)

# The pane the menu was opened from — what "alongside" means when there's no
# cursor to point at a row. run-shell inherits the client's pane, so this is the
# window you were looking at. Resolved now rather than left as a #{pane_id} for
# tmux to expand later, because whether run-shell expands formats in its command
# has moved around between tmux versions; the current pane can't change between
# building this menu and clicking it anyway.
#
# display-menu / command-prompt / confirm-before below are deliberately left
# without -c: unlike the popup, this whole script runs under `run-shell` from
# the key binding, where tmux still knows which client pressed the key. Only
# this lookup gets -c, because it's the one value a wrong client would silently
# corrupt (you'd get a second agent beside someone else's window).
if [ -n "${TMUX_AGENT_CLIENT:-}" ]; then
  here=$(tmux display-message -c "$TMUX_AGENT_CLIENT" -p '#{pane_id}' 2>/dev/null)
else
  here=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
fi
# No current pane (invoked from a client-less context): point "alongside" at the
# first agent instead of building a menu entry that fails when you press it.
[ -n "${here:-}" ] || here=$(printf '%s\n' "$rows" | awk -F'\t' 'NR==1 { print $1 }')

if [ -z "$rows" ]; then
  # Nothing to list, but starting one is still the likely intent.
  if [ "$mode" = "--kill-menu" ]; then
    tmux display-message "no agents running"
    exit 0
  fi
  tmux command-prompt -p "new agent name:" "run-shell \"$DO new '%%'\""
  exit 0
fi

# display-menu takes (label, key, command) triples.
args=()
i=0
while IFS=$'\t' read -r pane session cwd glyph status label task; do
  [ -n "${pane:-}" ] || continue
  i=$((i + 1))
  if [ "$i" -le 9 ]; then key="$i"; else key=""; fi

  # Trim the task so a long one can't stretch the menu off-screen. The label
  # column is already capped at 30 by _t_agent_display.
  if [ ${#task} -gt 46 ]; then task="${task:0:45}…"; fi
  disp=$(printf '%s %-30s %s' "$glyph" "$label" "$task")

  if [ "$mode" = "--kill-menu" ]; then
    # confirm-before, because this row now destroys work instead of visiting it.
    args+=( "$disp" "$key" "confirm-before -p 'kill agent in $session? (y/n)' \"run-shell \\\"$DO kill $pane\\\"\"" )
  else
    args+=( "$disp" "$key" "run-shell \"$DO focus $pane\"" )
  fi
done <<< "$rows"

if [ "$mode" = "--kill-menu" ]; then
  tmux display-menu -T "#[align=centre fg=colour203,bold] Kill agent " -x C -y C "${args[@]}"
  exit 0
fi

# A separator, then the verbs. Same three actions the fzf picker binds to
# ctrl-n / ctrl-s / ctrl-x, so the muscle memory transfers.
args+=( "" )
args+=( "new agent…"            "n" "command-prompt -p 'new agent name:' \"run-shell \\\"$DO new '%%'\\\"\"" )
args+=( "agent alongside this one" "s" "run-shell \"$DO alongside $here\"" )
args+=( "kill an agent…"        "x" "run-shell \"$DIR/tmux-agent-menu.sh --kill-menu\"" )
args+=( "" )
args+=( "list all panes (tw)"   "w" "choose-tree -Zs" )

tmux display-menu -T "#[align=centre fg=colour39,bold] Agents " -x C -y C "${args[@]}"
