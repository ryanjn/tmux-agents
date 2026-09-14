#!/usr/bin/env bash
# tmux-favorites-pick — Ctrl+b F: the favorites list in a popup; enter starts one.
#
#   tmux-favorites-pick.sh CLIENT_TTY
#
# Same shape as tmux-agent-pick.sh: the popup writes the choice to a request
# file, and the start happens OUT here through tmux-agent-do.sh's `new` verb —
# which is what makes a favorite's folder and command apply, and what makes
# picking one that is already running simply switch to it. Without fzf it is a
# tmux menu, up to nine entries.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO="$DIR/tmux-agent-do.sh"
CLIENT="${1:-}"
[ -n "$CLIENT" ] || CLIENT=$(tmux display-message -p '#{client_tty}' 2>/dev/null)

HELPERS="${TMUX_AGENTS_HOME:-$DIR/..}/shell"
# shellcheck disable=SC1090
. "$HELPERS/agents.sh" 2>/dev/null || true
. "$HELPERS/favorites.sh" 2>/dev/null || { tmux display-message "favorites: shell/favorites.sh not found"; exit 0; }
[ -r "$DIR/tmux-ui.sh" ] && . "$DIR/tmux-ui.sh"

# Inside the popup: show the list, write the pick.
if [ "${1:-}" = "--inside" ]; then
  running=$'\n'$(tmux list-sessions -F '#{session_name}' 2>/dev/null)$'\n'
  _tf_rows | while IFS=$'\t' read -r n target cmd note; do
    case "$running" in *$'\n'"$n"$'\n'*) mark="●" ;; *) mark=" " ;; esac
    printf '%s\t%s %-28s %s\n' "$n" "$mark" "$n" "$( [ "$note" = - ] || printf '%s' "$note" )"
  done | fzf --delimiter=$'\t' --with-nth=2.. --prompt='favorite> ' --reverse --height=100% \
             --header='enter start (● = running: switch to it)   esc cancel   tf add / tf edit to change the list' \
             --color "$(ui_fzf_colors 2>/dev/null)" | cut -f1 > "${TMUX_AGENT_REQUEST:?}"
  exit 0
fi

rows=$(_tf_rows)
[ -n "$rows" ] || { tmux display-message "no favorites yet — tf add NAME (or just: tf add, inside an agent's session)"; exit 0; }

if ! command -v fzf >/dev/null 2>&1; then
  args=( -T " favorites " -x C -y C )
  i=0
  while IFS=$'\t' read -r n target cmd note; do
    i=$((i + 1)); [ "$i" -le 9 ] || break
    args+=( "$n$( [ "$note" = - ] || printf ' — %s' "$note" )" "$i" "run-shell \"TMUX_AGENT_CLIENT=$CLIENT '$DO' new '$n'\"" )
  done <<< "$rows"
  exec tmux display-menu "${args[@]}"
fi

REQUEST=$(mktemp) || exit 0
trap 'rm -f "$REQUEST"' EXIT
tmux display-popup -c "$CLIENT" -e "TMUX_AGENT_REQUEST=$REQUEST" -e "TMUX_AGENT_IN_POPUP=1" \
  -E -w 70% -h 60% "$0 --inside"
name=$(cat "$REQUEST" 2>/dev/null)
[ -n "$name" ] && TMUX_AGENT_CLIENT="$CLIENT" "$DO" new "$name"
exit 0
