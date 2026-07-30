#!/usr/bin/env bash
# tmux-agent-picker — fzf picker for Claude Code agents, with a live preview of
# each agent's actual screen.
#
# Runs inside `tmux display-popup -E`, launched by prefix + a via
# tmux-agent-pick.sh. Falls back to tmux-agent-menu.sh where fzf isn't present.
#
#   enter    jump to that agent
#   ctrl-n   start a new agent — named from whatever you've typed in the prompt,
#            or from a dialog if you've typed nothing
#   ctrl-s   start a second agent alongside the highlighted one, same folder
#   ctrl-x   kill the highlighted agent, after a confirmation dialog
#   ctrl-f   browse the highlighted agent's files
#   ctrl-r   refresh the list and previews
#   esc      cancel
#
# ctrl-n costs you fzf's default "move down" binding. Arrows still work, and
# "new" is the one verb worth a mnemonic key.
#
# ctrl-x and ctrl-n do NOT act here. They write what they want to
# $TMUX_AGENT_REQUEST and exit; tmux-agent-pick.sh then asks the question in a
# small popup and reopens this picker. That indirection isn't architecture for its
# own sake: tmux allows one overlay per client, and a dialog opened from inside
# this popup is silently dropped while reporting success — see the warning in
# tmux-agent-pick.sh.
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
#
# The age column sits between the glyph and the name, padded even when empty, so
# the name column stays put whether or not anything is waiting. Waiting-first
# ordering comes from _t_agent_display and fzf preserves it for an empty query.
_list() {
  _t_agent_display |
    awk -F'\t' '{ printf "%s\t%s\t%s\t%s %-4s %-30s %s\n", $1, $2, $3, $4, $8, $6, $7 }'
}

# ---------------------------------------------------------------------------
# Preview: what it's saying, and what it has done to the repo
# ---------------------------------------------------------------------------
# The screen alone tells you what the agent is talking about. The header tells you
# whether it has left uncommitted work behind — the thing you'd otherwise have to
# visit every agent to find out.
#
# ⚠️  --no-optional-locks matters. A plain `git status` can take the index lock,
# and these repos have live agents writing to them; this runs on every cursor
# move. Read-only or not at all.
_preview() {
  local pane="${1:-}" cwd="${2:-}" branch dirty
  if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
    # Detached HEAD reads as the literal word "HEAD", which tells you nothing.
    [ "$branch" = HEAD ] &&
      branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -c .)
    if [ "${dirty:-0}" -gt 0 ]; then
      printf '%s · %s +%s uncommitted\n\n' "${cwd##*/}" "$branch" "$dirty"
    else
      printf '%s · %s clean\n\n' "${cwd##*/}" "$branch"
    fi
  fi
  [ -n "$pane" ] && tmux capture-pane -pe -t "$pane" 2>/dev/null | tail -n 60
  return 0
}

case "${1:-}" in
  --list)    _list; exit 0 ;;
  --preview) shift; _preview "${1:-}" "${2:-}"; exit 0 ;;
esac

# One tab-separated line for tmux-agent-pick.sh to act on once this popup is out
# of the way. Field 4 is the query, so the reopened picker lands where you left it.
_request() {
  [ -n "${TMUX_AGENT_REQUEST:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" "${4:-}" > "$TMUX_AGENT_REQUEST"
}

rows=$(_list)

# Nothing running: no list to show, but "start one" is the likeliest reason you
# pressed the key, so ask for a name instead of reporting an empty box.
if [ -z "$rows" ]; then
  _request new "" "" ""
  exit 0
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
    --preview "$0 --preview {1} {3}" \
    --preview-window='right,60%,border-left' \
    --header='enter jump   ctrl-n new   ctrl-s alongside   ctrl-x kill   ctrl-f files   ctrl-r refresh' \
    --prompt='agent> ' \
    --query "${TMUX_AGENT_QUERY:-}" \
    --reverse --cycle --height=100% \
    --bind "ctrl-r:reload($0 --list)"
)

query=$(printf '%s\n' "$out" | sed -n 1p)
key=$(printf '%s\n' "$out" | sed -n 2p)
sel=$(printf '%s\n' "$out" | sed -n 3p)

pane=""
cwd=""
if [ -n "$sel" ]; then
  IFS=$'\t' read -r pane _session cwd _rest <<< "$sel"
fi

case "$key" in

  ctrl-n)
    # A non-empty query is almost always the name you want, so it goes straight
    # through and no dialog appears: type it, hit ctrl-n, done.
    _request new "$query" "" "$query"
    exit 0
    ;;

  ctrl-x)
    [ -n "$pane" ] || exit 0
    # Ask _t_agent_display for the label rather than scraping it back out of the
    # display column: it's "api-gateway", or "api-gateway:claude2" when a session
    # holds two agents, and that's what the question needs to name.
    label=$(_t_agent_display | awk -F'\t' -v p="$pane" '$1 == p { print $6; exit }')
    _request kill "$pane" "$label" "$query"
    exit 0
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

esac

# Plain enter: jump to it. fzf exits non-zero on esc, so an empty selection here
# just means "cancelled".
[ -n "$pane" ] || exit 0
exec "$DO" focus "$pane"
