#!/usr/bin/env bash
# tmux-file-picker — browse, preview and open the files an agent is working on.
#
# Runs inside `tmux display-popup -E`, launched by prefix + f via
# tmux-file-pick.sh. The agent picker's ctrl-f exec's it directly in the popup it
# is already holding, so you can go prefix + a -> find an agent -> ctrl-f and be
# looking at that agent's folder without ever nesting popups.
#
# ONE DIRECTORY AT A TIME, sorted, directories first. The first cut of this listed
# the whole tree recursively, which in a plugin repo meant 467 unsorted paths and
# no way to see what was actually in the folder. Fuzzy-finding a path you already
# know the name of is a different job from looking around, so it's a toggle
# (ctrl-a) rather than the default.
#
#   enter    directory: go into it.  file: open in the system viewer
#   ..       first row, or ctrl-h — go up a level
#   ctrl-a   toggle recursive: every file below here, for when you want to fuzzy-find
#   ctrl-l   Quick Look (stays open, so you can flip through images)
#   ctrl-f   reveal in Finder
#   ctrl-y   copy the absolute path to the clipboard (stays open)
#   ctrl-e   open in $EDITOR, in a new tmux window in the agent's session
#   ctrl-r   refresh
#   esc      cancel
#
# Environment, all set by the caller:
#   TMUX_FILE_ROOT     folder to start in (required)
#   TMUX_FILE_PANE     pane whose session gets the $EDITOR window (optional)
#   TMUX_AGENT_CLIENT  tty of the client that asked (optional; see pick.sh)
set -u

# Absolute, because fzf runs --preview and reload() as fresh child processes and a
# relative $0 would resolve against whatever directory they inherit.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------
# Sorted, and case-insensitively: rg and find both emit in traversal order, which
# looks like nothing at all to a reader. Directories first with a trailing slash,
# because they're how you move and you shouldn't have to hunt for them.
#
# Hidden entries are included on purpose — .claude/, .gitignore and .env are
# exactly the files you go looking for in an agent's folder.
_list_dir() {
  local d="$1"
  [ -d "$d" ] || return 0

  # `..` unless we're at /. It's a row rather than only a keybinding so that
  # going up is discoverable instead of something you have to be told.
  [ "$d" = "/" ] || printf '..\n'

  ( cd "$d" 2>/dev/null || exit 0
    for e in * .*; do
      case "$e" in .|..) continue ;; esac
      [ -e "$e" ] || continue          # unmatched glob
      [ -d "$e" ] && printf '%s/\n' "$e"
    done | sort -f
    for e in * .*; do
      case "$e" in .|..) continue ;; esac
      [ -e "$e" ] || continue
      [ -d "$e" ] || printf '%s\n' "$e"
    done | sort -f
  )
}

