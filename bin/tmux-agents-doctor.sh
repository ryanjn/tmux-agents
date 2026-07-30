#!/usr/bin/env bash
# tmux-agents doctor — is this thing actually wired up?
#
# Checks dependencies, the config wiring, the running server's keybindings, and
# the two things people most often miss (the Claude Code hook, and shadowed
# function names). Exits non-zero if something is broken, so CI can run it too.
set -u

HOME_DIR="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agents"
FAILED=0

if [ -t 1 ]; then
  B=$(printf '\033[1m'); DIM=$(printf '\033[2m'); G=$(printf '\033[32m')
  Y=$(printf '\033[33m'); R=$(printf '\033[31m'); Z=$(printf '\033[0m')
else
  B=""; DIM=""; G=""; Y=""; R=""; Z=""
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$Z" "$*"; FAILED=1; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$Z"; }

VERSION=$(sed -n 's/^TMUX_AGENTS_VERSION="\(.*\)"$/\1/p' "$HOME_DIR/shell/agents.sh" 2>/dev/null)
printf '\n%stmux-agents %s%s  %s%s%s\n' "$B" "${VERSION:-?}" "$Z" "$DIM" "$HOME_DIR" "$Z"

# ---------------------------------------------------------------------------
head_ "Dependencies"
if command -v tmux >/dev/null 2>&1; then
  v=$(tmux -V | sed 's/^tmux //')
  maj=$(printf '%s' "$v" | sed 's/[^0-9.].*//' | cut -d. -f1)
  min=$(printf '%s' "$v" | sed 's/[^0-9.].*//' | cut -d. -f2); [ -n "$min" ] || min=0
  if [ "$maj" -gt 3 ] || { [ "$maj" -eq 3 ] && [ "$min" -ge 3 ]; }; then
    ok "tmux $v"
  else
    bad "tmux $v is too old — need 3.3+ for 'display-popup -e'"
  fi
else
  bad "tmux not found"
fi

if command -v fzf >/dev/null 2>&1; then
  ok "fzf $(fzf --version | cut -d' ' -f1)"
else
  warn "fzf missing — picker degrades to a tmux menu, file browser unavailable"
fi
command -v rg >/dev/null 2>&1 && ok "ripgrep" || warn "ripgrep missing — file browser uses find"

case "$(uname -s 2>/dev/null)" in
  Darwin) ok "macOS — Quick Look and reveal-in-Finder available" ;;
  *)      warn "$(uname -s): open/Quick Look fall back to xdg-open where possible" ;;
esac

# ---------------------------------------------------------------------------
head_ "Files"
for f in bin/tmux-agent-pick.sh bin/tmux-agent-picker.sh bin/tmux-agent-menu.sh \
         bin/tmux-agent-do.sh bin/tmux-agent-status.sh bin/tmux-file-pick.sh \
         bin/tmux-file-picker.sh bin/tmux-agent-next.sh bin/tmux-agent-notify.sh \
         bin/tmux-dialog.sh shell/agents.sh; do
  if [ ! -f "$HOME_DIR/$f" ]; then bad "missing $f"
  elif [ ! -x "$HOME_DIR/$f" ] && [ "${f#bin/}" != "$f" ]; then bad "$f is not executable (run ./install.sh)"
  else ok "$f"
  fi
done

# ---------------------------------------------------------------------------
head_ "Wiring"
if [ -f "$CONF_DIR/agents.conf" ]; then
  ok "rendered config at $CONF_DIR/agents.conf"
  if grep -q "$HOME_DIR/bin" "$CONF_DIR/agents.conf"; then
    ok "  and it points at this checkout"
  else
    bad "  but it points somewhere else — re-run ./install.sh from here"
  fi
else
  bad "no rendered config — run ./install.sh"
fi

if grep -rqF "tmux-agents" "$HOME/.tmux.conf" 2>/dev/null; then
  ok "~/.tmux.conf sources it"
else
  bad "~/.tmux.conf has no tmux-agents block — run ./install.sh"
fi

if tmux info >/dev/null 2>&1; then
  if tmux list-keys 2>/dev/null | grep -q 'tmux-agent-pick'; then
    ok "prefix + a is bound in the running server"
  else
    bad "prefix + a is NOT bound — run: tmux source-file ~/.tmux.conf"
  fi
  if tmux list-keys 2>/dev/null | grep -q 'tmux-agent-next'; then
    ok "prefix + j jumps to the waiting agent"
  else
    warn "prefix + j is not bound — re-run ./install.sh, then reload tmux"
  fi
  if tmux list-keys 2>/dev/null | grep -q 'tmux-file-pick'; then
    ok "prefix + f is bound in the running server"
  else
    warn "prefix + f is not bound (fine if you commented it out to keep find-window)"
  fi
  if tmux show -gv status-right 2>/dev/null | grep -q 'tmux-agent-status'; then
    ok "agent counts are in your status line"
  else
    warn "no agent counts in status-right — ./install.sh --with-status, or add:"
    printf '      %s#(%s/bin/tmux-agent-status.sh)%s\n' "$DIM" "$HOME_DIR" "$Z"
  fi
  if tmux show -gv allow-rename 2>/dev/null | grep -q 'off'; then
    ok "allow-rename is off, so window names stay meaningful"
  else
    warn "allow-rename is on — Claude Code will rename windows to its version string"
  fi
