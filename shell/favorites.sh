#!/usr/bin/env bash
# favorites.sh — a short list of agents you start often, one keystroke away.
#
#   tf                 pick one (fzf) and start it — or switch to it if running
#   tf NAME            start that one
#   tf add [NAME]      add — inside tmux with no NAME, the agent in this session
#                      --target T   folder, owner/repo or git URL  (default: a folder called NAME)
#                      --cmd C      what window 1 runs  (default: $T_AUTOSTART, i.e. claude)
#                      --note N     what it is for
#   tf rm NAME         remove
#   tf ls              the list, with ● for the ones running now
#   tf edit            open the file in $EDITOR
#
# The list is ~/.config/tmux-agents/favorites.tsv: NAME, TARGET, COMMAND, NOTE,
# tab-separated, "-" for "the default". It is meant to be hand-edited.
#
# A favorite is not a separate kind of thing. It is defaults for a NAME: `t NAME`,
# the picker's ctrl-n, and `Ctrl+b F` all consult the list, so a favorite that
# says "start in ~/Projects/monorepo with claude '/product-manager:activate'"
# does exactly that however you start it. There is nothing to migrate: a favorite
# whose target and command are both "-" is just `t NAME` with a note.
#
# Sourced after tmux-aliases.sh, which owns `t`; the lookup hooks in there are
# guarded by `declare -F _tf_resolve`, so this file is optional.

: "${TMUX_AGENTS_FAVORITES:=${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agents/favorites.tsv}"

_tf_header() {
  cat <<'TXT'
# tmux agents — favorites. One per line, TAB-separated:  NAME  TARGET  COMMAND  NOTE
#
#   NAME     the session name: `t NAME`, `tf NAME`, or Ctrl+b F
#   TARGET   -                      a folder called NAME on $TMUX_SESSION_PATH (made if missing)
#            ~/Projects/foo         start in that folder
#            owner/repo or git URL  check it out (a worktree if a clone is already local)
#   COMMAND  -                      the default: $T_AUTOSTART, which is claude
#            claude "/sales-operator:activate"   any command; runs in window 1
#   NOTE     what it is for — shown in the list
#
# Edit by hand (tf edit) or with tf add / tf rm. Blank lines and # lines are ignored.
TXT
}

