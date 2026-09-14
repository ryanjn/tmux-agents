#!/usr/bin/env bash
# tmux-agent-notify — one desktop notification, best-effort.
#
#   tmux-agent-notify.sh TITLE MESSAGE
#
# Called by hooks/claude-status-hook.sh when an agent starts waiting, and only if
# @agent-notify / TMUX_AGENT_NOTIFY is 1. Off by default: notifications are personal, and a tool that
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

# Preferred: the terminal itself. Ghostty turns OSC 777 ("notify;TITLE;BODY")
# into a real desktop notification from a signed, authorised app — the one
# notification path that still works on macOS 26. Written to a PANE's tty
# wrapped in tmux's passthrough envelope, so tmux forwards it to the attached
# client (allow-passthrough must be "all", set in tmux.conf, or an agent in a
# window you are not looking at — the whole point — gets nothing).
#
# ⚠️  2026-09-10: terminal-notifier (2.0.0, 2017, NSUserNotification) and
# osascript's `display notification` both exit 0 on macOS 26 and deliver
# NOTHING — neither so much as reaches usernotificationsd, which is how it went
# unnoticed. They stay below only as fallbacks for a detached server on an
# older macOS.
_osc_pane_tty() {
  local tty=""
  [ -n "${TMUX_PANE:-}" ] && tty=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_tty}' 2>/dev/null)
  # Not in a pane (launchd, a cron line): any pane will do under passthrough "all".
  [ -n "$tty" ] || tty=$(tmux list-panes -a -F '#{pane_tty}' 2>/dev/null | head -1)
  printf '%s' "$tty"
}
if tmux list-clients 2>/dev/null | grep -q .; then
  tty=$(_osc_pane_tty)
  if [ -n "$tty" ] && [ -w "$tty" ]; then
    # OSC text: no control characters, and no ";" in the title (it is the field
    # separator). The ESCs inside the envelope are doubled, as tmux requires.
    t=$(printf '%s' "$title" | tr -d '\000-\037;' )
    m=$(printf '%s' "$message" | tr -d '\000-\037')
    printf '\033Ptmux;\033\033]777;notify;%s;%s\007\033\\' "$t" "$m" > "$tty" 2>/dev/null
    exit 0
  fi
fi

if command -v terminal-notifier >/dev/null 2>&1; then
  terminal-notifier -title "$title" -message "$message" \
    -group "tmux-agents" >/dev/null 2>&1
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  t=$(printf '%s' "$title" | tr -d '"\\')
  m=$(printf '%s' "$message" | tr -d '"\\')
  osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$message" >/dev/null 2>&1
fi

exit 0
