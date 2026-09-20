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
for f in "$ROOT"/bin/*.sh "$ROOT"/hooks/*.sh "$ROOT"/shell/*.sh "$ROOT"/install.sh "$ROOT"/test/smoke.sh; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done
# NOT `sh -n shell/agents.sh`. That check was here on the belief that run-shell
# hands this file to sh, and it is not true: every run-shell in the tmux config
# invokes a script FILE, each with a bash shebang, and those scripts source the
# helpers from bash. sh never parses our shell/ files.
#
# It passed for years only because macOS /bin/sh is bash in sh-mode. On a Linux
# runner /bin/sh is dash and it fails immediately — agents.sh has 17 array
# constructs and 8 here-strings and has always been openly bash.
#
# What actually has to hold is the shebang contract, so check that instead.
for f in $(grep -ohE '@TMUX_AGENTS_HOME@/bin/[a-z-]+\.sh' "$ROOT"/tmux/*.conf.in | sed 's|@TMUX_AGENTS_HOME@/||' | sort -u); do
  check "run-shell target $f declares bash (sh must never parse our code)" \
    "head -1 '$ROOT/$f' | grep -q 'bash'"
done

printf '\nshell helpers load together\n'
# Sourced in the order install.sh writes into the rc. A failure here is the
# whole shell layer being dead, so say WHY rather than just failing.
source_all_out=$(bash -c '
  set -u
  for f in agents.sh quick-agents.sh tmux-persist.sh favorites.sh; do
    . "$1/shell/$f" || { echo "failed sourcing $f" >&2; exit 1; }
  done' _ "$ROOT" 2>&1)
if [ $? -eq 0 ]; then
  ok "all four shell files source in install order"
else
  no "all four shell files source in install order"
  printf '      %s\n' "$source_all_out" | head -5
fi
for fn in t tl ta ts tk tmv tq tf tsave trestore tdoctor tpower; do
  check "defines $fn" \
    "bash -c 'for f in agents.sh quick-agents.sh tmux-persist.sh favorites.sh; do . \"$ROOT/shell/\$f\"; done; declare -F $fn >/dev/null || type $fn >/dev/null 2>&1'"
done
# The doctor asserts a list of function names. When a function is renamed or
# dropped, that list is what goes stale — and it fails at the user, not here.
check "every function the doctor expects is actually defined" \
  "bash -c '
    for f in agents.sh quick-agents.sh tmux-persist.sh favorites.sh; do . \"$ROOT/shell/\$f\"; done
    miss=\"\"
    for fn in \$(sed -n \"s/^  for fn in \\(.*\\) \\\\\\\\\$/\\1/p;s/^            \\(_t_.*\\); do\\\$/\\1/p\" \"$ROOT/bin/tmux-agents-doctor.sh\"); do
      declare -F \"\$fn\" >/dev/null 2>&1 || miss=\"\$miss \$fn\"
    done
    [ -z \"\$miss\" ] || { echo \"missing:\$miss\" >&2; exit 1; }
  '"

# A file your rc sources must return 0. quick-agents.sh ended with a
# `tmux set-hook -g`, which needs a running SERVER — so with tmux installed and
# no server up (every first shell after a reboot) the hook failed and, being the
# last command, became the file's exit status. Under `set -e` in an rc that
# aborts the rest of your shell startup.
#
# TMUX_TMPDIR at an empty directory is how "installed but no server" is
# simulated; plain `unset TMUX` is not enough, since tmux still finds the socket.
NOSRV=$(mktemp -d)
for f in agents quick-agents tmux-persist favorites; do
  check "shell/$f.sh returns 0 with tmux installed but no server running" \
    "[ \"\$(env -u TMUX TMUX_TMPDIR='$NOSRV' bash -c '
        . \"$ROOT/shell/agents.sh\" >/dev/null 2>&1
        . \"$ROOT/shell/$f.sh\" >/dev/null 2>&1
        echo \$?')\" = 0 ]"
done

check "_TA_BIN resolves to this clone's bin/" \
  "bash -c '. \"$ROOT/shell/agents.sh\"; [ \"\$_TA_BIN\" = \"$ROOT/bin\" ]'"
check "tmux-favorites-pick.sh finds favorites.sh where it looks for it" \
  "[ -r '$ROOT/shell/favorites.sh' ] && grep -q 'shell/favorites.sh' '$ROOT/bin/tmux-favorites-pick.sh'"

printf '\nnothing personal leaked\n'
# This repo was assembled out of a personal dotfiles repo. These are the names
# that came with it; none of them belong in a public tree.
for word in hermes ryannorris desktop-setup prescriberpoint; do
  check "no '$word' anywhere" \
    "! grep -rniq '$word' '$ROOT/bin' '$ROOT/shell' '$ROOT/tmux' '$ROOT/hooks' '$ROOT/macos' '$ROOT/install.sh'"
done

printf '\nportability traps\n'
# Comments may mention it; code may not. Strip comments before looking.
# Only agents.sh: run-shell executes under sh, and a `<(` there is a syntax
# error that silently truncates the file and loses every function below it. The
# other three shell files are sourced only by bash scripts, which may use it.
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

printf '\nstuck, not thinking\n'
STHOME=$(mktemp -d); mkdir -p "$STHOME/.cache/tmux-agent-status"
STT="$STHOME/t.jsonl"; printf '{}\n' > "$STT"
printf '%s\n' "$STT" > "$STHOME/.cache/tmux-agent-status/700.transcript"
# _t_stuck reads the sweep's clock, so the test sets it the way _t_agent_rows does.
stuck() { ( . "$ROOT/shell/agents.sh"; HOME="$STHOME" _T_NOW=$(date +%s) TMUX_AGENT_STUCK_MINS="${MINS:-10}" \
            _t_stuck %700 /nowhere "$1" && echo stuck || echo fine ); }

check "a silent pane AND an idle transcript is stuck" \
  "touch -t 202001010000 '$STT'; [ \"\$(stuck 3600)\" = stuck ]"
check "a silent pane with a LIVE transcript is not stuck (it is mid-tool-call)" \
  "touch '$STT'; [ \"\$(stuck 3600)\" = fine ]"
check "a chatty pane with an idle transcript is not stuck" \
  "touch -t 202001010000 '$STT'; [ \"\$(stuck 5)\" = fine ]"
check "no transcript means no claim either way" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; HOME='$STHOME' _T_NOW=\$(date +%s) _t_stuck %999 /nowhere 99999 && echo stuck || echo fine )\" = fine ]"
check "TMUX_AGENT_STUCK_MINS=0 turns it off" \
  "touch -t 202001010000 '$STT'; [ \"\$(MINS=0 stuck 3600)\" = fine ]"
check "a junk threshold is off, not a crash" \
  "[ \"\$(MINS=soon stuck 3600)\" = fine ]"
check "a pane with no activity timestamp is never stuck" \
  "[ \"\$(stuck '')\" = fine ]"
rm -rf "$STHOME"

# Ordering and presentation: stuck is second only to waiting, and it is in the
# group that means "deal with me", not in a day.
SSTUB='
_t_agent_rows() {
  printf "○\tidle\t%%1\t@1\tzeta\tc\t/tmp\tt\t\t30\t101\n"
  printf "⊘\tstuck\t%%2\t@2\twedged\tc\t/tmp\tt\t\t2400\t102\n"
  printf "●\tworking\t%%3\t@3\tbusy\tc\t/tmp\tt\t\t5\t103\n"
  printf "◆\twaiting\t%%4\t@4\tasked\tc\t/tmp\tt\t60\t60\t104\n"
}
_t_proc_counts() { :; }'
check "stuck sorts under waiting and above working" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$SSTUB\"; _t_agent_display | cut -f5 | tr '\n' ' ' )\" = 'waiting stuck working idle ' ]"
check "stuck is filed under Needs you, not under a day" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$SSTUB\"; _t_agent_display | sed -n 2p | cut -f11 )\" = 'Needs you' ]"
# The status line script re-sources the helpers in its own process, so it gets a
# checkout whose helpers are the stub — the same door the real one comes through.
STATHOME=$(mktemp -d); mkdir -p "$STATHOME/shell" "$STATHOME/bin" "$STATHOME/jobs"
cp "$ROOT/bin/tmux-agent-status.sh" "$ROOT/bin/tmux-quick-job.sh" "$STATHOME/bin/"
printf '%s\n' '_t_agent_rows() { printf "⊘\tstuck\t%%1\n◆\twaiting\t%%2\n●\tworking\t%%3\n"; }' > "$STATHOME/shell/agents.sh"
STATOUT=$(TMUX_AGENTS_HOME="$STATHOME" TMUX_QUICK_JOB_DIR="$STATHOME/jobs" "$STATHOME/bin/tmux-agent-status.sh" 2>/dev/null)
check "the status line counts stuck separately" "printf '%s' \"$STATOUT\" | grep -q '⊘1'"
check "it is red, and next to the waiting count rather than the working one" \
  "printf '%s' \"$STATOUT\" | grep -q 'colour214,bold]◆1#\[none\] #\[fg=colour203,bold]⊘1'"
rm -rf "$STATHOME"
check "the transcript lookup is shared, not duplicated" \
  "[ \"\$(grep -c 'claude/projects' '$ROOT/shell/agents.sh')\" = 1 ]"

printf '\ngrouping by day\n'
# Seconds since local midnight, the same way _t_agent_display works it out — so
# "yesterday" here means the calendar day before this one, not 24 hours ago.
MIDNIGHT=$(( $(date +%-H) * 3600 + $(date +%-M) * 60 + $(date +%-S) ))
GSTUB="
_t_agent_rows() {
  printf '●\tworking\t%%1\t@1\tnow\tc\t/tmp\tt\t\t30\t201\n'
  printf '○\tidle\t%%2\t@2\tyesterday\tc\t/tmp\tt\t\t$((MIDNIGHT + 3600))\t202\n'
  printf '○\tidle\t%%3\t@3\tmidweek\tc\t/tmp\tt\t\t$((MIDNIGHT + 3 * 86400))\t203\n'
  printf '○\tidle\t%%4\t@4\tancient\tc\t/tmp\tt\t\t$((MIDNIGHT + 30 * 86400))\t204\n'
  printf '☾\tasleep\t%%5\t@5\tsleeper\tc\t/tmp\tt\t\t\t\n'
  printf '◆\twaiting\t%%6\t@6\tstale\tc\t/tmp\tt\t$((MIDNIGHT + 4 * 86400))\t9\t206\n'
}
_t_proc_counts() { :; }"
groups() { ( . "$ROOT/shell/agents.sh"; eval "$GSTUB"; _t_agent_display | cut -f11 | tr '\n' '|' ); }
labels() { ( . "$ROOT/shell/agents.sh"; eval "$GSTUB"; _t_agent_display | cut -f6 | tr '\n' '|' ); }

check "groups run needs-you, today, yesterday, this week, older, asleep" \
  "[ \"\$(groups)\" = 'Needs you|Today|Yesterday|This week|Older|Asleep|' ]"
check "an agent waiting since last week still sorts to the top" \
  "[ \"\$(labels | cut -d'|' -f1)\" = stale ]"
check "a sleeper is its own group, not a day" \
  "[ \"\$(labels | cut -d'|' -f6)\" = sleeper ]"
check "the group is column 11, leaving every earlier column where it was" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$GSTUB\"; _t_agent_display | head -1 | cut -f5 )\" = waiting ]"
check "ta draws a heading per group" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$GSTUB\"; ta | grep -c 'Needs you\|Today\|Yesterday\|This week\|Older\|Asleep' )\" = 6 ]"
check "ta's own columns still line up under the headings" \
  "( . '$ROOT/shell/agents.sh'; eval \"\$GSTUB\"; ta | grep -q '^◆  waiting' )"
# The picker re-sources the helpers in its own process, so a stub here can't
# reach it. Feed its heading awk the stubbed rows directly instead — same
# program, extracted from the script so the two can't drift.
PICKAWK=$(sed -n "/\\\$11 != seen/,/\\\$7 }'/p" "$ROOT/bin/tmux-agent-picker.sh" | sed "s/}'\$/}/")
check "the picker emits one heading per group, with an empty pane id" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; eval \"\$GSTUB\"; _t_agent_display |
       awk -F'\t' -v dim= -v off= \"\$PICKAWK\" | awk -F'\t' '\$1 == \"\" { n++ } END { print n+0 }' )\" = 6 ]"
check "the picker reopens rather than exiting when a heading is chosen" \
  "grep -q 'can only be a' '$ROOT/bin/tmux-agent-picker.sh'"
check "no Unicode escapes in awk — they are not portable" \
  "! grep -n 'gsub(.*\\\\\\\\u00' '$ROOT/shell/agents.sh'"

printf '\ncontext usage\n'
CTXHOME=$(mktemp -d); mkdir -p "$CTXHOME/.cache/tmux-agent-status"
# A transcript shaped like Claude Code's: the last non-sidechain assistant turn is
# what counts, and a sidechain turn after it must not win.
CTXFILE="$CTXHOME/t.jsonl"
printf '%s\n' '{"type":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":9}}' > "$CTXFILE"
printf '%s\n' '{"type":"assistant","usage":{"input_tokens":2,"cache_creation_input_tokens":300,"cache_read_input_tokens":50000,"output_tokens":40,"server_tool_use":{"web_search_requests":0}}}' >> "$CTXFILE"
printf '%s\n' '{"type":"assistant","isSidechain":true,"usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":999999,"output_tokens":1}}' >> "$CTXFILE"
printf '%s\n' "$CTXFILE" > "$CTXHOME/.cache/tmux-agent-status/900.transcript"

check "sums input + cache_creation + cache_read of the last real turn" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; HOME='$CTXHOME' _t_context_tokens %900 /nowhere )\" = 50302 ]"
check "a subagent's turn does not count as the main thread's context" \
  "[ \"\$( . '$ROOT/shell/agents.sh'; HOME='$CTXHOME' _t_context_tokens %900 /nowhere )\" != 1000002 ]"
check "no transcript, no guess" \
  "[ -z \"\$( . '$ROOT/shell/agents.sh'; HOME='$CTXHOME' _t_context_tokens %901 /nowhere )\" ]"
check "the second read is served from cache" \
  ". '$ROOT/shell/agents.sh'; HOME='$CTXHOME' _t_context_tokens %900 /nowhere >/dev/null; [ -f '$CTXHOME/.cache/tmux-agent-status/900.ctx' ]"
check "two agents sharing a folder get no context rather than each other's" \
  "[ -z \"\$( . '$ROOT/shell/agents.sh'; HOME='$CTXHOME' _t_context_map <<< \"\$(printf '●\tworking\t%%1\t@1\ta\tc\t/shared\tt\t\t1\t11\n●\tworking\t%%2\t@2\tb\tc\t/shared\tt\t\t1\t12\n')\" )\" ]"
check "tokens, not a fabricated percentage, by default" \
  "grep -q 'TOKENS, NOT A PERCENTAGE' '$ROOT/shell/agents.sh'"
check "hook records the transcript path for exact attribution" \
  "grep -q 'transcript_path' '$ROOT/hooks/claude-status-hook.sh'"
rm -rf "$CTXHOME"

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

printf '\nquick jobs\n'
QJ="$ROOT/bin/tmux-quick-job.sh"
QJTMP=$(mktemp -d)
cat > "$QJTMP/fake" <<'FAKE'
#!/usr/bin/env bash
sleep 1
printf '{"type":"result","is_error":false,"result":"## Heading\\n\\nthe answer is 4","session_id":"s-1"}\n'
FAKE
cat > "$QJTMP/fail" <<'FAKE'
#!/usr/bin/env bash
echo "boom: not logged in" >&2; exit 1
FAKE
chmod +x "$QJTMP/fake" "$QJTMP/fail"
qj() { TMUX_QUICK_JOB_DIR="$QJTMP/jobs" TMUX_QUICK_JOB_CMD="$QJTMP/${QJCMD:-fake}" TMUX_AGENT_NOTIFY=0 "$QJ" "$@"; }
if command -v python3 >/dev/null 2>&1; then
  check "tj TASK dispatches and prints an id" "qj what is 2+2 | grep -q '^⚡ '"
  check "a fresh job reads as running, not lost" "qj | head -1 | grep -q '^⚡'"
  check "the status line counts it" "qj --status | grep -q '⚡1'"
  check "tj wait returns the parsed answer" "qj wait | grep -qx 'the answer is 4'"
  check "the session id is kept for tj resume" "grep -qx s-1 \"\$(ls -d '$QJTMP'/jobs/*/ | head -1)session\""
  check "reading it clears the unread count" "[ -z \"\$(qj --status)\" ]"
  QJCMD=fail qj this will fail >/dev/null; sleep 2
  check "a failed job shows as ✗ with its stderr as output" \
    "qj | head -1 | grep -q '^✗' && qj show | grep -q 'not logged in'"
  check "an empty task is refused" "! qj '   ' 2>/dev/null"
  check "tj --help is the header" "qj --help | grep -q 'prefix + Q'"
