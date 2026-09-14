#!/usr/bin/env bash
# tmux-agent-cli — standalone entry point for the agent helpers.
#
# The helpers are shell FUNCTIONS, which only exist in a shell that has sourced
# them. That covers an interactive prompt and nothing else: `!tsleep` from an
# editor, a cron line, a hook, `bash -c`, and Claude Code's own `!` prefix all
# start a non-login /bin/bash which never reads ~/.bash_profile, so the function
# is simply not there. "command not found" is the only symptom, and sourcing the
# profile does not fix it because the next invocation is another fresh shell.
#
# Symlinked into ~/.local/bin under each name, and dispatches on argv[0]:
#   tsleep twake tsnaps tsave trestore tarchive tpower tdoctor tf
#
# ⚠️  Both files, in this order. tmux-persist.sh's tsleep calls _t_agent_sid and
# _t_agent_pid, which live in tmux-aliases.sh — loading only the persist half
# gives a tsleep that runs and silently fails to record any session id, which is
# exactly the case that loses conversations.
set -u

# ⚠️  Same trap as the save/restore scripts, reached through a different door.
# With no locale — which is what a bare `bash -c` inherits — tmux substitutes "_"
# for the TAB in a format string, so every tab-separated helper silently reads
# one giant field and finds nothing. The symptom is "nothing to sleep", not an
# error.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

HOME_DIR="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
for f in "$HOME_DIR/shell/agents.sh" "$HOME_DIR/shell/tmux-persist.sh" "$HOME_DIR/shell/favorites.sh"; do
  # shellcheck disable=SC1090
  [ -r "$f" ] && . "$f"
done

cmd="$(basename "$0")"
if ! declare -F "$cmd" >/dev/null 2>&1; then
  echo "$cmd: helper not found — expected it in $HOME_DIR/shell/" >&2
  exit 1
fi
"$cmd" "$@"
