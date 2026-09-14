#!/usr/bin/env bash
# tmux-agents installer.
#
#   ./install.sh                 install with sane defaults
#   ./install.sh --with-status   also put agent counts in your tmux status line
#   ./install.sh --with-extras   also install the optional tmux QoL settings
#   ./install.sh --with-launchd  also load the save/restore and battery jobs
#   ./install.sh --no-cli        skip the ~/.local/bin command symlinks
#   ./install.sh --login-shell   force tmux's default login shell in panes
#   ./install.sh --no-login-shell  force a non-login interactive shell instead
#   ./install.sh --no-shell      tmux keybindings only, no shell functions
#   ./install.sh --dry-run       print every change, make none
#   ./install.sh --uninstall     remove everything this added
#
#   --rc PATH          shell rc to edit        (default: auto-detected)
#   --tmux-conf PATH   tmux config to edit     (default: ~/.tmux.conf)
#   --no-reload        do not reload a running tmux server
#
# What it touches, and nothing else:
#
#   ~/.config/tmux-agents/           rendered tmux config (absolute paths baked in)
#   <your tmux.conf>                 one `source-file` line, inside markers
#   <your shell rc>                  one `source` line, inside markers
#
# Both edits are fenced in "# >>> tmux-agents >>>" markers, are replaced rather
# than appended on re-run, and are removed cleanly by --uninstall. Every file it
# edits is backed up first.
set -eu

HOME_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="tmux-agents"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$NAME"
BEGIN="# >>> $NAME >>>"
END="# <<< $NAME <<<"
STAMP=$(date +%Y%m%d%H%M%S)

WITH_STATUS=0
WITH_EXTRAS=0
WITH_LAUNCHD=0
WITH_CLI=1
LOGIN_SHELL=auto
WITH_SHELL=1
DRY_RUN=0
UNINSTALL=0
RC_FILE=""
TMUX_CONF="$HOME/.tmux.conf"
TMUX_CONF_EXPLICIT=0
NO_RELOAD=0

MIN_TMUX_MAJOR=3
MIN_TMUX_MINOR=3

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  B=$(printf '\033[1m'); DIM=$(printf '\033[2m'); G=$(printf '\033[32m')
  Y=$(printf '\033[33m'); R=$(printf '\033[31m'); Z=$(printf '\033[0m')
else
  B=""; DIM=""; G=""; Y=""; R=""; Z=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '  %s✗%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
act()  { if [ "$DRY_RUN" = 1 ]; then printf '  %swould%s %s\n' "$DIM" "$Z" "$*"; else printf '  %s\n' "$*"; fi; }

# link_cli DEST SRC — symlink, but never over a real file someone else owns.
# A stale symlink from an older clone is ours to repoint; a regular file at that
# name belongs to another tool and is left alone with a warning.
link_cli() {
  dest="$1"; src="$2"
  if [ -L "$dest" ] || [ ! -e "$dest" ]; then
    ln -sfn "$src" "$dest" && ok "$(basename "$dest")"
  else
    warn "$dest exists and is not a symlink — left alone"
  fi
}

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --with-status) WITH_STATUS=1 ;;
    --with-extras) WITH_EXTRAS=1 ;;
    --with-launchd) WITH_LAUNCHD=1 ;;
    --no-cli)      WITH_CLI=0 ;;
    --login-shell)    LOGIN_SHELL=1 ;;
    --no-login-shell) LOGIN_SHELL=0 ;;
    --no-shell)    WITH_SHELL=0 ;;
    --dry-run)     DRY_RUN=1 ;;
    --uninstall)   UNINSTALL=1 ;;
    --rc)          RC_FILE="${2:?--rc needs a path}"; shift ;;
    --tmux-conf)   TMUX_CONF="${2:?--tmux-conf needs a path}"; TMUX_CONF_EXPLICIT=1; shift ;;
    --no-reload)   NO_RELOAD=1 ;;
    -h|--help)     usage ;;
    *)             die "unknown option: $1  (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Which shell rc
