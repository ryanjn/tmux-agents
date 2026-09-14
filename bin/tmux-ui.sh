#!/usr/bin/env bash
# tmux-ui — one palette and one set of box-drawing helpers for every overlay in
# this repo, so the picker, the dialogs and the file browser look like one tool
# rather than three.
#
# Sourced, never executed:
#
#   . "$(dirname "$0")/tmux-ui.sh"
#
# ---------------------------------------------------------------------------
# The palette
# ---------------------------------------------------------------------------
# Taken from ~/.tmux.conf's status bar rather than invented, so an overlay opens
# into the same colours as the bar underneath it: bg 234, fg 250, dim 244, and
# 39 as the accent (it's the `status-left` session badge).
#
# The three intent colours are the only additions. They exist so that WHAT AN
# OVERLAY WILL DO is legible before you read a word of it — a red border is a
# question you should read twice, a green one is making something new.
#
# 256-colour indexes, not RGB: `default-terminal` is tmux-256color, and while
# terminal-features adds RGB for the outer terminal, indexes are what the status
# bar already uses and what degrades sanely everywhere else.
#
# ⚠️  Stored as BARE NUMBERS. tmux wants "colour203" and an ANSI SGR wants "203",
# and the two are not interchangeable: `\033[38;5;colour203m` is not a valid
# escape, so a palette written tmux's way renders as literal "olour203m" spray
# across the card. The number is the common form; ui_tmux_colour() adds tmux's
# prefix at the one boundary that needs it.
TMUX_UI_BG="${TMUX_UI_BG:-234}"
TMUX_UI_FG="${TMUX_UI_FG:-252}"
TMUX_UI_DIM="${TMUX_UI_DIM:-244}"
TMUX_UI_SEL="${TMUX_UI_SEL:-238}"
TMUX_UI_ACCENT="${TMUX_UI_ACCENT:-39}"    # blue   — neutral / browse
TMUX_UI_DANGER="${TMUX_UI_DANGER:-203}"   # red    — destroys something
TMUX_UI_CREATE="${TMUX_UI_CREATE:-78}"    # green  — makes something
TMUX_UI_EDIT="${TMUX_UI_EDIT:-214}"       # amber  — changes something

# ui_tmux_colour N — the same colour spelled the way tmux options want it.
ui_tmux_colour() { printf 'colour%s' "$1"; }

# ui_intent_colour INTENT — the accent for a kind of action.
# Anything unrecognised gets the neutral accent, so a new verb is never invisible.
ui_intent_colour() {
  case "${1:-}" in
    danger|kill|destroy) printf '%s' "$TMUX_UI_DANGER" ;;
    create|new)          printf '%s' "$TMUX_UI_CREATE" ;;
    edit|rename)         printf '%s' "$TMUX_UI_EDIT" ;;
    *)                   printf '%s' "$TMUX_UI_ACCENT" ;;
  esac
}

# ui_popup_style INTENT — the -s/-S/-b flags for `display-popup`, as one string
# for the caller to expand unquoted.
#
# ⚠️  Border lines and border STYLE are different tmux settings: -b picks the
# glyphs (rounded/heavy/double), -S colours them. Setting only -S leaves you with
# a coloured square-cornered box that matches nothing else here.
ui_popup_style() {
  local c
  c=$(ui_tmux_colour "$(ui_intent_colour "${1:-}")")
  printf -- '-b rounded -s bg=%s,fg=%s -S fg=%s,bg=%s' \
    "$(ui_tmux_colour "$TMUX_UI_BG")" "$(ui_tmux_colour "$TMUX_UI_FG")" \
    "$c" "$(ui_tmux_colour "$TMUX_UI_BG")"
}

# ui_popup_title INTENT TEXT — a title styled to match its border.
# tmux parses #[…] in -T, so the colour has to be spelled its way, not in ANSI.
ui_popup_title() {
  printf '#[fg=%s,bold] %s #[default]' \
    "$(ui_tmux_colour "$(ui_intent_colour "${1:-}")")" "${2:-}"
}

