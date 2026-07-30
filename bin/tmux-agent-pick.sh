#!/usr/bin/env bash
# Dispatcher for prefix + a.
#
# fzf gives fuzzy search and a live preview of each agent's screen, so prefer
# it. Without it, fall back to tmux's built-in menu — the binding keeps working
# on a machine where fzf isn't installed.
#
# Takes the invoking client's tty as $1; ~/.tmux.conf passes '#{client_tty}',
# which tmux expands against the client that pressed the key. See below for why
# nothing downstream can work that out for itself.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Which client are we acting on
# ---------------------------------------------------------------------------
# ⚠️  Inside `display-popup -E`, $TMUX_PANE is EMPTY. tmux then has nothing to
# resolve "the current client" from and falls back to whichever client it feels
# like — so a bare `switch-client` from the picker will happily yank a DIFFERENT
# terminal window to the agent you picked, while the window you pressed the key
# in sits there unchanged. Verified: with three clients attached, switching from
# the popup moved the wrong one every time.
#
# So capture the tty here, where run-shell still has the real client context,
# and hand it down. TMUX_AGENT_CLIENT is what _t_focus targets with -c.
CLIENT="${1:-}"
[ -n "$CLIENT" ] || CLIENT=$(tmux display-message -p '#{client_tty}' 2>/dev/null)

if command -v fzf >/dev/null 2>&1; then
  # -c so the popup itself lands on the right client; -e so the picker inherits
  # the tty (a popup's command comes from the server, so exporting here would
  # not reach it).
  tmux display-popup -c "$CLIENT" -e "TMUX_AGENT_CLIENT=$CLIENT" \
    -E -w 90% -h 80% "$DIR/tmux-agent-picker.sh"
else
  # The menu runs in this process, where a plain export is enough.
  TMUX_AGENT_CLIENT="$CLIENT" "$DIR/tmux-agent-menu.sh"
fi

# Always succeed.
#
# The binding runs this under `run-shell`, which reports any non-zero status as
# "'…/tmux-agent-pick.sh' returned 1" over the top of the status line — and the
# popup is *expected* to end non-zero in the normal case: switching the client
# to another session tears the popup down mid-command, and Esc out of fzf is
# exit 130. Neither is an error worth a message.
#
# Nothing is being swallowed that you'd want: every real failure downstream is
# reported by tmux-agent-do.sh via `display-message` before it exits.
exit 0