# ---------------------------------------------------------------------------
# The helpers are bash. Under zsh they load and work, minus tab completion, so
# zsh users still get them — we just pick the right file to write to.
#
# bash reads ~/.bash_profile for LOGIN shells and ~/.bashrc for non-login ones,
# and terminals differ on which they start. Prefer whichever already exists so we
# land in the file you actually maintain.
detect_rc() {
  if [ -n "$RC_FILE" ]; then printf '%s\n' "$RC_FILE"; return; fi
  case "${SHELL##*/}" in
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ -f "$HOME/.bash_profile" ]; then printf '%s\n' "$HOME/.bash_profile"
          else printf '%s\n' "$HOME/.bashrc"; fi ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}
RC_FILE=$(detect_rc)

# ---------------------------------------------------------------------------
# Marker-block editing
# ---------------------------------------------------------------------------
# One block per file, replaced wholesale on re-run. awk rather than sed -i, which
# is not portable between GNU and BSD.
strip_block() {          # strip_block FILE -> prints file without our block
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 }
    !skip   { print }
    $0 == e { skip = 0 }
  ' "$1"
}

has_block() { [ -f "$1" ] && grep -qF "$BEGIN" "$1"; }

backup() {
  [ -f "$1" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then act "back up $1 -> $1.bak-$NAME-$STAMP"; return 0; fi
  cp "$1" "$1.bak-$NAME-$STAMP"
}

write_block() {          # write_block FILE BODY...
  file="$1"; shift
  if [ "$DRY_RUN" = 1 ]; then
    act "$( has_block "$file" && echo update || echo add ) the $NAME block in $file"
    printf '%s\n' "$@" | sed "s|^|      $DIM|;s|$|$Z|"
    return 0
  fi
  backup "$file"
  mkdir -p "$(dirname "$file")"
  tmp="$file.$NAME.tmp.$$"
  if [ -f "$file" ]; then strip_block "$file" > "$tmp"; else : > "$tmp"; fi
  # Exactly one trailing newline before the block, so re-running can't stack them.
  [ -s "$tmp" ] && printf '\n' >> "$tmp"
  { printf '%s\n' "$BEGIN"
    printf '%s\n' "$@"
    printf '%s\n' "$END"; } >> "$tmp"
  mv "$tmp" "$file"
}

remove_block() {
  file="$1"
  has_block "$file" || { warn "no $NAME block in $file"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then act "remove the $NAME block from $file"; return 0; fi
  backup "$file"
  tmp="$file.$NAME.tmp.$$"
  strip_block "$file" > "$tmp"
  mv "$tmp" "$file"
  ok "removed the $NAME block from $file"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  say ""
  say "${B}Uninstalling $NAME${Z}"
  remove_block "$TMUX_CONF"
  remove_block "$RC_FILE"
  if [ -d "$CONF_DIR" ]; then
    if [ "$DRY_RUN" = 1 ]; then act "remove $CONF_DIR"
    else rm -f "$CONF_DIR/agents.conf" "$CONF_DIR/extras.conf"
         rmdir "$CONF_DIR" 2>/dev/null || true
         ok "removed $CONF_DIR"
    fi
  fi
  if [ -d "$HOME/.cache/tmux-agent-status" ] && [ "$DRY_RUN" != 1 ]; then
    rm -rf "$HOME/.cache/tmux-agent-status"
    ok "removed the waiting-state cache"
  fi

  # Only our own symlinks, and only the ones pointing into THIS clone: a name
  # someone has since pointed at another checkout is not ours to remove.
  BIN_DIR="$HOME/.local/bin"
  for n in tsleep twake tsnaps tsave trestore tarchive tpower tdoctor tf tlifecycle; do
    tgt=$(readlink "$BIN_DIR/$n" 2>/dev/null) || continue
    case "$tgt" in
      "$HOME_DIR"/bin/*)
        if [ "$DRY_RUN" = 1 ]; then act "remove $BIN_DIR/$n"
        else rm -f "$BIN_DIR/$n"; ok "removed $BIN_DIR/$n"; fi ;;
    esac
  done

  # launchd jobs, if --with-launchd ever loaded them.
  if [ "$(uname -s)" = "Darwin" ]; then
    for job in persist power; do
      plist="$HOME/Library/LaunchAgents/com.tmux-agents.$job.plist"
      [ -e "$plist" ] || continue
      if [ "$DRY_RUN" = 1 ]; then act "unload and remove $plist"; continue; fi
      launchctl bootout "gui/$(id -u)/com.tmux-agents.$job" >/dev/null 2>&1 || true
      rm -f "$plist"
      ok "removed com.tmux-agents.$job"
    done
  fi
  say ""
  say "Done. The repo itself is untouched — delete it whenever you like."
  say "${DIM}Your tmux config and shell rc were backed up as *.bak-$NAME-$STAMP${Z}"
  say "${DIM}Reload tmux to drop the keybindings: tmux source-file $TMUX_CONF${Z}"
  say ""
  exit 0
fi

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
say ""
say "${B}Installing $NAME${Z} from $HOME_DIR"
say ""
say "${B}Checking what's here${Z}"

command -v tmux >/dev/null 2>&1 || die "tmux is not installed (brew install tmux / apt install tmux)"

TMUX_VER=$(tmux -V | sed 's/^tmux //')
# Strip any suffix letter ("3.7b") before comparing.
ver_major=$(printf '%s' "$TMUX_VER" | sed 's/[^0-9.].*//' | cut -d. -f1)
ver_minor=$(printf '%s' "$TMUX_VER" | sed 's/[^0-9.].*//' | cut -d. -f2)
[ -n "$ver_minor" ] || ver_minor=0
if [ "$ver_major" -lt "$MIN_TMUX_MAJOR" ] ||
   { [ "$ver_major" -eq "$MIN_TMUX_MAJOR" ] && [ "$ver_minor" -lt "$MIN_TMUX_MINOR" ]; }; then
  die "tmux $TMUX_VER is too old — need $MIN_TMUX_MAJOR.$MIN_TMUX_MINOR+ for 'display-popup -e'"
fi
ok "tmux $TMUX_VER"

if command -v fzf >/dev/null 2>&1; then
  ok "fzf $(fzf --version | cut -d' ' -f1)"
else
  warn "fzf missing — the agent picker falls back to a plain tmux menu,"
  warn "  and the file browser won't work at all. brew install fzf"
fi

if command -v rg >/dev/null 2>&1; then
  ok "ripgrep (file browser respects .gitignore)"
else
  warn "ripgrep missing — the file browser falls back to find. brew install ripgrep"
fi

# Short function names are the ergonomics, but they can collide.
if [ "$WITH_SHELL" = 1 ]; then
  clashes=""
  for fn in t tl ta ts tw tk td; do
    if command -v "$fn" >/dev/null 2>&1; then clashes="$clashes $fn"; fi
  done
  if [ -n "$clashes" ]; then
    warn "these names already exist and will be shadowed:$clashes"
    warn "  (moreutils provides 'ts'.) Use --no-shell for keybindings only."
  fi
fi

# ---------------------------------------------------------------------------
# Render the tmux config
# ---------------------------------------------------------------------------
say ""
say "${B}Writing config${Z}"

# ---------------------------------------------------------------------------
# Login shell, or not
# ---------------------------------------------------------------------------
# tmux starts a LOGIN shell. bash logins read ~/.bash_profile and never
# ~/.bashrc; zsh logins read ~/.zprofile and never ~/.zshrc. If the file holding
# your aliases is not reachable from there, `t` starts an agent whose `claude` is
# the bare binary rather than your alias — the same word, different behaviour,
# and nothing reports it. Rather than guess, look.
#
# Deliberately conservative: only when the interactive file exists AND the login
# file demonstrably does not pull it in. An unreadable or absent login file means
# we cannot tell, and we leave tmux's default alone.
detect_login_shell() {
  case "${SHELL##*/}" in
    bash) login_f="$HOME/.bash_profile"; inter_f="$HOME/.bashrc" ;;
    zsh)  login_f="${ZDOTDIR:-$HOME}/.zprofile"; inter_f="${ZDOTDIR:-$HOME}/.zshrc" ;;
    *)    return 1 ;;
  esac
  [ -r "$inter_f" ] || return 1
  [ -r "$login_f" ] || return 1
  # Does the login file source the interactive one? Comments are stripped first,
  # then a real sourcing line is matched in any of its usual shapes:
  #   . ~/.bashrc    source $HOME/.bashrc    [ -f ~/.bashrc ] && . ~/.bashrc
  #   if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
  # Requiring whitespace after the dot is what keeps a path like /opt/x.y/bin
  # from counting as a source command.
  base=$(basename "$inter_f")
  if sed 's/#.*//' "$login_f" 2>/dev/null \
     | grep -qE "(^|[[:space:]])(\.|source)[[:space:]]+[^[:space:];&|]*${base}"; then
    return 1
  fi
  return 0
}

