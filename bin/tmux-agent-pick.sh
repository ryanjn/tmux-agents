#!/usr/bin/env bash
# Dispatcher for prefix + a, and the orchestrator for the picker's dialogs.
#
#   tmux-agent-pick.sh [CLIENT_TTY]
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
DO="$DIR/tmux-agent-do.sh"
DIALOG="$DIR/tmux-dialog.sh"

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

if ! command -v fzf >/dev/null 2>&1; then
  # The menu runs in this process, where a plain export is enough. It asks its
  # questions with tmux's own confirm-before / command-prompt — status line
  # prompts, not overlays — so it needs none of the dance below.
  TMUX_AGENT_CLIENT="$CLIENT" exec "$DIR/tmux-agent-menu.sh"
fi

# ---------------------------------------------------------------------------
# Why this is a loop and not just one popup
# ---------------------------------------------------------------------------
# ⚠️  tmux allows exactly ONE overlay per client. A second `display-popup` from
# inside the first does not error — it returns **0** and silently never runs the
# command. A confirmation built that way "answers yes" without ever being shown,
# which briefly made ctrl-x kill agents with no prompt at all. `display-menu` from
# inside a popup is dropped the same way. So dialogs cannot stack on the picker.
#
# Instead the picker tells us what it wants and exits, which closes its popup and
# frees the overlay slot. We ask in a properly sized 7-line popup, act, and reopen
# the picker with the query it had — so the question is a small box rather than a
# prompt on an otherwise blank 90%-of-the-screen popup, and the list comes back
# where you left it.
#
# The picker writes one tab-separated line into $TMUX_AGENT_REQUEST:
#
#     kill   <pane> <label> <query>   ask, then kill
#     rename <pane> <name>  <query>   ask for a new name, then rename
#     new  <query> - <query>          name it, asking only if the query was empty
#
# An empty file means "nothing to do" — Esc, or an action the picker finished by
# itself (jump, alongside, files).
REQUEST=$(mktemp) || exit 0
QUERY=""

# ---------------------------------------------------------------------------
# Always succeed — enforced here, not just intended at the bottom
# ---------------------------------------------------------------------------
# The `exit 0` at the end of this file says this script never reports failure,
# because `run-shell` puts any non-zero status on screen as
# "'…/tmux-agent-pick.sh' returned N" — and non-zero is NORMAL here: switching
# the client tears the popup down mid-command, and Esc out of fzf is 130.
#
# That final line only covers the paths that reach it. A "returned 2" was seen
# in the wild that none of them explain, so the guarantee now lives in the EXIT
# trap, which runs however we leave — including paths that never reach the last
# line. `exit 0` inside an EXIT trap overrides the status bash was about to use.
#
# ⚠️  This suppresses the message, it does not hide the cause: a non-zero status
# is recorded with the line it came from. Nothing downstream is silenced either —
# every real failure is reported by tmux-agent-do.sh via display-message before
# it exits, which is a different mechanism entirely.
#
# A trap cannot fire if bash never started (a syntax error, a missing
# interpreter), so an empty log alongside a "returned N" is itself the answer:
# the failure was before the first line ran.
PICK_LOG="${TMPDIR:-/tmp}/tmux-agent-pick.log"
_pick_exit() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf '%s  exit=%s  line=%s  verb=%s  client=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "${BASH_LINENO[0]:-?}" \
      "${verb:-none}" "${CLIENT:-?}" >> "$PICK_LOG" 2>/dev/null
  fi
  rm -f "$REQUEST"
  exit 0
}
trap _pick_exit EXIT

while :; do
  : > "$REQUEST"

  # -c so the popup lands on the right client; -e because a popup's command comes
  # from the tmux server, so exporting in this process would not reach it.
  tmux display-popup -c "$CLIENT" \
    -e "TMUX_AGENT_CLIENT=$CLIENT" \
    -e "TMUX_AGENT_REQUEST=$REQUEST" \
    -e "TMUX_AGENT_QUERY=$QUERY" \
    -e "TMUX_AGENT_IN_POPUP=1" \
    -E -w 90% -h 80% "$DIR/tmux-agent-picker.sh"

  verb=""; arg1=""; arg2=""
  IFS=$'\t' read -r verb arg1 arg2 QUERY < "$REQUEST" 2>/dev/null
  [ -n "$verb" ] || break

  case "$verb" in
    kill)
      [ -n "$arg1" ] || continue
      # An agent mid-task is the exact thing this setup exists not to lose, so
      # this asks and defaults to no. Naming it in the question matters: "Kill the
      # agent in api-gateway?" is answerable, "Are you sure?" is not.
      if "$DIALOG" confirm " kill agent " "Kill the agent in ${arg2:-$arg1}?" danger; then
        "$DO" kill "$arg1"
      fi
      # Either way, back to the list: clearing out four finished agents should be
      # four answers, not four trips through the prefix key.
      ;;

    rename)
      [ -n "$arg1" ] || continue
      answer=$(mktemp) || break
      # Prefilled with the current name, so enter on its own is a no-op rather
      # than a mistake.
      "$DIALOG" input " rename agent " "New name for ${arg2:-this agent}" "$answer" "$arg2" edit
      newname=$(cat "$answer" 2>/dev/null)
      rm -f "$answer"
      [ -n "$newname" ] && "$DO" rename "$arg1" "$newname"
      ;;

    new)
      name="$arg1"
      if [ -z "$name" ]; then
        answer=$(mktemp) || break
        "$DIALOG" input " new agent " "Name for the new agent" "$answer" "" create
        name=$(cat "$answer" 2>/dev/null)
        rm -f "$answer"
      fi
      # Creating an agent switches the client to it, so this is the end of the
      # loop either way. Cancelling the dialog just stops.
      [ -n "$name" ] && "$DO" new "$name"
      break
      ;;

    *) break ;;
  esac
done

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