else
  warn "no tmux server running — start one and re-run to check the bindings"
fi

# ---------------------------------------------------------------------------
head_ "tmux server"
# A tmux server outlives the terminal that started it, and macOS keeps attributing
# every process under it to that original app — so permission prompts name an app
# that may have quit hours ago, and clicking Allow can't record a durable grant
# against it. Nothing surfaces that on its own; this does.
if tmux info >/dev/null 2>&1; then
  spid=$(tmux display-message -p '#{pid}' 2>/dev/null)
  sage=$(ps -o etime= -p "$spid" 2>/dev/null | tr -d ' ')
  ok "server pid $spid, up ${sage:-?}"

  launcher=$(tmux show-environment -g __CFBundleIdentifier 2>/dev/null | sed -n 's/^__CFBundleIdentifier=//p')
  lname=$(tmux show-environment -g TERM_PROGRAM 2>/dev/null | sed -n 's/^TERM_PROGRAM=//p')
  if [ -n "$launcher" ] && command -v lsappinfo >/dev/null 2>&1; then
    if [ -z "$(lsappinfo find "bundleid=$launcher" 2>/dev/null)" ]; then
      warn "started from ${lname:-$launcher}, which is NOT running any more"
      printf '      %smacOS attributes every process in every pane to that app. Permission%s\n' "$DIM" "$Z"
      printf '      %sprompts will name it, and Allow will not stick because the app is gone.%s\n' "$DIM" "$Z"
      printf '      %sFix: restart the server from your current terminal when convenient —%s\n' "$DIM" "$Z"
      printf '      %sit kills running agents, so pick your moment.%s\n' "$DIM" "$Z"
    else
      ok "started from ${lname:-$launcher}, still running"
    fi
  elif [ -n "$lname" ]; then
    warn "started from $lname (can't tell whether it's still running)"
  fi
else
  warn "no tmux server running"
fi

# ---------------------------------------------------------------------------
head_ "Shell helpers"
# shellcheck disable=SC1090
if [ -r "$HOME_DIR/shell/agents.sh" ] && . "$HOME_DIR/shell/agents.sh" 2>/dev/null; then
  missing=""
  for fn in t tl ta ts tw tk _t_agent_rows _t_new_session _t_kill_agent; do
    declare -F "$fn" >/dev/null 2>&1 || missing="$missing $fn"
  done
  if [ -n "$missing" ]; then bad "helpers loaded but these are missing:$missing"
  else ok "all helpers load (t, tl, ta, ts, tw, tk)"
  fi
  n=$(_t_agent_rows 2>/dev/null | wc -l | tr -d ' ')
  ok "agent detection runs — sees $n right now"
else
  bad "shell/agents.sh does not load"
fi

# ---------------------------------------------------------------------------
head_ "Waiting-state hook (optional)"
# Without this, Claude Code's ✳ means both "finished" and "waiting on you".
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q 'claude-status-hook' "$SETTINGS" 2>/dev/null; then
  ok "claude-status-hook is wired into ~/.claude/settings.json"
  if [ -d "$HOME/.cache/tmux-agent-status" ]; then
    ok "  and it has written state (◆ waiting works)"
  else
    warn "  but it hasn't fired yet — restart your agents to pick it up"
  fi
else
  warn "not wired up: ✳ will mean both 'finished' and 'waiting on you'"
  printf '      %ssee %s/hooks/README.md%s\n' "$DIM" "$HOME_DIR" "$Z"
fi

if [ "${TMUX_AGENT_NOTIFY:-}" = 1 ]; then
  if [ -n "${TMUX_AGENT_NOTIFY_CMD:-}" ]; then
    ok "desktop notifications on, via \$TMUX_AGENT_NOTIFY_CMD"
  elif command -v terminal-notifier >/dev/null 2>&1; then
    ok "desktop notifications on (terminal-notifier)"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    ok "desktop notifications on (osascript)"
  elif command -v notify-send >/dev/null 2>&1; then
    ok "desktop notifications on (notify-send)"
  else
    warn "TMUX_AGENT_NOTIFY=1 but no notifier found — nothing will be sent"
  fi
else
  warn "desktop notifications off (export TMUX_AGENT_NOTIFY=1 to enable)"
fi

# ---------------------------------------------------------------------------
head_ "Name collisions"
clash=0
for fn in t tl ta ts tw tk td; do
  # type -aP lists only real files on $PATH, which is the whole question here.
  # Plain `type -a` would report the functions this script just sourced itself,
  # and its multi-line function bodies, as if they were collisions.
  paths=$(type -aP "$fn" 2>/dev/null | tr '\n' ' ')
  if [ -n "$paths" ]; then
    warn "$fn shadows a real command: $paths"
    clash=1
  fi
done
if [ "$clash" = 0 ]; then
  ok "no shadowed commands"
else
  printf '      %sthe function wins in an interactive shell; use install.sh --no-shell%s\n' "$DIM" "$Z"
  printf '      %sif you would rather keep the command.%s\n' "$DIM" "$Z"
fi

# ---------------------------------------------------------------------------
if [ "$FAILED" = 0 ]; then
  printf '\n%s✓ tmux-agents looks healthy.%s\n\n' "$G" "$Z"
else
  printf '\n%s✗ something above needs fixing.%s\n\n' "$R" "$Z"
fi
exit "$FAILED"
