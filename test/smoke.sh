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

printf '\nrows, sort and age\n'
# Stub _t_agent_rows in a subshell so the ordering and age formatting can be
# checked without three agents actually waiting. Deliberately out of order and
# alphabetically hostile: zeta idle, alpha working, mid waiting for 3700s.
STUB='
_t_agent_rows() {
  printf "○\tidle\t%%1\t@1\tzeta\tclaude\t/tmp\ttask\t\t7200\t101\n"
  printf "●\tworking\t%%2\t@2\talpha\tclaude\t/tmp\ttask\t\t45\t102\n"
  printf "◆\twaiting\t%%3\t@3\tmid\tclaude\t/tmp\ttask\t3700\t10\t103\n"
  printf "◇\trunning\t%%4\t@4\tbeta\taider\t/tmp\ttask\t\t5\t104\n"
}'
check "rows carry 11 fields" \
  "[ \"\$(_t_agent_rows | awk -F'\t' 'NR==1 { print NF }')\" = 11 ] || [ -z \"\$(_t_agent_rows)\" ]"
check "waiting sorts first, not alphabetically" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_agent_display | head -1 | cut -f6 )\" = mid ]"
check "then working, idle, running" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_agent_display | cut -f5 | tr '\n' ' ' )\" = 'waiting working idle running ' ]"
check "age renders as 1h" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_agent_display | head -1 | cut -f8 )\" = 1h ]"
# Superseded: non-waiting rows now carry time-since-last-output. What still has to
# hold is that a row with nothing to report shows nothing, rather than "0s".
check "a row with no timing data shows no age" \
  "[ -z \"\$( . '$ROOT/shell/agents.sh'; _t_agent_rows() { printf '●\tworking\t%%9\t@9\tnone\tc\t/tmp\tt\t\t\t999\n'; }; _t_proc_counts() { :; }; _t_agent_display | cut -f8 )\" ]"
check "ties sort alphabetically by label" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; _t_agent_rows() { printf '●\tworking\t%%1\t@1\tzeta\tc\t/tmp\tt\t\n●\tworking\t%%2\t@2\talpha\tc\t/tmp\tt\t\n'; }; _t_agent_display | head -1 | cut -f6 )\" = alpha ]"

check "silence shows for a non-waiting agent" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_proc_counts() { :; }; _t_agent_display | sed -n 2p | cut -f8 )\" = 45s ]"
check "an idle agent shows how long since it last spoke" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_proc_counts() { :; }; _t_agent_display | sed -n 3p | cut -f8 )\" = 2h ]"
check "waiting time still wins over silence for a waiting agent" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_proc_counts() { :; }; _t_agent_display | head -1 | cut -f8 )\" = 1h ]"

printf '\nprocess fan-out\n'
check "a busy agent is flagged with its process count" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_proc_counts() { printf '102:37 '; }; _t_agent_display | sed -n 2p | cut -f9 )\" = '⚙37' ]"
check "a quiet agent is not flagged" \
  "[ -z \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_proc_counts() { printf '102:3 '; }; _t_agent_display | sed -n 2p | cut -f9 )\" ]"
check "the threshold is tunable" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$STUB\"; _t_proc_counts() { printf '102:3 '; }; TMUX_AGENT_BUSY_PROCS=2 _t_agent_display | sed -n 2p | cut -f9 )\" = '⚙3' ]"
check "counting never walks a cycle forever" \
  "timeout 10 bash -c '. \"$ROOT/shell/agents.sh\"; _t_proc_counts >/dev/null'"

printf '\ndoctor\n'
check "doctor warns when the server outlives the app that launched it" \
  "grep -q 'NOT running any more' '$ROOT/bin/tmux-agents-doctor.sh'"

printf '\nnotifications\n'
NOTIFYLOG=$(mktemp)
printf '#!/bin/sh\nprintf "[%%s][%%s]" "$1" "$2" > %s\n' "$NOTIFYLOG" > "$NOTIFYLOG.cmd"
chmod +x "$NOTIFYLOG.cmd"
check "notifier uses \$TMUX_AGENT_NOTIFY_CMD when set" \
  "TMUX_AGENT_NOTIFY_CMD='$NOTIFYLOG.cmd' '$ROOT/bin/tmux-agent-notify.sh' 'T' 'M' && [ \"\$(cat '$NOTIFYLOG')\" = '[T][M]' ]"
check "notifier never fails when the notifier itself is missing" \
  "TMUX_AGENT_NOTIFY_CMD=/nonexistent/nope '$ROOT/bin/tmux-agent-notify.sh' 'T' 'M'"