# _tf_rows — the data lines, every field present ("-" when blank).
_tf_rows() {
  [ -r "$TMUX_AGENTS_FAVORITES" ] || return 0
  awk -F'\t' -v OFS='\t' '
    /^[[:space:]]*(#|$)/ { next }
    { for (i = 1; i <= 4; i++) if ($i == "") $i = "-"; NF = 4; print }
  ' "$TMUX_AGENTS_FAVORITES"
}

# _tf_resolve NAME — "TARGET<TAB>COMMAND<TAB>NOTE" for a favorite, else status 1.
_tf_resolve() {
  local row
  row=$(_tf_rows | awk -F'\t' -v OFS='\t' -v n="$1" '$1 == n { print $2, $3, $4; exit }')
  [ -n "$row" ] || return 1
  printf '%s\n' "$row"
}

# _tf_candidates — "NAME<TAB>NOTE" per favorite, for the picker's ctrl-n list.
_tf_candidates() { _tf_rows | awk -F'\t' -v OFS='\t' '{ print $1, ($4 == "-" ? "" : $4) }'; }

_tf_running() {
  local n="$1"
  tmux has-session -t "=$n" 2>/dev/null
}

_tf_ls() {
  local name target cmd note mark n=0 tilde='~'
  while IFS=$'\t' read -r name target cmd note; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if _tf_running "$name"; then mark="●"; else mark=" "; fi
    printf '%s %-28s %-34s %s\n' "$mark" "$name" \
      "$( [ "$target" = - ] && printf '' || printf '%s' "${target/#$HOME/$tilde}" )$( [ "$cmd" = - ] && printf '' || printf '  [%s]' "$cmd" )" \
      "$( [ "$note" = - ] || printf '%s' "$note" )"
  done < <(_tf_rows)
  if [ "$n" = 0 ]; then
    echo "no favorites yet — tf add NAME, or from inside an agent's session just: tf add"
    return 0
  fi
  echo "● running   tf NAME starts one   tf edit changes the list ($TMUX_AGENTS_FAVORITES)"
}

_tf_add() {
  local name="" target="-" cmd="-" note="-" cur title
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) target="${2:?--target needs a value}"; shift 2 ;;
      --cmd)    cmd="${2:?--cmd needs a value}"; shift 2 ;;
      --note)   note="${2:?--note needs a value}"; shift 2 ;;
      -*) echo "tf add: unknown option $1" >&2; return 2 ;;
      *) name="$1"; shift ;;
    esac
  done

  # No name, inside tmux: the session we are in, as it is set up right now.
  if [ -z "$name" ] && [ -n "${TMUX:-}" ]; then
    name=$(tmux display-message -p '#{session_name}' 2>/dev/null)
    cur=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
    # Only record a target when the folder is NOT where `t NAME` would land anyway.
    if [ "$target" = - ] && [ -n "$cur" ] && [ "$cur" != "$(_t_workdir "$name" 2>/dev/null)" ]; then
      target="$cur"
    fi
    if [ "$cmd" = - ]; then
      cur=$(tmux list-windows -F '#{window_name}' 2>/dev/null | head -1)
      # The window is named after the command's FIRST word only, so this is a
      # guess at the command, not the command — say so.
      case "$cur" in ''|claude|shell) ;; *) cmd="$cur"; echo "tf: window 1 runs '$cur' — recorded that; if it takes arguments, tf edit and add them" >&2 ;; esac
    fi
    if [ "$note" = - ] && declare -F _t_agent_rows >/dev/null 2>&1; then
      # What the agent is working on, as its title says — a fair first note.
      title=$(tmux list-panes -s -F '#{pane_title}' 2>/dev/null | awk 'NF > 1 && $1 !~ /[[:alnum:]]/ { sub(/^[^ ]+ /, ""); print; exit }')
      [ -n "$title" ] && note="$title"
    fi
  fi
  [ -n "$name" ] || { echo "tf add NAME [--target T] [--cmd C] [--note N]   (no NAME: this session, inside tmux)" >&2; return 2; }
  case "$name" in *[$'\t']*|*/*|*.*) echo "tf add: '$name' is not a usable session name" >&2; return 2 ;; esac
  case "$target$cmd$note" in *[$'\t']*) echo "tf add: fields cannot contain tabs" >&2; return 2 ;; esac

  mkdir -p "$(dirname "$TMUX_AGENTS_FAVORITES")" || return 1
  [ -s "$TMUX_AGENTS_FAVORITES" ] || _tf_header > "$TMUX_AGENTS_FAVORITES"
  if _tf_resolve "$name" >/dev/null; then
    _tf_rm "$name" quiet
    echo "tf: replaced '$name'"
  fi
  printf '%s\t%s\t%s\t%s\n' "$name" "$target" "$cmd" "$note" >> "$TMUX_AGENTS_FAVORITES"
  echo "tf: added '$name'  →  tf $name   (or Ctrl+b F)"
}

_tf_rm() {
  local name="${1:-}" tmp
  [ -n "$name" ] || { echo "tf rm NAME" >&2; return 2; }
  _tf_resolve "$name" >/dev/null || { echo "tf: no favorite called '$name'" >&2; return 1; }
  tmp=$(mktemp) || return 1
  awk -F'\t' -v n="$name" '!(/^[^#]/ && $1 == n)' "$TMUX_AGENTS_FAVORITES" > "$tmp" && mv -f "$tmp" "$TMUX_AGENTS_FAVORITES"
  [ "${2:-}" = quiet ] || echo "tf: removed '$name' (the folder and conversation are untouched)"
}

_tf_pick() {
  local rows name
  rows=$(_tf_rows)
  [ -n "$rows" ] || { _tf_ls; return 0; }
  if command -v fzf >/dev/null 2>&1; then
    name=$(printf '%s\n' "$rows" | awk -F'\t' '{ printf "%s\t%-28s %s\n", $1, $1, ($4 == "-" ? "" : $4) }' \
      | fzf --delimiter=$'\t' --with-nth=2.. --prompt='favorite> ' --reverse --height=40% \
            --header='enter start (or switch to it)   esc cancel' | cut -f1)
  else
    _tf_ls
    printf 'name> '; read -r name
  fi
  [ -n "$name" ] && _tf_start "$name"
}

# _tf_start NAME — `t NAME`, which consults the list itself. If NAME is not on
# the list it still starts; a favorite is only a set of defaults.
_tf_start() {
  local name="$1"
  _tf_resolve "$name" >/dev/null || echo "tf: '$name' is not a favorite — starting it anyway; tf add $name to keep it" >&2
  t "$name"
}

tf() {
  case "${1:-}" in
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    '')        _tf_pick ;;
    add)       shift; _tf_add "$@" ;;
    rm|remove) shift; _tf_rm "$@" ;;
    ls|list)   _tf_ls ;;
    edit)      mkdir -p "$(dirname "$TMUX_AGENTS_FAVORITES")"
               [ -s "$TMUX_AGENTS_FAVORITES" ] || _tf_header > "$TMUX_AGENTS_FAVORITES"
               "${EDITOR:-vi}" "$TMUX_AGENTS_FAVORITES" ;;
    *)         _tf_start "$1" ;;
  esac
}

if [ -n "${BASH_VERSION:-}" ]; then
  _tf_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if [ "$COMP_CWORD" -eq 1 ]; then
      COMPREPLY=( $(compgen -W "add rm ls edit $(_tf_rows | cut -f1 | tr '\n' ' ')" -- "$cur") )
    elif [ "${COMP_WORDS[1]}" = rm ]; then
      COMPREPLY=( $(compgen -W "$(_tf_rows | cut -f1 | tr '\n' ' ')" -- "$cur") )
    fi
  }
  complete -F _tf_complete tf
fi
