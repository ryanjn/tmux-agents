#!/usr/bin/env bash
# tmux-agents doctor — is this thing actually wired up?
#
# Checks dependencies, the config wiring, the running server's keybindings, and
# the two things people most often miss (the Claude Code hook, and shadowed
# function names). Exits non-zero if something is broken, so CI can run it too.
set -u

HOME_DIR="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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
# ⚠️  This list once named a bin/ directory, shell/agents.sh and an install.sh
# that this repo never had — it was written for a packaged layout and never
# updated, so the doctor reported 13 missing files from its first commit until
# 2026-09-08. Keep it in step with bin/ and shell/ as they actually are.
for f in bin/tmux-agent-pick.sh bin/tmux-agent-picker.sh bin/tmux-agent-menu.sh \
         bin/tmux-agent-do.sh bin/tmux-agent-status.sh bin/tmux-file-pick.sh \
         bin/tmux-file-picker.sh bin/tmux-agent-next.sh bin/tmux-agent-notify.sh \
         bin/tmux-dialog.sh bin/tmux-agent-cli.sh \
         bin/tmux-agent-save.sh bin/tmux-agent-restore.sh bin/tmux-agent-persist.sh \
         bin/tmux-agent-lifecycle.sh bin/tmux-agent-autosave.sh bin/tmux-agent-power.sh \
         hooks/claude-status-hook.sh bin/quick-agent-reap.sh \
         bin/tmux-favorites-pick.sh \
         shell/agents.sh shell/tmux-persist.sh shell/quick-agents.sh shell/favorites.sh; do
  if [ ! -f "$HOME_DIR/$f" ]; then bad "missing $f"
  elif [ ! -x "$HOME_DIR/$f" ] && [ "${f#bin/}" != "$f" ]; then bad "$f is not executable (chmod +x)"
  else ok "$f"
  fi
done

# The standalone names: symlinks into tmux-agent-cli.sh, for shells that never
# sourced the helpers (hooks, cron, Claude Code's own `!` prefix).
for n in tsleep twake tsnaps tsave trestore tarchive tpower tdoctor tf; do
  if [ "$(readlink "$HOME/.local/bin/$n" 2>/dev/null)" = "$HOME_DIR/bin/tmux-agent-cli.sh" ]; then ok "~/.local/bin/$n"
  else warn "~/.local/bin/$n is not a symlink to bin/tmux-agent-cli.sh — fix: ln -sfn $HOME_DIR/bin/tmux-agent-cli.sh ~/.local/bin/$n"
  fi
done
if [ "$(readlink "$HOME/.local/bin/tlifecycle" 2>/dev/null)" = "$HOME_DIR/bin/tmux-agent-lifecycle.sh" ]; then ok "~/.local/bin/tlifecycle"
else warn "~/.local/bin/tlifecycle is not a symlink to bin/tmux-agent-lifecycle.sh"
fi
if [ "$(readlink "$HOME/.local/bin/tj" 2>/dev/null)" = "$HOME_DIR/bin/tmux-quick-job.sh" ]; then ok "~/.local/bin/tj"
else warn "~/.local/bin/tj is not a symlink to bin/tmux-quick-job.sh — fix: ./install.sh"
fi

# ---------------------------------------------------------------------------
head_ "Wiring"
# install.sh renders tmux/agents.conf.in into ~/.config/tmux-agents/agents.conf
# and adds one source-file line to ~/.tmux.conf. Check both halves: a rendered
# conf that nothing sources is the failure that looks fine from the outside.
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-agents/agents.conf"
if [ ! -r "$CONF" ]; then
  bad "$CONF is missing — fix: $HOME_DIR/install.sh"
elif ! grep -qF "$HOME_DIR/bin" "$CONF" 2>/dev/null; then
  bad "$CONF points somewhere other than $HOME_DIR/bin — fix: $HOME_DIR/install.sh"
elif grep -qF "$CONF" "$HOME/.tmux.conf" 2>/dev/null; then
  ok "~/.tmux.conf sources $CONF"
else
  bad "~/.tmux.conf does not source $CONF — fix: $HOME_DIR/install.sh"
fi

