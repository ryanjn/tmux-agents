#!/usr/bin/env bash
# tmux-agents smoke test — no tmux server or GUI required, safe to run in CI.
#
#   ./test/smoke.sh
#
# Covers the things that have actually broken in this codebase:
#   - syntax, under bash AND sh (run-shell executes hooks under sh)
#   - no process substitution in the sourced helpers (a syntax error under sh
#     silently truncates the file and loses every function after that line)
#   - the helpers load and define what the pickers call
#   - listing and preview sub-modes produce output for real directories
#   - install.sh --dry-run touches nothing
#   - install/uninstall round-trip against a throwaway HOME
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
if [ -t 1 ]; then G=$(printf '\033[32m'); R=$(printf '\033[31m'); Z=$(printf '\033[0m')
else G=""; R=""; Z=""; fi

ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; PASS=$((PASS+1)); }
no()   { printf '  %s✗%s %s\n' "$R" "$Z" "$1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

printf '\ntmux-agents smoke test\n\n'

printf 'syntax\n'
for f in "$ROOT"/bin/*.sh "$ROOT"/hooks/*.sh "$ROOT"/shell/agents.sh "$ROOT"/install.sh "$ROOT"/test/smoke.sh; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done
check "sh -n shell/agents.sh (sourced by run-shell, which uses sh)" "sh -n '$ROOT/shell/agents.sh'"

printf '\nportability traps\n'
# Comments may mention it; code may not. Strip comments before looking.
check "no process substitution in shell/agents.sh" \
  "! sed 's/#.*//' '$ROOT/shell/agents.sh' | grep -q '< *<('"
check "no absolute paths to anyone's home" \
  "! grep -rn '/Users/' '$ROOT/bin' '$ROOT/shell' '$ROOT/tmux' '$ROOT/hooks'"
check "tmux config template has its placeholder" \
  "grep -q '@TMUX_AGENTS_HOME@' '$ROOT/tmux/agents.conf.in'"
# base-index defaults to 0, and only --with-extras sets it to 1. Any hardcoded
# ":1" window target silently addresses the wrong window on a default tmux.
check "no hardcoded window indexes" \
  "! sed 's/#.*//' '$ROOT/shell/agents.sh' '$ROOT'/bin/*.sh | grep -qE '\-t \"?=?\\\$[A-Za-z_]+:[0-9]'"

printf '\nhelpers\n'
# shellcheck disable=SC1090
. "$ROOT/shell/agents.sh" 2>/dev/null
for fn in t tl ta ts tw tk _t_agent_rows _t_agent_display _t_new_session \
          _t_focus _t_kill_agent _t_agent_alongside _t_uniq_window _t_session_notes; do
  check "defines $fn" "declare -F $fn"
done
check "version is set" "[ -n \"\${TMUX_AGENTS_VERSION:-}\" ]"

printf '\nfile browser sub-modes\n'
check "--list of a directory is non-empty" \
  "[ -n \"\$(TMUX_FILE_DIR='$ROOT' TMUX_FILE_MODE=dir '$ROOT/bin/tmux-file-picker.sh' --list)\" ]"
check "--list is sorted, directories first" \
  "TMUX_FILE_DIR='$ROOT' TMUX_FILE_MODE=dir '$ROOT/bin/tmux-file-picker.sh' --list | head -1 | grep -q '^\.\.$'"
check "--list recursive is non-empty" \
  "[ -n \"\$(TMUX_FILE_DIR='$ROOT' TMUX_FILE_MODE=recursive '$ROOT/bin/tmux-file-picker.sh' --list)\" ]"
check "--preview of a text file shows line numbers" \
  "TMUX_FILE_DIR='$ROOT' '$ROOT/bin/tmux-file-picker.sh' --preview README.md | grep -q '    1  '"
check "--preview of a directory lists it" \
  "TMUX_FILE_DIR='$ROOT' '$ROOT/bin/tmux-file-picker.sh' --preview bin/ | grep -q 'tmux-agent-do.sh'"
check "--preview of a missing file says so" \
  "TMUX_FILE_DIR='$ROOT' '$ROOT/bin/tmux-file-picker.sh' --preview no-such-file | grep -q 'gone'"

printf '\ndialog guard\n'
# The guard must key off the explicit marker, NOT off an empty $TMUX_PANE: that is
# also how `tmux run-shell` looks, which is where the dialogs actually run.
check "refuses inside a popup (marker set)" \
  "TMUX_AGENT_IN_POPUP=1 '$ROOT/bin/tmux-dialog.sh' confirm ' t ' 'q'; [ \$? = 2 ]"
check "does NOT refuse merely because TMUX_PANE is empty" \
  "! ( TMUX=fake TMUX_PANE= '$ROOT/bin/tmux-dialog.sh' confirm ' t ' 'q'; [ \$? = 2 ] )"
check "every popup we open sets the marker" \
  "[ \$(grep -c 'TMUX_AGENT_IN_POPUP=1' '$ROOT'/bin/tmux-agent-pick.sh '$ROOT'/bin/tmux-file-pick.sh | awk -F: '{s+=\$2} END {print s}') -ge 2 ]"

printf '\ninstaller\n'
TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT
: > "$TMPHOME/.tmux.conf"
printf 'export EXISTING=1\n' > "$TMPHOME/.bash_profile"

check "--dry-run changes nothing" \
  "HOME='$TMPHOME' '$ROOT/install.sh' --dry-run --rc '$TMPHOME/.bash_profile' --tmux-conf '$TMPHOME/.tmux.conf' >/dev/null && ! grep -q tmux-agents '$TMPHOME/.tmux.conf'"

HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
check "install adds a tmux block" "grep -q 'tmux-agents' '$TMPHOME/.tmux.conf'"
check "install adds a shell block" "grep -q 'agents.sh' '$TMPHOME/.bash_profile'"
check "install keeps existing rc content" "grep -q 'EXISTING=1' '$TMPHOME/.bash_profile'"
check "rendered config has real paths, no placeholder" \
  "grep -q '$ROOT/bin' '$TMPHOME/.config/tmux-agents/agents.conf' && ! grep -q '@TMUX_AGENTS_HOME@' '$TMPHOME/.config/tmux-agents/agents.conf'"
check "status line stays off by default" \
  "! grep -q '^set -g status-right' '$TMPHOME/.config/tmux-agents/agents.conf'"

# Re-running must replace its block, not stack another copy.
HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
check "re-install is idempotent (one block, not two)" \
  "[ \"\$(grep -c '>>> tmux-agents >>>' '$TMPHOME/.tmux.conf')\" = 1 ]"

HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --with-status --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
check "--with-status enables the status line" \
  "grep -q '^set -g status-right' '$TMPHOME/.config/tmux-agents/agents.conf'"

HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --uninstall --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
check "uninstall removes the tmux block" "! grep -q 'tmux-agents' '$TMPHOME/.tmux.conf'"
check "uninstall removes the shell block" "! grep -q 'agents.sh' '$TMPHOME/.bash_profile'"
check "uninstall leaves your own rc content alone" "grep -q 'EXISTING=1' '$TMPHOME/.bash_profile'"

printf '\n%s%d passed%s' "$G" "$PASS" "$Z"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$R" "$FAIL" "$Z"
printf '\n\n'
[ "$FAIL" = 0 ]
