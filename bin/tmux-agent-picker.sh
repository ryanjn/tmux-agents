#!/usr/bin/env bash
# tmux-agent-picker — fzf picker for Claude Code agents, with a live preview of
# each agent's actual screen.
#
# Runs inside `tmux display-popup -E`, launched by prefix + a via
# tmux-agent-pick.sh. Falls back to tmux-agent-menu.sh where fzf isn't present.
#
#   enter    jump to that agent
#   ctrl-n   start a new agent — named from whatever you've typed in the prompt,
#            or from a follow-up prompt if you've typed nothing
#   ctrl-s   start a second agent alongside the highlighted one, same folder
#   ctrl-x   kill the highlighted agent (asks first), then back to the list
#   ctrl-f   browse the highlighted agent's files
#   ctrl-r   refresh the list and previews
#   esc      cancel
#
# ctrl-n costs you fzf's default "move down" binding. Arrows still work, and
# "new" is the one verb worth a mnemonic key.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO="$DIR/tmux-agent-do.sh"

# The shell helpers hold the agent classifier and the session/kill logic, so this
# and the picker share one definition of what an agent is. Found relative to this
# script rather than at a fixed path: the repo has to work wherever it is cloned.
HELPERS="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/agents.sh"
if [ -r "$HELPERS" ]; then
  # shellcheck disable=SC1090
  . "$HELPERS"
fi

# Fields 1-3 (pane id, session, cwd) are what the actions target; everything
# from field 4 on is display, which is what --with-nth=4.. shows and searches.
_list() {
  _t_agent_display | awk -F'\t' '{ printf "%s\t%s\t%s\t%s  %-30s %s\n", $1, $2, $3, $4, $6, $7 }'
}

if [ "${1:-}" = "--list" ]; then
  _list
  exit 0
fi

rows=$(_list)

# With nothing running there's nothing to preview or kill — but "start one" is
# still the likeliest reason you hit the key, so prompt for a name rather than
# just reporting an empty list.
if [ -z "$rows" ]; then
  printf 'no agents running.  name a new one (enter to cancel): '
  read -r name || exit 0
  [ -n "$name" ] || exit 0
  exec "$DO" new "$name"
fi

# --print-query puts the query on line 1 and --expect the key on line 2, so the
# selected row is line 3. Verified against fzf 0.74: on esc you get the query
# plus an empty key line and no third line; on a key with no matches you get the
# key and no third line.
out=$(
  printf '%s\n' "$rows" | fzf \
    --delimiter=$'\t' \
    --with-nth=4.. \
    --print-query \
    --expect=ctrl-n,ctrl-s,ctrl-x,ctrl-f \
    --preview 'tmux capture-pane -pe -t {1} | tail -n 60' \
    --preview-window='right,60%,border-left' \
    --header='enter jump   ctrl-n new   ctrl-s alongside   ctrl-x kill   ctrl-f files   ctrl-r refresh' \
    --prompt='agent> ' \
    --reverse --cycle --height=100% \
    --bind "ctrl-r:reload($0 --list)"
)

query=$(printf '%s\n' "$out" | sed -n 1p)
key=$(printf '%s\n' "$out" | sed -n 2p)
sel=$(printf '%s\n' "$out" | sed -n 3p)

pane=""
session=""
cwd=""
if [ -n "$sel" ]; then
  IFS=$'\t' read -r pane session cwd _rest <<< "$sel"
fi

case "$key" in

  ctrl-n)
    # Whatever you typed to filter the list is almost always the name you want:
    # prefix + a, type the name, ctrl-n — no second prompt. Only asks when the
    # query is empty.
    name="$query"
    if [ -z "$name" ]; then
      printf 'new agent name (enter to cancel): '
      read -r name || exit 0
    fi
    [ -n "$name" ] || exit 0
    exec "$DO" new "$name"
    ;;

  ctrl-s)
    [ -n "$pane" ] || exit 0
    exec "$DO" alongside "$pane"
    ;;

  ctrl-f)
    # Hand this popup over to the file browser rather than opening a second one
    # on top of it — nested popups are a fight with tmux that buys nothing, and
    # exec'ing reuses the tty we already have. cwd comes from the row, so this
    # browses the HIGHLIGHTED agent's folder, not the one you pressed the key in.
    [ -n "$cwd" ] || exit 0
    export TMUX_FILE_ROOT="$cwd"
    export TMUX_FILE_PANE="$pane"
    exec "$DIR/tmux-file-picker.sh"
    ;;

  ctrl-x)
    [ -n "$pane" ] || exit 0
    # An agent mid-task is the exact thing this setup exists not to lose, so
    # this one asks, and defaults to no.
    printf 'kill the agent in %s? [y/N] ' "$session"
    read -r ans || exit 0
    case "$ans" in
      y|Y|yes|YES)
        "$DO" kill "$pane" || exit 1
        # Straight back to the list, so clearing out four finished agents is
        # four keystrokes rather than four trips through the prefix key.
        exec "$0"
        ;;
    esac
    exit 0
    ;;

esac

# Plain enter: jump to it. fzf exits non-zero on esc, so an empty selection here
# just means "cancelled".
[ -n "$pane" ] || exit 0
exec "$DO" focus "$pane"