# The two launchd jobs: snapshot/restore/lifecycle every 5 min, battery guard every 60s.
# Opt-in, so "not loaded" is a choice, not a fault. Without them: snapshots
# still happen on tmux's own hooks, but there is no 5-minute clock, no restore
# at login, and no battery guard.
for job in persist power; do
  if launchctl print "gui/$(id -u)/com.tmux-agents.$job" >/dev/null 2>&1; then
    ok "launchd job com.tmux-agents.$job is loaded"
  elif [ -e "$HOME/Library/LaunchAgents/com.tmux-agents.$job.plist" ]; then
    bad "com.tmux-agents.$job is installed but NOT loaded — fix: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tmux-agents.$job.plist"
  else
    warn "com.tmux-agents.$job is not installed (optional) — add it with: $HOME_DIR/install.sh --with-launchd"
  fi
done

if tmux info >/dev/null 2>&1; then
  if tmux list-keys 2>/dev/null | grep -q 'tmux-agent-pick'; then
    ok "prefix + a is bound in the running server"
  else
    bad "prefix + a is NOT bound — run: tmux source-file ~/.tmux.conf"
  fi
  if tmux list-keys 2>/dev/null | grep -q 'tmux-agent-next'; then
    ok "prefix + j jumps to the waiting agent"
  else
    warn "prefix + j is not bound — run: tmux source-file ~/.tmux.conf"
  fi
  if tmux list-keys 2>/dev/null | grep -q 'tmux-file-pick'; then
    ok "prefix + f is bound in the running server"
  else
    warn "prefix + f is not bound (fine if you commented it out to keep find-window)"
  fi
  if tmux show -gv status-right 2>/dev/null | grep -q 'tmux-agent-status'; then
    ok "agent counts are in your status line"
  else
    warn "no agent counts in status-right — add to tmux.conf:"
    printf '      %s#(%s/bin/tmux-agent-status.sh)%s\n' "$DIM" "$HOME_DIR" "$Z"
  fi
  nh=$(tmux show-hooks -g 2>/dev/null | grep -c 'tmux-agent-autosave' || true)
  if [ "${nh:-0}" -ge 9 ]; then
    ok "snapshot-on-change hooks are set ($nh)"
  else
    warn "only $nh of 9 autosave hooks are set — run: tmux source-file ~/.tmux.conf"
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
  . "$HOME_DIR/shell/tmux-persist.sh" 2>/dev/null || warn "shell/tmux-persist.sh does not load"
  . "$HOME_DIR/shell/quick-agents.sh" 2>/dev/null || warn "shell/quick-agents.sh does not load"
  . "$HOME_DIR/shell/favorites.sh" 2>/dev/null || warn "shell/favorites.sh does not load"
  for fn in t tl ta ts tw tk tmv tq tf tsleep twake tsnaps tsave trestore tarchive tpower tdoctor \
            _t_agent_rows _t_new_session _t_kill_agent _t_agent_pid _t_agent_sid; do
    declare -F "$fn" >/dev/null 2>&1 || missing="$missing $fn"
  done
  if [ -n "$missing" ]; then bad "helpers loaded but these are missing:$missing"
  else ok "every command in t --help is defined"
  fi
  # ---------------------------------------------------------------------
  # Detection, checked against a second opinion
  # ---------------------------------------------------------------------
  # Everything in this tool reads from one heuristic: an agent is a pane whose
  # title starts with a short non-alphanumeric glyph, because that is what
  # Claude Code writes there. It costs nothing and needs no hook, and it is
  # entirely outside our control.
  #
  # The danger is not that it breaks. It is that a break is invisible: `ta`
  # prints nothing, the status line reads 0/0/0, prefix+j says nobody is
  # waiting, and this check used to print "detection runs — sees 0" and call
  # itself ok. Every one of those looks exactly like a quiet afternoon.
  #
  # So ask a second, independent question. Claude Code renames the pane's
  # COMMAND to its own version string ("2.1.271") — a different tmux field, set
  # by a different mechanism, that would have to break in the same release for
  # both to go quiet together. Any pane that looks like an agent by command but
  # is missing from the rows means the title contract has moved.
  n=$(_t_agent_rows 2>/dev/null | wc -l | tr -d ' ')
  detected=$(_t_agent_rows 2>/dev/null | cut -f3)

  extra_re=""
  for pr in ${TMUX_AGENT_EXTRA_PROCS:-}; do extra_re="$extra_re|^$pr\$"; done
  suspects=$(tmux list-panes -a -F '#{pane_id}	#{pane_current_command}	#{pane_title}' 2>/dev/null \
             | awk -F'\t' -v extra="$extra_re" '
                 $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print; next }
                 extra != "" && $2 ~ substr(extra, 2) { print }')

  # Count in a variable rather than by counting lines afterwards: the report is
  # indented, and `grep -c .` happily counts a line of spaces as content.
  blind=""; nsus=0; nblind=0
  while IFS="$(printf '\t')" read -r pid cmd title; do
    [ -n "$pid" ] || continue
    nsus=$((nsus + 1))
    case "
