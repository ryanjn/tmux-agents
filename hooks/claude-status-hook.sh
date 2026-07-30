#!/usr/bin/env bash
# claude-status-hook — record whether a Claude Code pane is *waiting on you*.
#
# Claude Code owns its pane title and rewrites it continuously, so
# we can't publish state there — it would be clobbered within a frame. Instead
# each pane gets a marker file, and the classifier in shell/agents.sh
# treats "title says idle (✳) + marker present" as waiting.
#
# Why this is needed at all: Claude renders ✳ both when it has finished and
# when it is sitting waiting for you. Those are the two states you most need to
# tell apart when several agents are running.
#
# Wired into ~/.claude/settings.json — see hooks/README.md:
#   Notification, PermissionRequest  -> set    (needs your attention)
#   Stop, UserPromptSubmit, SessionStart -> clear
set -u

action="${1:-clear}"

# Drain stdin — Claude Code pipes hook JSON in and we don't want it blocking.
cat >/dev/null 2>&1 || true

# The hook is a child of the Claude process, which runs in the pane, so
# TMUX_PANE is inherited. Outside tmux there's nothing to track.
[ -n "${TMUX_PANE:-}" ] || exit 0

dir="$HOME/.cache/tmux-agent-status"
mkdir -p "$dir" 2>/dev/null || exit 0

# TMUX_PANE looks like "%12"; strip the % so the filename stays boring.
marker="$dir/${TMUX_PANE#%}.waiting"

case "$action" in
  set) : > "$marker" ;;
  *)   rm -f "$marker" ;;
esac

# Emit nothing: any stdout is parsed by Claude Code as a hook directive.
exit 0
