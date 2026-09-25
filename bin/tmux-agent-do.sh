#!/usr/bin/env bash
# tmux-agent-do — the verbs behind the agent picker.
#
# The picker (fzf) and the menu fallback (display-menu) both shell out to this
# instead of running tmux commands themselves, so "new agent" means exactly the
# same thing however you got there. The logic itself lives in the shell helpers
# (shell/agents.sh) so it's callable from a plain prompt too.
#
#   tmux-agent-do.sh focus        PANE          jump to that agent
#   tmux-agent-do.sh new          NAME|REPO     new agent session named NAME —
#                                               or named after REPO, checked out
#   tmux-agent-do.sh alongside    PANE [NAME]   new agent in PANE's session and cwd
#   tmux-agent-do.sh split        PANE [NAME]   same, but in a new PANE beside it
#   tmux-agent-do.sh gather       DST SRC       MOVE the running agent SRC into DST's window
#   tmux-agent-do.sh home         PANE          undo a gather — break it back out
#   tmux-agent-do.sh kill         PANE          kill that agent, and nothing else
#   tmux-agent-do.sh restart      PANE          exit the agent and resume the same
#                                               conversation, in place
#   tmux-agent-do.sh sleep        PANE          exit the agent but keep its exact
#                                               conversation, to be woken later
#   tmux-agent-do.sh wake         PANE          bring a sleeping agent back on that
#                                               same conversation
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

# The sleep/wake helpers live beside the persistence scripts rather than in the
# canonical upstream file, so they are sourced separately and optionally.
PERSIST="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/tmux-persist.sh"
# shellcheck disable=SC1090
[ -r "$PERSIST" ] && . "$PERSIST"
FAVORITES="${PERSIST%/*}/favorites.sh"
[ -r "$FAVORITES" ] && . "$FAVORITES"

if ! declare -F _t_new_session >/dev/null 2>&1; then
  tmux display-message "agent actions: helpers not found at $HELPERS"
  exit 1
fi

# Errors go to the tmux message line, not stdout: half of these run under
# `run-shell`, where nothing has a terminal to print to.
# ⚠️  -d 0 holds the message until a key is pressed. display-time here is 750ms,
# which is long enough to notice an error and far too short to read one — a failed
# checkout "flashed too quickly to see" and the reason was simply lost. Successes
# still use the default; it is only failure that has to survive being blinked at.
die() {
  tmux display-message -d 0 "$1"
  exit 1
}