else
  no "quick jobs need python3 to detach"
fi
check "the worker finds claude off the tmux server's PATH" "grep -q 'HOME/.local/bin' '$QJ'"
check "a missing agent command is a failure, not a success" \
  "! grep -q 'code=\\\${code:-' '$QJ' && grep -q 'code=127' '$QJ'"
check "prefix + Q is in the config template" "grep -q 'bind Q .*tmux-quick-job.sh --popup' '$ROOT/tmux/agents.conf.in'"
rm -rf "$QJTMP"

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

printf '\nthe ported surface\n'
# Everything below arrived with the port and had no coverage before it.
HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --with-extras --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
CONF="$TMPHOME/.config/tmux-agents/agents.conf"

for key in 'bind F' 'bind A' 'bind R' 'bind S' 'bind B'; do
  check "rendered conf has $key" "grep -q '^$key ' '$CONF'"
done
check "all ten autosave hooks are rendered" \
  "[ \"\$(grep -c '^set-hook .*tmux-agent-autosave.sh' '$CONF')\" = 10 ]"
check "notifications need passthrough 'all', and the conf sets it" \
  "grep -q '^set -g allow-passthrough all' '$CONF'"
check "extras does not downgrade passthrough back to 'on'" \
  "! grep -q '^set -g allow-passthrough on' '$TMPHOME/.config/tmux-agents/extras.conf'"