# ui_fzf_colors — an fzf --color spec in the same palette.
# Kept to fzf's own names so a future fzf can add fields without this fighting it.
# bg:-1 keeps the popup's own background rather than painting a second one over it.
ui_fzf_colors() {
  printf 'bg:-1,fg:%s,hl:%s,fg+:%s,bg+:%s,hl+:%s,border:%s,header:%s,info:%s,prompt:%s,pointer:%s,marker:%s,spinner:%s' \
    "$TMUX_UI_FG" "$TMUX_UI_ACCENT" "$TMUX_UI_FG" "$TMUX_UI_SEL" "$TMUX_UI_ACCENT" \
    "$TMUX_UI_DIM" "$TMUX_UI_DIM" "$TMUX_UI_DIM" "$TMUX_UI_ACCENT" \
    "$TMUX_UI_ACCENT" "$TMUX_UI_ACCENT" "$TMUX_UI_ACCENT"
}

# ---------------------------------------------------------------------------
# Drawing a card in the middle of a popup we already have
# ---------------------------------------------------------------------------
# ⚠️  This exists because tmux allows exactly ONE overlay per client. A second
# `display-popup` from inside the first returns 0 and silently runs nothing — so
# a confirmation asked that way answers "yes" without appearing. The old fix was
# to close the picker, ask in a fresh popup, and reopen: correct, but you watch a
# full-screen overlay vanish, a small box appear somewhere else, and the list
# come back. Drawing into the popup we are already inside is not a second overlay
# and has none of that.
#
# 256-colour SGR by hand rather than tput: tput setaf inside a popup resolves
# against the popup's TERM, which is not always the outer terminal's, and gets
# 8-colour approximations of the palette above.
ui_sgr()   { printf '\033[38;5;%sm' "$1"; }
ui_bold()  { printf '\033[1m'; }
ui_reset() { printf '\033[0m'; }

# ui_term_size — "ROWS COLS" for the terminal we are actually drawing on.
#
# ⚠️  NOT `tput lines` / `tput cols`. Inside a tmux popup those report 80x24 —
# the terminfo entry's default — no matter how big the popup is. Measured in a
# 90%x80% popup on a 200x60 client: tput said 80x24, the popup was 178x46.
#
# The failure is invisible at exactly one size. A card centred for 80x24 inside a
# 178x46 popup lands high and to the left, hugging nothing, which is precisely
# how it looked in the wild; it was verified against an 80x24 test terminal where
# the wrong answer and the right answer are the same number.
#
# `stty size` reads the window size from the controlling terminal itself, so it
# is right wherever this runs. tput stays as the fallback for the case where
# /dev/tty cannot be opened at all.
ui_term_size() {
  local sz rows cols
  sz=$(stty size </dev/tty 2>/dev/null)
  rows="${sz%% *}"; cols="${sz##* }"
  case "${rows:-}" in ''|*[!0-9]*) rows="" ;; esac
  case "${cols:-}" in ''|*[!0-9]*) cols="" ;; esac
  if [ -z "$rows" ] || [ -z "$cols" ] || [ "$rows" -lt 1 ] || [ "$cols" -lt 1 ]; then
    cols=$(tput cols 2>/dev/null); rows=$(tput lines 2>/dev/null)
  fi
  case "${rows:-}" in ''|*[!0-9]*) rows=24 ;; esac
  case "${cols:-}" in ''|*[!0-9]*) cols=80 ;; esac
  [ "$rows" -lt 1 ] && rows=24
  [ "$cols" -lt 1 ] && cols=80
  printf '%s %s' "$rows" "$cols"
}