# A name typed into a prompt becomes a session name AND a directory name, so
# keep it to something safe rather than rejecting it and making them retype.
# ⚠️  The dot goes too, and it is the one that matters. tmux parses a target as
# session:window.pane, so "prescribing-activation-2.0" produces a session that
# cannot be addressed by name — not to add its shell window, not to jump to it,
# not to kill it. Typing that used to leave a half-built agent the picker could
# not remove. Converted rather than rejected: the picker reports the name it
# actually created, so "2.0" quietly becoming "2-0" is visible and keeps you moving.
sanitize() {
  local n="$1"
  n="${n//[^A-Za-z0-9_-]/-}"                           # spaces, slashes, quotes, DOTS -> dash
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

    # ⚠️  Going to a SLEEPING agent means bringing it back, not landing on the
    # bare shell its pane is parked at. Selecting one from the picker and
    # pressing enter used to drop you at a `bash-3.2$` prompt with no indication
    # of what to do — and typing `exit` there closes the pane, which takes the
    # window and the @agent-session-id pane option with it. That is how an agent
    # gets "lost": the session survives with only its shell window, and the id is
    # then only recoverable from the last snapshot.
    #
    # A pane carrying @agent-session-id whose foreground process is a plain shell
    # is exactly the sleeping case, and _t_agent_restart already handles "resume a
    # pane whose agent has exited", on the exact conversation.
    # _t_wake_pane holds this rule; `t NAME` wakes through the same one, so the
    # picker and the shell command cannot drift apart on what "go to it" means.
    if declare -F _t_wake_pane >/dev/null 2>&1; then
      sid=$(tmux show-options -pqv -t "$pane" @agent-session-id 2>/dev/null)
      cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
      case "${sid:+set}${cur##*/}" in
        setbash|setzsh|setsh|setdash|setfish|setksh)
          tmux display-message "waking '$(tmux display-message -p -t "$pane" '#{session_name}')'…" ;;
      esac
      _t_wake_pane "$pane" || true
    fi

    _t_focus "$pane" || die "agent focus: $pane is gone"
    ;;

  new)
    # A repo typed where a name goes gets cloned, and names the session. Tested
    # BEFORE sanitize, which would turn the identifying slash into a dash and
    # leave you with a session called "owner-repo" and an empty folder.
    repo=""
    if _t_is_repo_spec "${1:-}"; then
      repo="$1"
      name=$(_t_repo_name "$repo")
    else
      name=$(sanitize "${1:-}")
    fi
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

    # A clone takes seconds to minutes with nothing on screen — this runs under
    # `run-shell`, which has no tty for git's progress to reach. Say what is
    # happening first, and point at the log if it doesn't work out.
    [ -n "$repo" ] && tmux display-message -d 0 "checking out $repo into '$name'…"

    # ⚠️  Keep stderr. It was going to /dev/null, so the ONE line that says what
    # actually went wrong ("… already has something in it", "could not work out a
    # name") was discarded and replaced with a guess that pointed at a clone log
    # which, for any failure before the clone, had never been created. Report what
    # the helper said; fall back to the log only when it said nothing.
    # A favorite of this name supplies its folder/repo and window-1 command,
    # exactly as `t NAME` would — the picker and the prompt agree.
    fav_dir=""; fav_cmd=""
    if [ -z "$repo" ] && declare -F _t_favorite_defaults >/dev/null 2>&1; then
      _t_favorite_defaults "$name"
      [ -n "$fav_cmd" ] && T_AUTOSTART="$fav_cmd"
    fi
    err=$(mktemp) || die "new agent: no temp file"
    pane=$(_t_new_session "$name" "$fav_dir" "$repo" 2>"$err")
    if [ -z "$pane" ]; then
      reason=$(grep -v '^[[:space:]]*$' "$err" 2>/dev/null | tail -1)
      rm -f "$err"
      [ -n "$reason" ] && die "${reason#t: }"
      [ -n "$repo" ] &&
        die "new agent: could not check out '$repo' — see ${TMPDIR:-/tmp}/t-checkout-$name.log"
      die "new agent: could not create '$name'"
    fi
    rm -f "$err"
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

  gather)
    # DST first, SRC second — "pull SRC to where I am", so the destination is the
    # subject. The picker passes the client's own pane as DST.
    dst="${1:-}"
    src="${2:-}"
    [ -n "$dst" ] || die "agent gather: no destination pane given"
    [ -n "$src" ] || die "agent gather: no agent given"

    label=$(_t_agent_display | awk -F'\t' -v p="$src" '$1 == p { print $6; exit }')
    err=$(_t_agent_gather "$dst" "$src" 2>&1 >/dev/null) || die "${err:-agent gather: failed}"
    tmux display-message "pulled in ${label:-that agent} — Ctrl+b B sends it back"
    ;;

  home)
    pane="${1:-}"
    [ -n "$pane" ] || die "agent home: no pane given"
    # Reports its own outcome: where it went depends on whether the origin
    # session is still alive, and that is the thing worth knowing.
    _t_agent_send_home "$pane" || die "agent home: could not move $pane"
    ;;

  split)
    pane="${1:-}"
    name=$(sanitize "${2:-}")
    [ -n "$pane" ] || die "agent split: no pane given"

    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
    [ -n "${session:-}" ] || die "agent split: $pane is gone"

    _t_agent_split "$pane" "$name" >/dev/null \
      || die "agent split: could not start one in $cwd"
    # Deliberately quiet on success. This is bound to a key you press three or
    # four times in a row, and _t_agent_split already speaks up for the one thing
    # worth saying (panes too narrow to read).
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

  sleep)
    # ⚠️  $1, not $2 — the dispatcher shifts the verb off above, so every branch
    # here sees the pane as $1. Copied the index out of the usage comment at the
    # top of this file instead of the branch next door, and it failed as
    # "no pane given" on a pane that was plainly given.
    pane="${1:-}"
    [ -n "$pane" ] || die "agent sleep: no pane given"
    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    [ -n "${session:-}" ] || die "agent sleep: $pane is gone"
    declare -F tsleep >/dev/null 2>&1 || die "agent sleep: helpers not found at $PERSIST"
    tmux display-message "putting the agent in '$session' to sleep…"
    out=$(tsleep "$pane" 2>&1) || die "agent sleep: ${out:-failed}"
    case "$out" in
      # tsleep exits 0 when it finds nothing to do, so say so rather than
      # reporting a sleep that never happened.
      *"nothing to sleep"*)
        tmux display-message "no running agent in '$session' — already asleep?" ;;
      *)
        tmux display-message "'$session' asleep — Ctrl+b R wakes it on the same conversation" ;;
    esac
    ;;
  wake)
    # Waking IS restarting a pane whose agent has already exited — _t_agent_restart
    # handles exactly that case, and resolves the exact session id rather than
    # falling back to --continue. Separate verb only so the messages say "wake".
    pane="${1:-}"
    [ -n "$pane" ] || die "agent wake: no pane given"
    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    [ -n "${session:-}" ] || die "agent wake: $pane is gone"
    tmux display-message "waking the agent in '$session'…"
    err=$(_t_agent_restart "$pane" 2>&1 >/dev/null) || die "agent wake: ${err:-failed}"
    tmux display-message "'$session' waking on its own conversation"
    ;;

  restart)
    pane="${1:-}"
    [ -n "$pane" ] || die "agent restart: no pane given"

    session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
    [ -n "${session:-}" ] || die "agent restart: $pane is gone"

    # The TERM-grace poll in the helper can take seconds; say so first, or the
    # keypress looks like it did nothing. The binding runs this under
    # `run-shell -b` for the same reason — without -b those seconds freeze the
    # whole tmux server, every session, not just this pane.
    tmux display-message "restarting agent in '$session'…"
    err=$(_t_agent_restart "$pane" 2>&1 >/dev/null) || die "agent restart: ${err:-failed}"
    tmux display-message "restarted agent in '$session' — resuming last conversation"
    ;;

  *)
    die "agent actions: unknown command '$cmd'"
    ;;
esac