if [ "$LOGIN_SHELL" = auto ]; then
  if detect_login_shell; then DEFAULT_COMMAND=""; else DEFAULT_COMMAND="# "; fi
elif [ "$LOGIN_SHELL" = 0 ]; then DEFAULT_COMMAND=""
else DEFAULT_COMMAND="# "
fi

render() {              # render IN OUT
  in="$1"; out="$2"
  if [ "$WITH_STATUS" = 1 ]; then status_comment=""; else status_comment="# "; fi
  if [ "$DRY_RUN" = 1 ]; then act "render $(basename "$in") -> $out"; return 0; fi
  mkdir -p "$(dirname "$out")"
  sed -e "s|@TMUX_AGENTS_HOME@|$HOME_DIR|g" \
      -e "s|@STATUS_COMMENT@|$status_comment|g" \
      -e "s|@HOME@|$HOME|g" \
      -e "s|@DEFAULT_COMMAND@|$DEFAULT_COMMAND|g" \
      "$in" > "$out"
}

render "$HOME_DIR/tmux/agents.conf.in" "$CONF_DIR/agents.conf"
[ "$DRY_RUN" = 1 ] || ok "$CONF_DIR/agents.conf"

SOURCE_LINES="source-file \"$CONF_DIR/agents.conf\""
if [ "$WITH_EXTRAS" = 1 ]; then
  render "$HOME_DIR/tmux/extras.conf.in" "$CONF_DIR/extras.conf"
  [ "$DRY_RUN" = 1 ] || ok "$CONF_DIR/extras.conf"
  SOURCE_LINES="$SOURCE_LINES