check "no placeholder survives into extras.conf" \
  "! grep -q '@[A-Z_]*@' '$TMPHOME/.config/tmux-agents/extras.conf'"

check "rc sources all four shell files" \
  "[ \"\$(grep -c 'shell/.*\.sh' '$TMPHOME/.bash_profile')\" = 4 ]"
check "agents.sh is sourced before the files that need _TA_BIN" \
  "[ \"\$(grep -n 'shell/agents.sh' '$TMPHOME/.bash_profile' | cut -d: -f1 | head -1)\" -lt \"\$(grep -n 'shell/tmux-persist.sh' '$TMPHOME/.bash_profile' | cut -d: -f1 | head -1)\" ]"

for n in tsave trestore tdoctor tf tlifecycle; do
  check "installs the $n command" \
    "[ \"\$(readlink '$TMPHOME/.local/bin/$n')\" = '$ROOT/bin/tmux-agent-cli.sh' ] || [ \"\$(readlink '$TMPHOME/.local/bin/$n')\" = '$ROOT/bin/tmux-agent-lifecycle.sh' ]"
done
check "--no-cli skips the command symlinks" \
  "rm -rf '$TMPHOME/.local/bin' && HOME='$TMPHOME' XDG_CONFIG_HOME='$TMPHOME/.config' '$ROOT/install.sh' --no-cli --rc '$TMPHOME/.bash_profile' --tmux-conf '$TMPHOME/.tmux.conf' >/dev/null 2>&1 && [ ! -e '$TMPHOME/.local/bin/tsave' ]"

