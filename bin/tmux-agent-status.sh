#!/usr/bin/env bash
# Agent counts for the tmux status line: how many are working, how many idle.
# Called by status-right every `status-interval` seconds, so it stays cheap —
# one tmux query, no subprocess fan-out.
set -u

# The shell helpers hold the agent classifier and the session/kill logic, so this
# and the picker share one definition of what an agent is. Found relative to this
# script rather than at a fixed path: the repo has to work wherever it is cloned.
HELPERS="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/agents.sh"
if [ -r "$HELPERS" ]; then
  # shellcheck disable=SC1090
  . "$HELPERS"
fi

declare -F _t_agent_rows >/dev/null 2>&1 || exit 0

rows=$(_t_agent_rows)
[ -n "$rows" ] || exit 0

working=0
idle=0
waiting=0
running=0
while IFS=$'\t' read -r glyph status rest; do
  case "${status:-}" in
    working) working=$((working + 1)) ;;
    idle)    idle=$((idle + 1)) ;;
    waiting) waiting=$((waiting + 1)) ;;
    running) running=$((running + 1)) ;;   # alive, but state unknown
  esac
done <<< "$rows"

# Waiting is the one that actually needs you, so it gets the loud colour and
# leads. Working is green, idle deliberately dim.
out=""
[ "$waiting" -gt 0 ] && out="$out$(printf '#[fg=colour214,bold]◆%d#[none] ' "$waiting")"
out="$out$(printf '#[fg=colour41]●%d #[fg=colour244]○%d' "$working" "$idle")"
[ "$running" -gt 0 ] && out="$out$(printf ' #[fg=colour109]◇%d' "$running")"
printf '%s#[default]' "$out"