# Every file below here, for fuzzy-finding by name. rg respects .gitignore, so a
# Next.js checkout doesn't bury you in node_modules; depth-capped find otherwise.
#
# ⚠️  macOS: never descend into other apps' data. Walking ~/Library/Containers or
# Group Containers asks TCC for permission ONCE PER APP, so browsing from $HOME
# turns into a storm of "would like to access data from other apps" dialogs — and
# they're attributed to whichever terminal started your tmux server, which may not
# even be running. CloudStorage is worse than annoying: walking it can pull down
# every file in your iCloud/Dropbox.
#
# Nobody fuzzy-finds source in there, so the fix is free.
_list_recursive() {
  local d="$1"
  ( cd "$d" 2>/dev/null || exit 0
    if command -v rg >/dev/null 2>&1; then
      rg --files --hidden \
        --glob '!.git/*' \
        --glob '!Library/Containers/*' \
        --glob '!Library/Group Containers/*' \
        --glob '!Library/Application Support/*' \
        --glob '!Library/CloudStorage/*' \
        --glob '!Library/Caches/*' \
        --glob '!.Trash/*' \
        2>/dev/null | sed 's|^\./||'
    else
      find . -mindepth 1 -maxdepth 6 -type f \
        -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' \
        -not -path '*/Library/Containers/*' -not -path '*/Library/Group Containers/*' \
        -not -path '*/Library/Application Support/*' -not -path '*/Library/CloudStorage/*' \
        -not -path '*/Library/Caches/*' -not -path '*/.Trash/*' \
        2>/dev/null | sed 's|^\./||'
    fi | sort -f
  )
}

# ---------------------------------------------------------------------------
# Preview
# ---------------------------------------------------------------------------
# Its own mode rather than a shell one-liner inside --preview: this is the part
# with the most branching, and quoting it through fzf would make it unreadable
# and untestable. Run `tmux-file-picker.sh --preview FILE` (with TMUX_FILE_DIR
# set) to see exactly what the popup will show.
_preview() {
  local rel="$1" dir="${TMUX_FILE_DIR:-$PWD}" f mime

  case "$rel" in
    "..") f=$(dirname "$dir") ;;
    /*)   f="$rel" ;;
    *)    f="$dir/${rel%/}" ;;
  esac

  if [ -d "$f" ]; then
    printf '%s\n\n' "${f/#$HOME/~}"
    ls -lAh "$f" 2>/dev/null | sed -n '1,200p'
    return 0
  fi

  [ -e "$f" ] || { printf '%s\n\n(gone)\n' "$rel"; return 0; }

  printf '%s  —  %s\n\n' "$rel" "$(ls -lh "$f" 2>/dev/null | awk '{print $5}')"

  if [ ! -s "$f" ]; then
    printf '(empty file)\n'
    return 0
  fi

  mime=$(file --mime-type -b "$f" 2>/dev/null)
  case "$mime" in
    text/*|*/json|*/javascript|*/xml|*/x-sh|*/x-shellscript|*/toml|*/yaml|*/x-yaml)
      # Line numbers via awk so this needs no bat/highlight. 400 lines is more
      # than the popup can show but leaves room to scroll the preview.
      awk 'NR <= 400 { printf "%5d  %s\n", NR, $0 } END { if (NR > 400) printf "\n… %d more lines\n", NR - 400 }' "$f" 2>/dev/null
      ;;
    image/*)
      printf '%s\n' "$mime"
      # Dimensions when something can tell us: sips ships with macOS, identify
      # comes with ImageMagick. Neither is required.
      if command -v sips >/dev/null 2>&1; then
        sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | sed -n '2,3p'
      elif command -v identify >/dev/null 2>&1; then
        identify -format '  %wx%h\n' "$f" 2>/dev/null
      fi
      printf '\nctrl-l for Quick Look\n'
      ;;
    *)
      printf '%s\n' "${mime:-unknown type}"
      file -b "$f" 2>/dev/null
      printf '\nctrl-l for Quick Look, enter to open it\n'
      ;;
  esac
}

# _shq STRING — single-quote for a shell command string. Needed because a couple
# of these actions go through `tmux run-shell`, which hands the string to sh, and
# paths from a real folder contain spaces.
_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------
# macOS has the verbs this thing is built around — Quick Look, reveal-in-Finder.
# Elsewhere we do the honest thing: fall back to xdg-open where the concept
# exists, and say so plainly where it doesn't.
#
# Gated on `uname`, NOT on `command -v open`: on Linux `open` is often util-linux's
# openvt, which would happily do something unrelated to what you asked for.
case "$(uname -s 2>/dev/null)" in
  Darwin) MACOS=1 ;;
  *)      MACOS=0 ;;
esac

_sys_open() {
  if [ "$MACOS" = 1 ]; then open "$1" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
  else return 127
  fi
}

_sys_reveal() {
  if [ "$MACOS" = 1 ]; then open -R "$1" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1; then
    # No "reveal and select" outside Finder, so open the containing folder.
    xdg-open "$(dirname "$1")" >/dev/null 2>&1
  else return 127
  fi
}

_sys_quicklook() {
  command -v qlmanage >/dev/null 2>&1 || return 127
  # See the ctrl-l branch for why this goes through the tmux server.
  tmux run-shell -b "qlmanage -p $(_shq "$1") >/dev/null 2>&1"
}

# tmux's own buffer is the portable clipboard: with `set-clipboard on` it reaches
# the system clipboard over OSC 52, which also works through SSH. pbcopy first on
# macOS because it needs no terminal cooperation at all.
_sys_copy() {
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$1" | pbcopy
  else
    tmux set-buffer -w -- "$1" 2>/dev/null || tmux set-buffer -- "$1"
  fi
}

# Sub-modes, used by fzf's --preview and reload().
case "${1:-}" in
  --preview) shift; _preview "${1:-}"; exit 0 ;;
  --list)
    if [ "${TMUX_FILE_MODE:-dir}" = "recursive" ]; then
      _list_recursive "${TMUX_FILE_DIR:-$PWD}"
    else
      _list_dir "${TMUX_FILE_DIR:-$PWD}"
    fi
    exit 0
    ;;
esac

CUR="${TMUX_FILE_ROOT:-$PWD}"
MODE=dir
QUERY=""

if [ ! -d "$CUR" ]; then
  tmux display-message "file browser: $CUR is not a directory"
  exit 0
fi

# ---------------------------------------------------------------------------
# The browse loop
# ---------------------------------------------------------------------------
# Descending into a directory re-runs fzf rather than reload()-ing it in place.
# Both work; a loop keeps the current directory in one obvious variable instead of
# smuggling it through fzf's reload state, and re-running fzf on a single
# directory listing is instant.
while :; do
  export TMUX_FILE_DIR="$CUR"
  export TMUX_FILE_MODE="$MODE"

  rows=$("$SELF" --list)
  if [ -z "$rows" ]; then
    rows=".."
  fi

  if [ "$MODE" = recursive ]; then
    title="${CUR/#$HOME/~}   — all files below here"
    hint='enter open   ctrl-a back to browsing   ctrl-l look   ctrl-f finder   ctrl-y copy   ctrl-e edit'
  else
    title="${CUR/#$HOME/~}"
    hint='enter open/enter dir   ctrl-h up   ctrl-a all files   ctrl-l look   ctrl-f finder   ctrl-y copy   ctrl-e edit'
  fi

  out=$(
    printf '%s\n' "$rows" | fzf \
      --print-query \
      --expect=ctrl-l,ctrl-f,ctrl-y,ctrl-e,ctrl-a,ctrl-h \
      --preview "$SELF --preview {}" \
      --preview-window='right,60%,border-left' \
      --header "$title
$hint" \
      --prompt='file> ' \
      --query "$QUERY" \
      --reverse --cycle --height=100% \
      --bind "ctrl-r:reload($SELF --list)"
  )

  query=$(printf '%s\n' "$out" | sed -n 1p)
  key=$(printf '%s\n' "$out" | sed -n 2p)
  sel=$(printf '%s\n' "$out" | sed -n 3p)

  # Actions that keep the browser up have to put you back where you were, or
  # they're not usable more than once: every iteration is a fresh fzf, which
  # starts with an empty query and the cursor on row 1. Restoring the query gets
  # the cursor back onto the same row too, since it matches the same thing.
  #
  # Changing directory clears it — the old filter means nothing in a new folder.
  # Toggling recursive keeps it, which is the good flow: type "serena", ctrl-a,
  # and you've found it anywhere below here.
  QUERY="$query"

  # Mode and navigation keys go FIRST, because they don't depend on what's
  # highlighted — and because folding ctrl-a into the ".." handling below made it
  # walk up a directory instead of toggling, whenever ".." happened to be the row
  # under the cursor (which it always is, right after you enter a directory).
  case "$key" in
    ctrl-a)
      if [ "$MODE" = recursive ]; then MODE=dir; else MODE=recursive; fi
      continue
      ;;
    ctrl-h)
      CUR=$(dirname "$CUR")
      MODE=dir
      QUERY=""
      continue
      ;;
  esac

  # Esc, or a query that matched nothing.
  [ -n "$sel" ] || exit 0

  # Plain enter on ".." is the discoverable way up.
  if [ "$sel" = ".." ]; then
    if [ -z "$key" ]; then
      CUR=$(dirname "$CUR")
      MODE=dir
      QUERY=""
      continue
    fi
    # Any other action on ".." means the parent directory itself — reveal it in
    # Finder, copy its path, and so on.
    target=$(dirname "$CUR")
  else
    # Trailing slash is display sugar on directories; strip it before touching disk.
    target="$CUR/${sel%/}"
  fi

  case "$key" in

    ctrl-l)
      # ⚠️  NOT `qlmanage -p … &`. qlmanage holds its terminal for as long as the
      # Quick Look window is up, so it has to outlive this script — but tmux tears
      # down a popup's whole process group the moment its command exits, which
      # kills a plain background child before it can draw anything. Verified: with
      # `&`, qlmanage never ran at all.
      #
      # `run-shell -b` hands it to the tmux server instead, which outlives popups.
      # The browser stays up so you can flip through a folder of images.
      _sys_quicklook "$target" ||
        tmux display-message "Quick Look needs macOS (qlmanage) — enter opens it instead"
      continue
      ;;

    ctrl-y)
      _sys_copy "$target"
      tmux display-message "copied: $target"
      continue
      ;;

    ctrl-f)
      _sys_reveal "$target" ||
        tmux display-message "no file manager to reveal $sel in"
      exit 0
      ;;

    ctrl-e)
      # A new window rather than this pane: the pane you pressed the key in is
      # usually an agent mid-task, and dropping an editor on top of it is not what
      # anyone wants. Needs an explicit -t, because inside a popup tmux has no
      # current session to guess from.
      editor="${VISUAL:-${EDITOR:-vi}}"
      session=""
      [ -n "${TMUX_FILE_PANE:-}" ] &&
        session=$(tmux display-message -p -t "$TMUX_FILE_PANE" '#{session_name}' 2>/dev/null)
      if [ -n "$session" ]; then
        tmux new-window -t "=$session" -n "${editor##*/}" -c "$CUR" "$editor \"$target\""
      else
        tmux display-message "edit: don't know which session to open a window in"
      fi
      exit 0
      ;;

    *)
      # Plain enter. A directory is navigation, not something to hand to Finder —
      # that's what ctrl-f is for.
      if [ -d "$target" ]; then
        CUR="$target"
        MODE=dir
        QUERY=""
        continue
      fi
      # Otherwise hand it to the system and let Launch Services decide.
      _sys_open "$target" ||
        tmux display-message "nothing is registered to open $sel"
      exit 0
      ;;

  esac
done