# A real file at one of our names belongs to another tool.
HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
# rm first: `>` on a symlink writes through it — into this repo's bin/.
rm -f "$TMPHOME/.local/bin/tf"
printf 'not ours\n' > "$TMPHOME/.local/bin/tf"
HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
check "never clobbers a real file at one of our command names" \
  "grep -q 'not ours' '$TMPHOME/.local/bin/tf'"
rm -f "$TMPHOME/.local/bin/tf"

# tmux starts a login shell; bash logins never read ~/.bashrc. Getting this
# wrong means `t` starts an agent with the bare binary instead of your alias —
# same word, different flags, and nothing reports it.
LSH="$TMPHOME/lsh"
lsh_case() { # name  bash_profile-content  expected(set|unset)
  rm -rf "$LSH/$1"; mkdir -p "$LSH/$1/.config"
  printf '%s\n' "$2" > "$LSH/$1/.bash_profile"
  printf 'alias claude="claude --x"\n'  > "$LSH/$1/.bashrc"
  : > "$LSH/$1/.tmux.conf"
  HOME="$LSH/$1" XDG_CONFIG_HOME="$LSH/$1/.config" SHELL=/bin/bash \
    "$ROOT/install.sh" --no-cli --rc "$LSH/$1/.bash_profile" --tmux-conf "$LSH/$1/.tmux.conf" >/dev/null 2>&1
  if grep -qE '^set -g default-command' "$LSH/$1/.config/tmux-agents/agents.conf"; then echo set; else echo unset; fi
}
check "login shell that never reads .bashrc gets default-command" \
  "[ \"\$(lsh_case unreachable '# .bashrc sources this file, not the reverse')\" = set ]"