source-file \"$CONF_DIR/extras.conf\""
fi

# Executability survives git, but not every zip or rsync.
if [ "$DRY_RUN" != 1 ]; then
  chmod +x "$HOME_DIR"/bin/*.sh "$HOME_DIR"/hooks/*.sh 2>/dev/null || true
fi

write_block "$TMUX_CONF" \
  "# Managed by $HOME_DIR/install.sh — your edits inside this block will be lost." \
  "$SOURCE_LINES"
[ "$DRY_RUN" = 1 ] || ok "$TMUX_CONF sources it"

if [ "$WITH_SHELL" = 1 ]; then
  # Order matters: agents.sh defines the classifier and _TA_BIN that the other
  # three build on, so it is sourced first. The rest are independent of each
  # other. Each line is guarded, so removing a file just removes its commands.
  SHELL_LINES=""
  for sf in agents.sh quick-agents.sh tmux-persist.sh favorites.sh; do
    SHELL_LINES="${SHELL_LINES}[ -r \"$HOME_DIR/shell/$sf\" ] && . \"$HOME_DIR/shell/$sf\"
"
  done
  write_block "$RC_FILE" \
    "# Managed by $HOME_DIR/install.sh — your edits inside this block will be lost." \
    "${SHELL_LINES%
}"
  [ "$DRY_RUN" = 1 ] || ok "$RC_FILE sources the shell helpers"
else
  say "  ${DIM}skipping shell helpers (--no-shell)${Z}"
fi

# ---------------------------------------------------------------------------
# Commands that work outside an interactive shell
# ---------------------------------------------------------------------------
# tsave, tdoctor and the rest are shell functions, which means cron, launchd and
# `ssh host tsave` cannot see them. These symlinks give the same names a real
# executable: tmux-agent-cli.sh dispatches on its own basename, so one script
# backs all of them.
if [ "$WITH_CLI" = 1 ]; then
  say ""
  say "${B}Commands${Z}"
  BIN_DIR="$HOME/.local/bin"
  if [ "$DRY_RUN" = 1 ]; then
    act "symlink tsleep twake tsnaps tsave trestore tarchive tpower tdoctor tf tlifecycle -> $BIN_DIR"
  else
    mkdir -p "$BIN_DIR"
    for n in tsleep twake tsnaps tsave trestore tarchive tpower tdoctor tf; do
      link_cli "$BIN_DIR/$n" "$HOME_DIR/bin/tmux-agent-cli.sh"
    done
    link_cli "$BIN_DIR/tlifecycle" "$HOME_DIR/bin/tmux-agent-lifecycle.sh"
    case ":$PATH:" in
      *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
      *) warn "$BIN_DIR is not on your PATH — add it, or the names above won't resolve" ;;
    esac
  fi
else
  say "  ${DIM}skipping command symlinks (--no-cli)${Z}"
fi

# ---------------------------------------------------------------------------
# launchd: snapshot/restore, and the battery guard
# ---------------------------------------------------------------------------
# Opt-in. These are background jobs that outlive your terminal, so installing
# them silently would be rude — and everything in this repo works without them.
# What you lose without them: snapshots only happen on tmux's own hooks (not on
# a 5-minute clock), nothing restores your sessions at login, and nothing sleeps
# agents when the battery gets low. tsave/trestore still work by hand.
if [ "$WITH_LAUNCHD" = 1 ]; then
  say ""
  say "${B}launchd jobs${Z}"
  if [ "$(uname -s)" != "Darwin" ]; then
    say "  ${DIM}not macOS — skipping${Z}"
  else
    mkdir -p "$HOME/.local/state/tmux-agents" 2>/dev/null || true
    LA="$HOME/Library/LaunchAgents"
    for job in persist power; do
      plist="com.tmux-agents.$job.plist"
      src="$HOME_DIR/macos/$plist.in"
      [ -r "$src" ] || { warn "$plist.in missing — skipping"; continue; }
      if [ "$DRY_RUN" = 1 ]; then act "render $plist -> $LA/$plist, then bootstrap"; continue; fi
      mkdir -p "$LA"
      render "$src" "$LA/$plist"
      # bootout first: bootstrap on an already-loaded label is an error, and a
      # label left pointing at an old path is worse than one that is absent.
      launchctl bootout "gui/$(id -u)/com.tmux-agents.$job" >/dev/null 2>&1 || true
      if launchctl bootstrap "gui/$(id -u)" "$LA/$plist" 2>/dev/null; then
        ok "com.tmux-agents.$job loaded"
      else
        warn "could not bootstrap com.tmux-agents.$job — load it from $LA/$plist by hand"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Reload
# ---------------------------------------------------------------------------
# ⚠️  Only ever reload the config the running server actually uses. Reloading a
# config from a different --tmux-conf pushes THAT config into a live server, which
# during testing meant a throwaway install silently rebound a real session's keys
# and status line. Explicit --tmux-conf means "you drive".
if [ "$DRY_RUN" != 1 ] && [ "$NO_RELOAD" != 1 ] && [ "$TMUX_CONF_EXPLICIT" != 1 ] &&
   tmux info >/dev/null 2>&1; then
  if tmux source-file "$TMUX_CONF" 2>/dev/null; then
    ok "reloaded the running tmux server"
  else
    warn "couldn't reload tmux automatically — run: tmux source-file $TMUX_CONF"
  fi
elif [ "$DRY_RUN" != 1 ] && tmux info >/dev/null 2>&1; then
  warn "not reloading a server that may use a different config — when you're ready:"
  warn "  tmux source-file $TMUX_CONF"
fi

# ---------------------------------------------------------------------------
# What now
# ---------------------------------------------------------------------------
say ""
if [ "$DRY_RUN" = 1 ]; then
  say "${B}Dry run — nothing changed.${Z}"
  say ""
  exit 0
fi

say "${B}Done. Try this:${Z}"
say ""
say "  ${B}t my-agent${Z}          start an agent in its own session and folder"
say "  ${B}prefix + a${Z}          every agent, with live previews"
say "  ${B}prefix + f${Z}          browse that agent's files"
say "  ${B}$HOME_DIR/bin/tmux-agents-doctor.sh${Z}"
say "                        check the install"
say ""
if [ "$WITH_SHELL" = 1 ]; then
  say "${DIM}New shells pick up the helpers automatically. For this one:${Z}"
  say "  . $HOME_DIR/shell/agents.sh"
  say ""
fi
if [ "$WITH_STATUS" != 1 ]; then
  say "${DIM}Want ●2 ○1 ◆1 agent counts in your status line? Either re-run with${Z}"
  say "${DIM}--with-status, or add this to your own status-right:${Z}"
  say "  #($HOME_DIR/bin/tmux-agent-status.sh)"
  say ""
fi
say "${DIM}To tell 'finished' from 'waiting on you', wire up the Claude Code hook:${Z}"
say "${DIM}  see $HOME_DIR/hooks/README.md${Z}"
say ""
say "${DIM}Uninstall any time: ./install.sh --uninstall${Z}"
say ""
