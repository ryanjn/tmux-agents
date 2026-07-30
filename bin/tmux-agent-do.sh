#!/usr/bin/env bash
# tmux-agent-do — the verbs behind the agent picker.
#
# The picker (fzf) and the menu fallback (display-menu) both shell out to this
# instead of running tmux commands themselves, so "new agent" means exactly the
# same thing however you got there. The logic itself lives in the shell helpers
# (shell/agents.sh) so it's callable from a plain prompt too.
#
#   tmux-agent-do.sh focus        PANE          jump to that agent
#   tmux-agent-do.sh new          NAME          new agent session named NAME
#   tmux-agent-do.sh alongside    PANE [NAME]   new agent in PANE's session and cwd
#   tmux-agent-do.sh kill         PANE          kill that agent, and nothing else
#   tmux-agent-do.sh rename       PANE NEW      rename the agent's session
#
# The confirmation dialog for a kill lives in tmux-agent-pick.sh, not here: it has
# to be opened from outside the picker's popup (tmux allows one overlay per
# client). These verbs just do the thing they're told.
#
# PANE is a tmux pane id (%12), not a session name — see _t_agent_rows for why.
set -u

# The shell helpers hold the agent classifier and the session/kill logic, so this
# and the picker share one definition of what an agent is. Found relative to this
# script rather than at a fixed path: the repo has to work wherever it is cloned.
HELPERS="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/agents.sh"
if [ -r "$HELPERS" ]; then
  # shellcheck disable=SC1090
  . "$HELPERS"
fi

if ! declare -F _t_new_session >/dev/null 2>&1; then
  tmux display-message "agent actions: helpers not found at $HELPERS"
  exit 1
fi

# Errors go to the tmux message line, not stdout: half of these run under
# `run-shell`, where nothing has a terminal to print to.
die() {
  tmux display-message "$1"
  exit 1
}

# A name typed into a prompt becomes a session name AND a directory name, so
# keep it to something safe rather than rejecting it and making them retype.
sanitize() {
  local n="$1"
  n="${n//[^A-Za-z0-9._-]/-}"                          # spaces, slashes, quotes -> dash
  while [ "$n" != "${n//--/-}" ]; do n="${n//--/-}"; done  # "foo / bar" -> foo-bar, not foo---bar
  while [ "$n" != "${n#[-.]}" ]; do n="${n#[-.]}"; done    # a leading - reads as a tmux flag
  while [ "$n" != "${n%[-.]}" ]; do n="${n%[-.]}"; done    # trailing dash is just untidy
  printf '%s' "$n"
}

cmd="${1:-}"
[ -n "$cmd" ] || die "agent actions: no command given"
shift || true

case "$cmd" in

  focus)
    pane="${1:-}"
    [ -n "$pane" ] || die "agent focus: no pane given"
    _t_focus "$pane" || die "agent focus: $pane is gone"
    ;;

  new)
    name=$(sanitize "${1:-}")
    [ -n "$name" ] || die "new agent: name was empty"

    # Idempotent on purpose: typing the name of an agent that already exists
    # should take you to it, not fail. Same contract as `t`.
    if tmux has-session -t "=$name" 2>/dev/null; then
      tmux display-message "agent '$name' already running — switching"
      # -s lists the whole session in window order, so the first pane is the
      # agent's. Not "=$name:1" — that assumes base-index 1.
      _t_focus "$(tmux list-panes -s -t "=$name" -F '#{pane_id}' | head -1)"
      exit 0
    fi

    # Recorded in the folder's CLAUDE.md, so a future agent can tell a session
    # started from the picker from one started by hand. Single-quoted: backticks
    # in double quotes would run as command substitution.
    _T_ORIGIN='the `Ctrl+b a` agent picker'

    pane=$(_t_new_session "$name" 2>/dev/null) \
      || die "new agent: could not create '$name'"
    _t_focus "$pane" || true
    tmux display-message "started agent '$name'"
    ;;

  rename)
    pane="${1:-}"
    new=$(sanitize "${2:-}")
    [ -n "$pane" ] || die "rename: no pane given"
    [ -n "$new" ] || exit 0

    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    [ -n "${session:-}" ] || die "rename: $pane is gone"
    [ "$session" = "$new" ] && exit 0

    _t_rename_session "$session" "$new" 2>/dev/null \
      || die "rename: could not rename '$session' to '$new' (name taken?)"
    tmux display-message "renamed '$session' to '$new'"
    ;;

  alongside)
    pane="${1:-}"
    name=$(sanitize "${2:-}")
    [ -n "$pane" ] || die "agent alongside: no pane given"

    # Two queries, not one tab-split read via `< <(…)` — see the note in
    # agents.sh: process substitution dies under sh, which is what
    # run-shell uses, and this file gets called from there.
    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
    [ -n "${session:-}" ] || die "agent alongside: $pane is gone"

    _t_agent_alongside "$pane" "$name" >/dev/null \
      || die "agent alongside: could not start one in $cwd"
    tmux display-message "second agent in ${cwd##*/} (session $session)"
    ;;

  kill)
    pane="${1:-}"
    [ -n "$pane" ] || die "agent kill: no pane given"

    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
    [ -n "${session:-}" ] || die "agent kill: $pane is already gone"

    # When this is the session's only agent AND it has the window to itself,
    # _t_kill_agent takes the whole session — and if that's the session the
    # client is attached to, tmux pulls the ground out from under the popup we
    # were called from. Step onto another agent first, in that case only: a
    # pane- or window-scoped kill leaves the client where it is, and jumping
    # somewhere else would just be startling.
    panes=$(tmux list-panes -t "$win" -F x 2>/dev/null | wc -l | tr -d ' ')
    agents=$(_t_agent_rows | awk -F'\t' -v s="$session" '$5 == s' | wc -l | tr -d ' ')
    here=$(_t_client_session)
    if [ "${panes:-1}" -le 1 ] && [ "${agents:-0}" -le 1 ] && [ "$here" = "$session" ]; then
      away=$(_t_agent_rows | awk -F'\t' -v s="$session" '$5 != s { print $3; exit }')
      [ -n "$away" ] && _t_focus "$away" >/dev/null 2>&1
    fi

    _t_kill_agent "$pane" || die "agent kill: failed on $pane"
    tmux display-message "killed agent in '$session'"
    ;;

  *)
    die "agent actions: unknown command '$cmd'"
    ;;
esac