# ui_card INTENT TITLE LINE... — a centred rounded card. Lines are printed in
# order; an empty argument is a blank line.
#
# A line starting with "~" is rendered dim — for hints and key legends.
#
# ⚠️  The marker exists so the width maths can stay honest. Colour has to be
# applied while printing, never baked into the string: SGR escapes are
# zero-width on screen but count in ${#s}, so a pre-coloured line measures ~10
# characters too long and pushes the right border out by exactly that much.
#
# Width comes from the longest line, so a card never wraps and never leaves a
# corridor of empty box around a short question. Height is derived, not assumed:
# getting it wrong scrolls the popup and leaves half a border behind.
ui_card() {
  local intent="$1" title="$2"; shift 2
  local -a lines=("$@")
  local c cols rows w h top left i pad text
  c=$(ui_intent_colour "$intent")

  read -r rows cols <<< "$(ui_term_size)"

  w=$(( ${#title} + 6 ))
  for i in "${lines[@]}"; do
    text="${i#\~}"
    [ $(( ${#text} + 6 )) -gt "$w" ] && w=$(( ${#text} + 6 ))
  done
  [ "$w" -lt 34 ] && w=34
  [ "$w" -gt $(( cols - 4 )) ] && w=$(( cols - 4 ))

  h=$(( ${#lines[@]} + 4 ))
  top=$(( (rows - h) / 2 )); [ "$top" -lt 1 ] && top=1
  left=$(( (cols - w) / 2 )); [ "$left" -lt 1 ] && left=1

  printf '\033[2J\033[H'                       # clear whatever fzf left behind
  printf '\033[%d;%dH' "$top" "$left"
  ui_sgr "$c"; printf '╭─'; ui_reset
  ui_sgr "$c"; ui_bold; printf ' %s ' "$title"; ui_reset
  ui_sgr "$c"
  pad=$(( w - ${#title} - 5 ))
  while [ "$pad" -gt 0 ]; do printf '─'; pad=$(( pad - 1 )); done
  printf '╮'; ui_reset

  top=$(( top + 1 ))
  printf '\033[%d;%dH' "$top" "$left"
  ui_sgr "$c"; printf '│'; ui_reset
  printf '%*s' $(( w - 2 )) ''
  ui_sgr "$c"; printf '│'; ui_reset

  for i in "${lines[@]}"; do
    top=$(( top + 1 ))
    printf '\033[%d;%dH' "$top" "$left"
    ui_sgr "$c"; printf '│'; ui_reset
    text="${i#\~}"
    printf '  '
    [ "$i" != "$text" ] && ui_sgr "$TMUX_UI_DIM"
    printf '%s' "$text"
    [ "$i" != "$text" ] && ui_reset
    printf '%*s' $(( w - 4 - ${#text} )) ''
    ui_sgr "$c"; printf '│'; ui_reset
  done

  top=$(( top + 1 ))
  printf '\033[%d;%dH' "$top" "$left"
  ui_sgr "$c"; printf '│'; ui_reset
  printf '%*s' $(( w - 2 )) ''
  ui_sgr "$c"; printf '│'; ui_reset

  top=$(( top + 1 ))
  printf '\033[%d;%dH' "$top" "$left"
  ui_sgr "$c"; printf '╰'
  pad=$(( w - 2 ))
  while [ "$pad" -gt 0 ]; do printf '─'; pad=$(( pad - 1 )); done
  printf '╯'; ui_reset
  printf '\033[%d;1H' "$(( top + 2 ))"
}

# ui_confirm_card INTENT TITLE QUESTION — draw the card, wait for one key.
# 0 = yes. Anything that isn't y is no, including a closed stdin.
#
# ⚠️  Defaults to NO. An agent mid-task is the thing this whole setup exists not
# to lose, so the dangerous answer is never the one you get by leaning on Enter.
ui_confirm_card() {
  local intent="$1" title="$2" q="$3" answer
  ui_card "$intent" "$title" "$q" "" "~y  yes        any other key  cancel"
  # One keypress, no Enter — it is a yes/no, not a form.
  if ! IFS= read -rsn1 answer; then answer=""; fi
  printf '\033[2J\033[H'
  case "$answer" in y|Y) return 0 ;; *) return 1 ;; esac
}