# Behavioural, not a grep: run the hook the way Claude Code does — action, a pane
# id, a throwaway HOME for the marker — and see whether anything gets sent.
HOOKHOME=$(mktemp -d)
hook_run() {   # hook_run NOTIFY_VALUE  -> prints whatever reached the notifier
  : > "$NOTIFYLOG"
  rm -rf "$HOOKHOME/.cache"
  env HOME="$HOOKHOME" TMUX_PANE=%999 TMUX_AGENT_NOTIFY="$1" \
      TMUX_AGENT_NOTIFY_CMD="$NOTIFYLOG.cmd" \
      "$ROOT/hooks/claude-status-hook.sh" set </dev/null >/dev/null 2>&1
  sleep 0.4          # the hook backgrounds the notifier on purpose
  cat "$NOTIFYLOG" 2>/dev/null
}
check "hook sends nothing when notifications are off" "[ -z \"\$(hook_run 0)\" ]"
check "hook sends a notification when they are on" "[ -n \"\$(hook_run 1)\" ]"
check "TMUX_AGENT_NOTIFY=0 overrides the tmux option" \
  "grep -q 'TMUX_AGENT_NOTIFY:-' '$ROOT/hooks/claude-status-hook.sh'"
check "the switch is read at fire time, so a live toggle reaches running agents" \
  "grep -q 'show-option -gqv @agent-notify' '$ROOT/hooks/claude-status-hook.sh'"
check "hook still writes the waiting marker" \
  "hook_run 1 >/dev/null; ls '$HOOKHOME/.cache/tmux-agent-status/' | grep -q '999.waiting'"
check "no second notification while it stays waiting" \
  "hook_run 1 >/dev/null; : > '$NOTIFYLOG'; env HOME='$HOOKHOME' TMUX_PANE=%999 TMUX_AGENT_NOTIFY=1 TMUX_AGENT_NOTIFY_CMD='$NOTIFYLOG.cmd' '$ROOT/hooks/claude-status-hook.sh' set </dev/null >/dev/null 2>&1; sleep 0.4; [ -z \"\$(cat '$NOTIFYLOG')\" ]"
rm -rf "$HOOKHOME" 2>/dev/null

printf '\nrename\n'
check "defines tmv and _t_rename_session" \
  ". '$ROOT/shell/agents.sh'; declare -F tmv >/dev/null && declare -F _t_rename_session >/dev/null"
check "refuses an empty name" \
  "! ( . '$ROOT/shell/agents.sh'; _t_rename_session old '' 2>/dev/null )"
check "refuses a name with a slash" \
  "! ( . '$ROOT/shell/agents.sh'; _t_rename_session old 'a/b' 2>/dev/null )"
check "refuses a name starting with a dash" \
  "! ( . '$ROOT/shell/agents.sh'; _t_rename_session old '-x' 2>/dev/null )"
check "renaming to the same name is a no-op, not an error" \
  ". '$ROOT/shell/agents.sh'; _t_rename_session same same"
check "tmv refuses outside tmux" \
  "! ( . '$ROOT/shell/agents.sh'; unset TMUX; tmv newname 2>/dev/null )"
check "tmv is not tr (the real command stays reachable)" \
  ". '$ROOT/shell/agents.sh'; ! declare -F tr >/dev/null"
check "the folder is deliberately left where it is" \
  "grep -q 'FOLDER is deliberately left alone' '$ROOT/shell/agents.sh'"
# sed -i takes an argument on BSD and refuses one on GNU, so every caller has to
# go through _t_sed_inplace. The wrapper's own two branches are the exception.
check "no sed -i outside the portability wrapper" \
  "sed 's/#.*//' '$ROOT/shell/agents.sh' | awk '/^_t_sed_inplace\\(\\)/ { inw = 1 } inw && /^}/ { inw = 0 } !inw && /sed -i/ { bad = 1 } END { exit bad }'"

printf '\nfile browser sub-modes\n'
check "--list of a directory is non-empty" \
  "[ -n \"\$(TMUX_FILE_DIR='$ROOT' TMUX_FILE_MODE=dir '$ROOT/bin/tmux-file-picker.sh' --list)\" ]"
check "--list is sorted, directories first" \
  "TMUX_FILE_DIR='$ROOT' TMUX_FILE_MODE=dir '$ROOT/bin/tmux-file-picker.sh' --list | head -1 | grep -q '^\.\.$'"
check "recursive list refuses to walk other apps' data (TCC storm)" \
  "grep -q \"Library/Group Containers\" '$ROOT/bin/tmux-file-picker.sh'"
check "--list recursive is non-empty" \
  "[ -n \"\$(TMUX_FILE_DIR='$ROOT' TMUX_FILE_MODE=recursive '$ROOT/bin/tmux-file-picker.sh' --list)\" ]"
check "agent preview adds a git header for a repo" \
  "'$ROOT/bin/tmux-agent-picker.sh' --preview '' '$ROOT' | head -1 | grep -qE 'tmux-agents · .+ (clean|\\+[0-9]+ uncommitted)'"
check "agent preview adds nothing for a non-repo" \
  "[ -z \"\$('$ROOT/bin/tmux-agent-picker.sh' --preview '' /tmp)\" ]"
check "agent preview never writes to the repo (no index lock)" \
  "grep -q 'no-optional-locks' '$ROOT/bin/tmux-agent-picker.sh'"
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