check ".bash_profile that sources .bashrc is left alone" \
  "[ \"\$(lsh_case plain '. \$HOME/.bashrc')\" = unset ]"
check "the if-then form counts as sourcing it" \
  "[ \"\$(lsh_case ifthen 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi')\" = unset ]"
check "a commented-out source does not count" \
  "[ \"\$(lsh_case commented '#. ~/.bashrc')\" = set ]"
check "a path containing a dot is not a source command" \
  "[ \"\$(lsh_case dotpath 'export PATH=\$PATH:/opt/x.y/bin')\" = set ]"
check "--login-shell forces tmux's default back" \
  "rm -rf '$LSH/f1' && mkdir -p '$LSH/f1/.config' && printf '# nothing\n' > '$LSH/f1/.bash_profile' && printf 'alias c=x\n' > '$LSH/f1/.bashrc' && : > '$LSH/f1/.tmux.conf' && HOME='$LSH/f1' XDG_CONFIG_HOME='$LSH/f1/.config' SHELL=/bin/bash '$ROOT/install.sh' --no-cli --login-shell --rc '$LSH/f1/.bash_profile' --tmux-conf '$LSH/f1/.tmux.conf' >/dev/null 2>&1 && ! grep -qE '^set -g default-command' '$LSH/f1/.config/tmux-agents/agents.conf'"