$detected
" in
      *"
$pid
"*) ;;
      *) nblind=$((nblind + 1))
         blind="$blind$pid ($cmd) title=\"$title\"
" ;;
    esac
  done <<EOF
$suspects
EOF

  if [ "$nblind" -gt 0 ]; then
    bad "agent detection is BLIND to $nblind of $nsus pane(s) that look like agents:"
    printf '%s' "$blind" | while IFS= read -r l; do [ -n "$l" ] && printf '      %s%s%s\n' "$DIM" "$l" "$Z"; done
    say "      The pane title contract has probably changed. Detection keys on a"
    say "      short non-alphanumeric glyph at the start of #{pane_title}."
  elif [ "$nsus" -gt 0 ]; then
    ver=$(printf '%s\n' "$suspects" | awk -F'\t' 'NF{print $2; exit}')
    ok "detection agrees with a second signal — $nsus/$nsus agent pane(s) classify (claude $ver)"
  elif [ "$n" -gt 0 ]; then
    ok "agent detection sees $n, none of them a recognised agent CLI (extra procs?)"
  else
    warn "no agents running, so detection is unverified — start one and re-run"
  fi
else
  bad "shell/agents.sh does not load"
fi

# ---------------------------------------------------------------------------
# macOS caches each process's privacy decision for that process's lifetime, so an
# agent that started before a grant keeps seeing the old answer however many times
# you re-toggle System Settings. It surfaces as computer-use insisting that
# permissions are "not yet granted" when they visibly are. This is the check that
# turns that from a 40-minute misdiagnosis into a line of output.
#
# It lives HERE and not in `ta` or the status line on purpose — see the note above
# _t_tcc_mtime. TCC.db moves whenever any app's privacy setting changes, so most
# agents are "stale" most of the time; as a permanent column it would be wallpaper.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && declare -F _t_tcc_stale >/dev/null 2>&1; then
  head_ "macOS permissions (TCC)"
  tccm=$(_t_tcc_mtime)
  if [ -z "$tccm" ]; then
    warn "can't read either TCC database — skipping the staleness check"
  else
    tccwhen=$(date -r "$tccm" '+%Y-%m-%d %H:%M' 2>/dev/null)
    stale=$(_t_tcc_stale)
    nstale=$(printf '%s' "$stale" | wc -w | tr -d ' ')
    if [ "${nstale:-0}" -eq 0 ]; then
      ok "no agent predates the last permission change ($tccwhen)"
    else
      warn "$nstale agent(s) started BEFORE the last permission change ($tccwhen)"
      tmux list-panes -a -F '#{pane_pid}	#{session_name}	#{window_name}' 2>/dev/null |
        while IFS=$(printf '\t') read -r ppid psess pwin; do
          case " $stale " in
            *" $ppid "*) printf '      %s· %s (%s)%s\n' "$DIM" "$psess" "$pwin" "$Z" ;;
          esac
        done
      printf '      %sThey cannot see privacy grants made since then — macOS caches a%s\n' "$DIM" "$Z"
      printf '      %sprocess'"'"'s TCC decision for its whole life. computer-use will report%s\n' "$DIM" "$Z"
      printf '      %s"permission(s) not yet granted" against settings that show granted.%s\n' "$DIM" "$Z"
      printf '      %sFix: Ctrl+b R in that window restarts claude in place and resumes the%s\n' "$DIM" "$Z"
      printf '      %sconversation — NOT tmux kill-server, and NOT re-toggling System%s\n' "$DIM" "$Z"
      printf '      %sSettings. Only matters for agents doing desktop automation.%s\n' "$DIM" "$Z"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# tmux parses every target as session:window.pane, so a session whose NAME holds
