#!/usr/bin/env bash
# tmux-agent-notify — one desktop notification, best-effort.
#
#   tmux-agent-notify.sh TITLE MESSAGE
#
# Called by hooks/claude-status-hook.sh when an agent starts waiting, and only if
# TMUX_AGENT_NOTIFY=1. Off by default: notifications are personal, and a tool that
# starts firing them after an update has spent trust it can't earn back.
#
# Set TMUX_AGENT_NOTIFY_CMD to use your own notifier instead. It's called as
#     $TMUX_AGENT_NOTIFY_CMD TITLE MESSAGE
# which is also how the test suite checks this without lighting up a real desktop.
#
# Never fails loudly. This runs in an agent's hook path; a missing notifier is a
# silent no-op, not something that surfaces in your agent's output.
set -u

title="${1:-agent}"
message="${2:-}"

if [ -n "${TMUX_AGENT_NOTIFY_CMD:-}" ]; then
  # shellcheck disable=SC2086
  $TMUX_AGENT_NOTIFY_CMD "$title" "$message" >/dev/null 2>&1
  exit 0
fi

if command -v terminal-notifier >/dev/null 2>&1; then
  # Preferred on macOS: it can carry a group id, so repeat notifications for the
  # same agent replace each other instead of stacking up.
  terminal-notifier -title "$title" -message "$message" \
    -group "tmux-agents" >/dev/null 2>&1
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  # Nothing to install. Quotes inside the text would end the AppleScript string,
  # so they're stripped rather than escaped — this is a notification, not a
  # document.
  t=$(printf '%s' "$title" | tr -d '"\\')
  m=$(printf '%s' "$message" | tr -d '"\\')
  osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$message" >/dev/null 2>&1
fi

exit 0