check "--no-login-shell forces it on" \
  "rm -rf '$LSH/f2' && mkdir -p '$LSH/f2/.config' && printf '. ~/.bashrc\n' > '$LSH/f2/.bash_profile' && printf 'alias c=x\n' > '$LSH/f2/.bashrc' && : > '$LSH/f2/.tmux.conf' && HOME='$LSH/f2' XDG_CONFIG_HOME='$LSH/f2/.config' SHELL=/bin/bash '$ROOT/install.sh' --no-cli --no-login-shell --rc '$LSH/f2/.bash_profile' --tmux-conf '$LSH/f2/.tmux.conf' >/dev/null 2>&1 && grep -qE '^set -g default-command' '$LSH/f2/.config/tmux-agents/agents.conf'"

# The snapshot is a TSV with a fixed column order, written in one place and read
# in three. When columns were inserted ahead of is_agent, `tsnaps -l` kept reading
# the old positions and reported "0 agents" against data that was correct. Pin the
# contract to the header the writer emits, so a future insert fails here.
SNAPCOLS='P session window_index window_name window_active window_layout pane_index pane_active cwd command title pane_id opt_sid opt_task is_agent task session_id'
check "the snapshot writer still emits the column order everyone reads" \
  "grep -qF '$SNAPCOLS' '$ROOT/bin/tmux-agent-save.sh'"