# a dot cannot be addressed by name at all — `kill-session -t "=release-2.0"`
# answers "can't find pane: 0" and the session lives on. New ones can't be made
# any more, but any that predate the guard are worth naming here rather than
# being found the hard way.
if declare -F _t_session_id >/dev/null 2>&1; then
  dotted=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '\.' || true)
  if [ -n "$dotted" ]; then
    head_ "Session names"
    n=$(printf '%s\n' "$dotted" | grep -c .)
    warn "$n session(s) have a '.' in the name and can't be targeted by name"
    printf '%s\n' "$dotted" | while IFS= read -r s; do
      [ -n "$s" ] && printf '      %s· %s%s\n' "$DIM" "$s" "$Z"
    done
    printf '      %sthey were made before the guard in _t_new_session. `tk NAME` and the%s\n' "$DIM" "$Z"
    printf '      %spicker'"'"'s ctrl-x now resolve the session id first, so both work — or%s\n' "$DIM" "$Z"
    printf '      %srename it out of the way with: tmv NEW-NAME (from inside the session)%s\n' "$DIM" "$Z"
  fi
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

notify_on="${TMUX_AGENT_NOTIFY:-}"
notify_how="\$TMUX_AGENT_NOTIFY"
if [ -z "$notify_on" ]; then
  notify_on=$(tmux show-option -gqv @agent-notify 2>/dev/null)
  notify_how="@agent-notify"
fi
if [ "${notify_on:-0}" = 1 ]; then
  osmaj=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
  if [ -n "${TMUX_AGENT_NOTIFY_CMD:-}" ]; then
    ok "desktop notifications on ($notify_how), via \$TMUX_AGENT_NOTIFY_CMD"
  elif tmux list-clients 2>/dev/null | grep -q ghostty; then
    ok "desktop notifications on ($notify_how), through Ghostty (OSC 777)"
    if [ "$(tmux show -gv allow-passthrough 2>/dev/null)" = all ]; then
      ok "  allow-passthrough is all, so agents in other windows get through"
    else
      bad "  allow-passthrough is '$(tmux show -gv allow-passthrough 2>/dev/null)' — must be 'all': run tmux source-file ~/.tmux.conf"
    fi
    printf '      %sif nothing appears: System Settings > Notifications > Ghostty > Allow%s\n' "$DIM" "$Z"
  elif [ "${osmaj:-0}" -ge 26 ] 2>/dev/null; then
    warn "notifications on, but no Ghostty client attached and macOS $osmaj has dropped terminal-notifier/osascript delivery"
  elif command -v terminal-notifier >/dev/null 2>&1; then
    ok "desktop notifications on ($notify_how, terminal-notifier)"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    ok "desktop notifications on ($notify_how, osascript)"
  elif command -v notify-send >/dev/null 2>&1; then
    ok "desktop notifications on ($notify_how, notify-send)"
  else
    warn "notifications are on but no notifier was found — nothing will be sent"
  fi
else
  warn "desktop notifications off — turn on with: tmux set -g @agent-notify 1"
fi

# ---------------------------------------------------------------------------
head_ "Name collisions"
clash=0
for fn in t tl ta ts tw tk td tq tf tmv; do
  # type -aP lists only real files on $PATH, which is the whole question here.
  # Plain `type -a` would report the functions this script just sourced itself,
  # and its multi-line function bodies, as if they were collisions.
  paths=""
  for pth in $(type -aP "$fn" 2>/dev/null); do
    # Our own standalone entry points are the function by another door, not a clash.
    [ "$(readlink "$pth" 2>/dev/null)" = "$HOME_DIR/bin/tmux-agent-cli.sh" ] && continue
    paths="$paths$pth "
  done
  if [ -n "$paths" ]; then
    warn "$fn shadows a real command: $paths"
    clash=1
  fi
done
if [ "$clash" = 0 ]; then
  ok "no shadowed commands"
else
  printf '      %sthe function wins in an interactive shell; see the README for how to%s\n' "$DIM" "$Z"
  printf '      %sload only the keybindings if you would rather keep the command.%s\n' "$DIM" "$Z"
fi

# ---------------------------------------------------------------------------
if [ "$FAILED" = 0 ]; then
  printf '\n%s✓ tmux-agents looks healthy.%s\n\n' "$G" "$Z"
else
  printf '\n%s✗ something above needs fixing.%s\n\n' "$R" "$Z"
fi
exit "$FAILED"
