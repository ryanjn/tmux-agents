#!/usr/bin/env bash
# tmux-agent-next — go to whichever agent has been waiting on you longest.
#
#   tmux-agent-next.sh [CLIENT_TTY]
#
# Bound to prefix + j. Press it until nobody's waiting.
#
# The point is that it asks you nothing. Seeing that two agents need you is
# already most of the work; choosing between them is the part worth deleting.
#
# ---------------------------------------------------------------------------
# Why longest-waiting, and not "the next one after the last one I visited"
# ---------------------------------------------------------------------------
# A round-robin cursor needs state — remembered somewhere, invalidated when agents
# come and go, and wrong the moment two clients use it at once. Ordering by how
# long each agent has been waiting needs none of that and advances by itself: you
# land on the oldest, you answer it, its hook clears the marker, and the next press
# goes to the new oldest. Nothing to persist, nothing to desync, and it happens to
# triage in the right order.
#
# Field 9 of _t_agent_rows is seconds spent waiting, from the marker file's mtime.
# An agent that publishes ◆ itself with no marker sorts as 0 — still reachable,
# just last, because we genuinely don't know how long it's been there.
set -u

HELPERS="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/agents.sh"
if [ -r "$HELPERS" ]; then
  # shellcheck disable=SC1090
  . "$HELPERS"
fi

if ! declare -F _t_agent_rows >/dev/null 2>&1; then
  tmux display-message "agent jump: helpers not found at $HELPERS"
  exit 0
fi

# The client that pressed the key, so _t_focus moves the right terminal window.
# See tmux-agent-pick.sh: a bare switch-client picks one at random.
export TMUX_AGENT_CLIENT="${1:-}"
[ -n "$TMUX_AGENT_CLIENT" ] || TMUX_AGENT_CLIENT=$(tmux display-message -p '#{client_tty}' 2>/dev/null)

rows=$(_t_agent_rows | awk -F'\t' '$2 == "waiting" { print ($9 == "" ? 0 : $9) "\t" $3 }')

if [ -z "$rows" ]; then
  # Not an error — it's the answer. Nobody needs you.
  tmux display-message "no agent is waiting on you"
  exit 0
fi

target=$(printf '%s\n' "$rows" | LC_ALL=C sort -k1,1nr | head -1 | cut -f2)
[ -n "$target" ] || exit 0

# How many others are still queued, so you know whether to press it again without
# having to open the picker to find out.
left=$(printf '%s\n' "$rows" | grep -c .)
_t_focus "$target" || { tmux display-message "agent jump: $target is gone"; exit 0; }

if [ "$left" -gt 1 ]; then
  tmux display-message "$((left - 1)) more waiting — press again"
fi
exit 0