check "is_agent is column 15, task 16, session_id 17" \
  "[ \"\$(printf '%s\n' $SNAPCOLS | grep -nx is_agent | cut -d: -f1)\" = 15 ] &&
   [ \"\$(printf '%s\n' $SNAPCOLS | grep -nx task | cut -d: -f1)\" = 16 ] &&
   [ \"\$(printf '%s\n' $SNAPCOLS | grep -nx session_id | cut -d: -f1)\" = 17 ]"
check "tsnaps -l reads is_agent at 15, not an older position" \
  "grep -q 'if (\$15 == 1)' '$ROOT/shell/tmux-persist.sh' && ! grep -q 'if (\$12 == 1)' '$ROOT/shell/tmux-persist.sh'"
check "trestore reads the snapshot by name, in writer order" \
  "grep -q 'read -r tag session widx wname wactive wlayout pidx pactive cwd cmd title paneid optsid opttask isagent task sid' '$ROOT/bin/tmux-agent-restore.sh'"

# "Is this pane an agent?" is answered in two places — shell/agents.sh for
# everything live, bin/tmux-agent-save.sh for the snapshot. They drifted: one
# accepted any single-character first token, the other required a
# non-alphanumeric one, so a pane could be a working agent to the status line
# and a plain shell to the snapshot with neither side reporting anything.
glyph_agents() { # the rule as shell/agents.sh applies it
  local t="$1" first="${1%% *}" g=0
  if [ "$t" != "$first" ] && [ -n "$first" ] && [ ${#first} -le 4 ]; then
    case "$first" in *[[:alnum:]]*) ;; *) g=1 ;; esac
  fi
  printf '%s' "$g"
}
glyph_save() {   # the rule as bin/tmux-agent-save.sh applies it
  printf '%s' "$1" | awk '{n=split($0,w," "); print (n>1 && w[1] !~ /[[:alnum:]]/ && length(w[1])<=4) ? 1 : 0}'
}
while IFS='|' read -r title want; do
  [ -n "$title" ] || continue
  # ${title} braced: a multibyte character immediately after $title gets
  # absorbed into the variable name in some locales, and the loop dies with
  # "unbound variable" on a name you never wrote.
  check "detection: «${title}» -> ${want}, and both sides agree" \
    "[ \"\$(glyph_agents '$title')\" = '$want' ] && [ \"\$(glyph_save '$title')\" = '$want' ]"
done <<'TITLES'
✳ writing the parser|1
◆ needs an answer|1
⠋ spinning up|1
a real fix for the parser|0
I think so|0
no glyph here|0
plain-shell-title|0
TITLES

check "the live classifier still requires a space after the glyph" \
  "[ \"\$(glyph_agents '✳')\" = 0 ]"

# The demo recordings are published. Two things have tried to get into them:
# tmux titles a plain pane with the HOSTNAME by default, and the snapshot header
# records it too. Both are staged over; check the committed artifacts, since a
# leak is only discoverable by reading the file it landed in.
for f in "$ROOT"/docs/demo/*.cast; do
  [ -e "$f" ] || continue
  check "no hostname in $(basename "$f")" \
    "! grep -qiE '$(hostname -s)|household-laptop' '$f'"
done
check "demo panes are given titles, so tmux does not use the hostname" \
  "grep -q '2;shell' '$ROOT/docs/demo/stage.sh'"
check "the staged snapshot's host is rewritten before it is recorded" \
  "grep -q 'workstation' '$ROOT/docs/demo/stage.sh'"

check "launchd plists are templates, not one person's paths" \
  "grep -q '@TMUX_AGENTS_HOME@' '$ROOT/macos/com.tmux-agents.persist.plist.in' && ! grep -rq '/Users/' '$ROOT/macos'"
# launchd is macOS. On Linux the installer correctly skips the whole block, so
# asserting the plist name appears would be asserting a bug.
if [ "$(uname -s)" = Darwin ]; then
  check "--with-launchd --dry-run renders without loading anything" \
    "HOME='$TMPHOME' '$ROOT/install.sh' --dry-run --with-launchd --rc '$TMPHOME/.bash_profile' --tmux-conf '$TMPHOME/.tmux.conf' 2>/dev/null | grep -q 'com.tmux-agents.persist.plist'"
else
  check "--with-launchd is a no-op off macOS" \
    "HOME='$TMPHOME' '$ROOT/install.sh' --dry-run --with-launchd --rc '$TMPHOME/.bash_profile' --tmux-conf '$TMPHOME/.tmux.conf' 2>/dev/null | grep -qv 'com.tmux-agents.persist.plist'"
fi

HOME="$TMPHOME" XDG_CONFIG_HOME="$TMPHOME/.config" \
  "$ROOT/install.sh" --uninstall --rc "$TMPHOME/.bash_profile" --tmux-conf "$TMPHOME/.tmux.conf" >/dev/null 2>&1
check "uninstall removes the command symlinks" "[ ! -e '$TMPHOME/.local/bin/tsave' ]"

printf '\n%s%d passed%s' "$G" "$PASS" "$Z"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$R" "$FAIL" "$Z"
printf '\n\n'
[ "$FAIL" = 0 ]
