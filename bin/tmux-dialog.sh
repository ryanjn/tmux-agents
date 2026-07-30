#!/usr/bin/env bash
# tmux-dialog — small centred dialogs, drawn as a tmux popup ON TOP of whatever
# popup asked for one.
#
#   tmux-dialog.sh confirm TITLE MESSAGE            exit 0 = yes, 1 = no/cancel
#   tmux-dialog.sh input   TITLE PROMPT OUT [DEF]   writes the answer to OUT
#
# Why a popup rather than just prompting where we already are: the picker fills
# 90% of the screen, so a bare `read` in it turns a y/N question into a full-pane
# takeover with one line of text on it. A 7-line box is the right size for a
# yes/no.
#
# ⚠️  MUST NOT be called from inside a popup. tmux allows exactly ONE overlay per
# client, and a second `display-popup` does not fail — it returns **0** and never
# runs your command. For a confirmation that is the worst possible failure: rc 0
# reads as "yes", so the caller proceeds without ever having asked. That is a real
# bug this file used to have; the guard below is why it can't come back.
# (`display-menu` from inside a popup is silently dropped the same way.)
#
# So dialogs are driven from OUTSIDE the popup — tmux-agent-pick.sh closes the
# picker, asks, acts, and reopens it. See the loop there.
#
# $TMUX_AGENT_CLIENT (set by the pick dispatchers) targets the client that asked.
# Without it tmux picks a client itself, which inside a popup means "possibly the
# wrong terminal window" — see tmux-agent-pick.sh.
set -u

# Inside a popup tmux leaves $TMUX_PANE empty while $TMUX is still set — the same
# quirk that breaks switch-client in there. That's our "am I in a popup" test.
if [ -n "${TMUX:-}" ] && [ -z "${TMUX_PANE:-}" ] && [ "${1:-}" != "--render-confirm" ] &&
   [ "${1:-}" != "--render-input" ]; then
  tmux display-message "tmux-dialog: refusing to open a popup inside a popup"
  # 2, never 1 and never 0: a caller doing `dialog confirm … || exit` must not
  # read this as an answer of any kind.
  exit 2
fi

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

MIN_WIDTH=44
MAX_WIDTH=92

# Single-quote for a shell command string: tmux hands the popup command to sh.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# _popup TITLE WIDTH HEIGHT COMMAND-STRING
_popup() {
  local title="$1" w="$2" h="$3" cmd="$4"
  if [ -n "${TMUX_AGENT_CLIENT:-}" ]; then
    tmux display-popup -c "$TMUX_AGENT_CLIENT" -E -w "$w" -h "$h" \
      -b rounded -T "$title" "$cmd"
  else
    tmux display-popup -E -w "$w" -h "$h" -b rounded -T "$title" "$cmd"
  fi
}

# Wide enough for the message, never wider than the screen wants to be.
_width_for() {
  local n=$(( ${#1} + 8 ))
  [ "$n" -lt "$MIN_WIDTH" ] && n=$MIN_WIDTH
  [ "$n" -gt "$MAX_WIDTH" ] && n=$MAX_WIDTH
  printf '%s' "$n"
}

case "${1:-}" in

  # -------------------------------------------------------------------------
  confirm)
    title="${2:- confirm }"
    msg="${3:-Are you sure?}"
    _popup "$title" "$(_width_for "$msg")" 7 "$(_shq "$SELF") --render-confirm $(_shq "$msg")"
    ;;

  input)
    title="${2:- input }"
    prompt="${3:-Value}"
    out="${4:?input needs an output file}"
    default="${5:-}"
    : > "$out"
    _popup "$title" "$(_width_for "$prompt")" 8 \
      "$(_shq "$SELF") --render-input $(_shq "$prompt") $(_shq "$out") $(_shq "$default")"
    ;;

  # -------------------------------------------------------------------------
  # Rendered inside the popup. Not for calling directly.
  --render-confirm)
    msg="${2:-Are you sure?}"
    printf '\n  %s\n\n  [y/N] ' "$msg"
    # One keypress, no Enter — this is a yes/no, not a form. -s so the answer
    # doesn't echo into the box after we've already printed it ourselves.
    if ! IFS= read -rsn1 answer; then answer=""; fi
    case "$answer" in
      y|Y) printf 'yes\n'; exit 0 ;;
      *)   printf 'no\n';  exit 1 ;;
    esac
    ;;

  --render-input)
    prompt="${2:-Value}"
    out="${3:?}"
    default="${4:-}"
    if [ -n "$default" ]; then
      printf '\n  %s\n  %s(enter for %s)%s\n\n  > ' "$prompt" "$(printf '\033[2m')" "$default" "$(printf '\033[0m')"
    else
      printf '\n  %s\n  %s(enter on its own cancels)%s\n\n  > ' "$prompt" "$(printf '\033[2m')" "$(printf '\033[0m')"
    fi
    # -e for line editing. NOT -i for the default: that's bash 4+, and macOS ships
    # bash 3.2, so the default is shown above and applied when the answer is empty.
    if ! IFS= read -re answer; then answer=""; fi
    [ -n "$answer" ] || answer="$default"
    [ -n "$answer" ] || exit 1
    printf '%s' "$answer" > "$out"
    ;;

  *)
    printf 'usage: %s {confirm TITLE MESSAGE | input TITLE PROMPT OUTFILE [DEFAULT]}\n' \
      "$(basename "$SELF")" >&2
    exit 2
    ;;
esac
