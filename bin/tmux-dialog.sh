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

# $TMUX_AGENT_IN_POPUP is set (via display-popup -e) by whoever opens a popup, so
# anything running inside one knows it.
#
# ⚠️  Do NOT try to infer this from the environment. The obvious test — "$TMUX set
# but $TMUX_PANE empty" — is also true under `tmux run-shell`, which is exactly
# where the dialogs legitimately run, so it refused every real dialog and the
# picker just flashed. Worse, it looked fine under test: a tmux server started
# from inside a pane inherits that pane's $TMUX_PANE into its own environment and
# hands it to run-shell children, so the guard passed on the test server and
# failed on a real one. An explicit marker can't drift like that.
case "${1:-}" in
  --render-confirm|--render-input) ;;   # already inside the popup; that's the job
  *)
    if [ "${TMUX_AGENT_IN_POPUP:-}" = 1 ]; then
      tmux display-message "tmux-dialog: can't open a dialog inside a popup — see tmux-agent-pick.sh"
      # 2, never 1 and never 0: a caller doing `dialog confirm … || exit` must not
      # read this as an answer of any kind.
      exit 2
    fi
    ;;
esac

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
UI="$(dirname "$SELF")/tmux-ui.sh"
# shellcheck disable=SC1090
[ -r "$UI" ] && . "$UI"

MIN_WIDTH=44
MAX_WIDTH=92

# Single-quote for a shell command string: tmux hands the popup command to sh.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# _popup INTENT TITLE WIDTH HEIGHT COMMAND-STRING
#
# INTENT colours the border and the title together — red for a kill, amber for a
# rename, green for a new agent. The point is that the box tells you what kind of
# answer it wants before you have read it; a rename and a kill looked identical
# before, which is a poor property for the one that cannot be undone.
#
# ⚠️  ui_popup_style must expand UNQUOTED — it returns several flags as one
# string. It is generated here, not taken from anywhere a caller can reach.
_popup() {
  local intent="$1" title="$2" w="$3" h="$4" cmd="$5" style ttl
  style=$(ui_popup_style "$intent" 2>/dev/null) || style="-b rounded"
  ttl=$(ui_popup_title "$intent" "$title" 2>/dev/null) || ttl="$title"
  # shellcheck disable=SC2086
  if [ -n "${TMUX_AGENT_CLIENT:-}" ]; then
    tmux display-popup -c "$TMUX_AGENT_CLIENT" -E -w "$w" -h "$h" \
      $style -T "$ttl" "$cmd"
  else
    tmux display-popup -E -w "$w" -h "$h" $style -T "$ttl" "$cmd"
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
  # INTENT is optional and trails the existing arguments, so every current caller
  # keeps working and gets the neutral accent until it asks for another.
  confirm)
    title="${2:- confirm }"
    msg="${3:-Are you sure?}"
    intent="${4:-danger}"   # a confirm is nearly always about to destroy something
    _popup "$intent" "$title" "$(_width_for "$msg")" 7 \
      "$(_shq "$SELF") --render-confirm $(_shq "$msg") $(_shq "$intent")"
    ;;

  input)
    title="${2:- input }"
    prompt="${3:-Value}"
    out="${4:?input needs an output file}"
    default="${5:-}"
    intent="${6:-edit}"
    : > "$out"
    _popup "$intent" "$title" "$(_width_for "$prompt")" 8 \
      "$(_shq "$SELF") --render-input $(_shq "$prompt") $(_shq "$out") $(_shq "$default") $(_shq "$intent")"
    ;;

  # -------------------------------------------------------------------------
  # Rendered inside the popup. Not for calling directly.
  --render-confirm)
    msg="${2:-Are you sure?}"
    intent="${3:-danger}"
    # The accent again, inside the box this time, so the y/N prompt matches the
    # border rather than sitting in default white against a red frame.
    printf '\n  %s\n\n  %s[y/N]%s ' "$msg" \
      "$(ui_sgr "$(ui_intent_colour "$intent")" 2>/dev/null)" "$(ui_reset 2>/dev/null)"
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
    intent="${5:-edit}"
    acc="$(ui_sgr "$(ui_intent_colour "$intent")" 2>/dev/null)"
    rst="$(ui_reset 2>/dev/null)"
    if [ -n "$default" ]; then
      printf '\n  %s\n  %s(enter for %s)%s\n\n  %s>%s ' "$prompt" "$(printf '\033[2m')" "$default" "$(printf '\033[0m')" "$acc" "$rst"
    else
      printf '\n  %s\n  %s(enter on its own cancels)%s\n\n  %s>%s ' "$prompt" "$(printf '\033[2m')" "$(printf '\033[0m')" "$acc" "$rst"
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
