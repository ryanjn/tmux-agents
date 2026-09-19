#!/usr/bin/env bash
# tmux-quick-job — ask for something, get the answer back, never see an agent.
#
#   prefix + Q                  a prompt; enter dispatches, the popup closes
#   tj "TASK"                   the same from any shell (runs in $PWD)
#   tj                          recent jobs            tj show [ID]   print an output
#   tj log [ID]                 its stderr             tj rm ID|--all  forget jobs
#
# A quick job is `claude -p` run detached until it finishes. No session, no
# window, nothing to babysit: when it is done you get a notification carrying the
# first line of the answer, and prefix + Q lists every recent job — enter on one
# reads the whole output.
#
# It is the other end of the scale from `tq`. `tq` is a throwaway *interactive*
# agent you still have to sit with; a quick job is a question you throw over the
# wall. Anything that turns out to need a conversation can be picked up again:
# every job keeps its session id, and `tj resume ID` opens it as a real agent.
#
# Where jobs live: $TMUX_QUICK_JOB_DIR (default ~/.local/state/tmux-agents/jobs),
# one directory each —
#
#   prompt  cwd  started  pid       written at dispatch
#   output.md  stderr  session      written as it finishes
#   exit  finished                  "exit" existing is what makes a job done
#   seen                            you have read it (clears the ✉ count)
#
# Configuration:
#
#   TMUX_QUICK_JOB_CMD    the agent command (default: claude). It is run as
#                         CMD -p --output-format json [FLAGS] PROMPT
#   TMUX_QUICK_JOB_FLAGS  extra flags, e.g. "--model sonnet" or
#                         "--permission-mode acceptEdits". Default: none, so a job
#                         runs under your Claude Code settings' defaultMode.
#   TMUX_QUICK_JOB_KEEP   how many finished jobs to keep (default 50)
#
# ⚠️  A job cannot ask you anything. A tool call your permission mode would have
# prompted for is simply denied, and the agent works around it or says it could
# not. That is the right failure for fire-and-forget; loosen it with
# TMUX_QUICK_JOB_FLAGS if your jobs need to write.
set -u

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)/tmux-quick-job.sh"
BIN="$(dirname "$SELF")"
JOBS="${TMUX_QUICK_JOB_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tmux-agents/jobs}"
KEEP="${TMUX_QUICK_JOB_KEEP:-50}"

# Same trap as tmux-agent-cli.sh: with no locale (launchd, a bare `bash -c`) tmux
# swaps the TAB in a format string for "_". Nothing here formats with tabs, but
# claude itself mangles non-ASCII output without one.
export LANG="${LANG:-en_US.UTF-8}"

# shellcheck disable=SC1090
[ -r "$BIN/tmux-ui.sh" ] && . "$BIN/tmux-ui.sh"

die() { echo "tj: $*" >&2; exit 1; }

# Single-quote for a command string tmux hands to sh.
_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ---------------------------------------------------------------------------
# Job state
# ---------------------------------------------------------------------------
# _state DIR — running | done | failed | lost
# "lost" is a job whose process is gone without writing an exit code: a reboot,
# or a kill -9. Telling it apart from "running" is the whole reason pid is kept.
_state() {
  local d="$1" code pid
  if [ -f "$d/exit" ]; then
    code=$(cat "$d/exit" 2>/dev/null)
    if [ "$code" = 0 ]; then echo "done"; else echo "failed"; fi
    return
  fi
  pid=$(cat "$d/pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo running; else echo lost; fi
}

# _jobs — job dirs, newest first. Ids sort by time, so a reverse name sort is it.
_jobs() {
  [ -d "$JOBS" ] || return 0
  # shellcheck disable=SC2012
  ls -1 "$JOBS" 2>/dev/null | sort -r | while IFS= read -r id; do
    [ -f "$JOBS/$id/prompt" ] && printf '%s\n' "$id"
  done
}

# _resolve [ID] — a job id; no argument means the newest. A unique prefix works,
# because nobody types 0917-142210-4821.
_resolve() {
  local want="${1:-}" hit n
  if [ -z "$want" ]; then _jobs | head -1; return; fi
  [ -d "$JOBS/$want" ] && { printf '%s\n' "$want"; return; }
  hit=$(_jobs | grep "^$want" || true)
  n=$(printf '%s' "$hit" | grep -c . || true)
  [ "$n" = 1 ] && { printf '%s\n' "$hit"; return; }
  [ "$n" = 0 ] && die "no job '$want'"
  die "'$want' matches $n jobs — be more specific"
}

_age() {
  local s=$(( $(date +%s) - $1 ))
  if   [ "$s" -lt 60 ];    then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ];  then printf '%dm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh' $((s / 3600))
  else printf '%dd' $((s / 86400)); fi
}

# _glyph STATE SEEN — one character a row can be read by at a glance.
_glyph() {
  case "$1" in
    running) printf '⚡' ;;
    failed|lost) printf '✗' ;;
    *) if [ "$2" = 1 ]; then printf '✓'; else printf '✉'; fi ;;
  esac
}

# _row ID — "ID<TAB>glyph age  prompt…  (folder)" for the list and `tj`.
_row() {
  local id="$1" d="$JOBS/$1" st seen started prompt where
  st=$(_state "$d")
  [ -f "$d/seen" ] && seen=1 || seen=0
  started=$(cat "$d/started" 2>/dev/null || echo 0)
  prompt=$(tr '\n' ' ' < "$d/prompt" | cut -c1-70)
  where=$(basename "$(cat "$d/cwd" 2>/dev/null)")
  printf '%s\t%s %4s  %-70s  %s\n' "$id" "$(_glyph "$st" "$seen")" "$(_age "$started")" "$prompt" "$where"
}

# _prune — keep the newest $KEEP finished jobs. Running ones are never touched.
_prune() {
  local n=0 id
  _jobs | while IFS= read -r id; do
    [ "$(_state "$JOBS/$id")" = running ] && continue
    n=$((n + 1))
    [ "$n" -gt "$KEEP" ] && rm -rf "${JOBS:?}/$id"
  done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
# _detach CMD... — run CMD in a new session with no controlling terminal, and
# print its pid. Returns only once CMD is safely detached.
#
# ⚠️  Not `nohup … &`, and not even `setsid … &`. Dispatch runs inside a popup,
# and closing the popup HUPs its whole process group. nohup only ignores SIGHUP;
# a backgrounded setsid can lose the race — the popup closed before python got as
# far as os.setsid(), and every job typed into prefix + Q died instantly while
# the same job from a shell lived. So the parent waits on a pipe whose write end
# is close-on-exec: EOF means the child has called setsid() AND exec'd.
# macOS has no setsid(1), which is why this is python3 at all.
_detach() {
  python3 -c '
import os, sys
r, w = os.pipe()                     # non-inheritable: closes on exec
pid = os.fork()
if pid == 0:
    os.close(r)
    os.setsid()
    os.execvp(sys.argv[1], sys.argv[1:])
os.close(w)
os.read(r, 1)                        # EOF once the child has exec-ed
print(pid)
' "$@" </dev/null 2>/dev/null
}

# dispatch DIR PROMPT — make the job dir, start the worker, print the id.
dispatch() {
  local cwd="$1" prompt="$2" id d
  [ -n "${prompt//[[:space:]]/}" ] || die "nothing to do — give it a task"
  [ -d "$cwd" ] || cwd="$HOME"
  id="$(date +%m%d-%H%M%S)-$$"
  d="$JOBS/$id"
  mkdir -p "$d" || die "can't create $d"
  printf '%s\n' "$prompt" > "$d/prompt"
  printf '%s\n' "$cwd" > "$d/cwd"
  date +%s > "$d/started"
  # Recorded here as well as by the worker: until the worker gets that far the
  # job would read as "lost".
  _detach "$SELF" --worker "$d" > "$d/pid" || die "can't start the job (needs python3)"
  _prune
  printf '%s\n' "$id"
}

# ---------------------------------------------------------------------------
# The worker — runs detached, once per job
# ---------------------------------------------------------------------------
# The system prompt addition is what makes the output worth reading cold: the
# person asking is not watching, can't answer a question, and will read only the
# final message.
QUICK_SYSTEM="You are running as a quick background job. The user typed one request and walked away: they cannot see your progress and cannot answer questions. Do the task fully without asking for confirmation. If something is ambiguous, pick the most reasonable reading and say which you chose. Your final message is the ONLY thing the user will read, so make it the complete answer: lead with the result, be concise, and use plain markdown."

worker() {
  local d="$1" cwd prompt cmd code rc
  echo $$ > "$d/pid"
  cwd=$(cat "$d/cwd"); prompt=$(cat "$d/prompt")
  cd "$cwd" 2>/dev/null || cd "$HOME" || exit 1

  # A job dispatched from inside a Claude Code pane inherits its env; claude
  # refuses to start nested under those.
  unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT

  # ⚠️  The worker inherits the TMUX SERVER's PATH, not your shell's. A server
  # started weeks ago from another terminal can predate ~/.local/bin being on
  # PATH, which is where Claude Code's installer puts `claude` — every job then
  # died with "claude: command not found". So add the places it installs to.
  PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin"
  export PATH

  # Not word-split into an array on purpose: TMUX_QUICK_JOB_CMD and _FLAGS are
  # user-written strings, "claude" and "--model sonnet", meant to split on spaces.
  cmd="${TMUX_QUICK_JOB_CMD:-claude}"
  if command -v "${cmd%% *}" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $cmd -p --output-format json --append-system-prompt "$QUICK_SYSTEM" \
      ${TMUX_QUICK_JOB_FLAGS:-} "$prompt" > "$d/raw.json" 2> "$d/stderr"
    code=$?
  else
    printf "can't find '%s' on the tmux server's PATH:\n  %s\nPoint at it with: tmux set-environment -g TMUX_QUICK_JOB_CMD /full/path/to/claude\n" \
      "${cmd%% *}" "$PATH" > "$d/stderr"
    : > "$d/raw.json"
    code=127
  fi

  # The JSON envelope carries the answer and the session id (for `tj resume`).
  # python3 is only here to parse it; without it the raw envelope is the output.
  if command -v python3 >/dev/null 2>&1 &&
     python3 - "$d" <<'PY' 2>/dev/null
import json, sys, os
d = sys.argv[1]
with open(os.path.join(d, "raw.json")) as f:
    env = json.load(f)
if isinstance(env, list):          # stream-style array: the result is last
    env = next(e for e in reversed(env) if e.get("type") == "result")
with open(os.path.join(d, "output.md"), "w") as f:
    f.write((env.get("result") or "").rstrip() + "\n")
if env.get("session_id"):
    with open(os.path.join(d, "session"), "w") as f:
        f.write(env["session_id"] + "\n")
if env.get("is_error"):
    sys.exit(3)
PY
  then :
  else
    rc=$?
    [ -s "$d/output.md" ] || cp "$d/raw.json" "$d/output.md" 2>/dev/null
    [ "$code" = 0 ] && [ "$rc" = 3 ] && code=1
  fi
  # A failed run's JSON is often empty; then what went wrong is on stderr.
  if [ "$code" != 0 ] && [ ! -s "$d/raw.json" ] || [ ! -s "$d/output.md" ]; then
    tail -20 "$d/stderr" > "$d/output.md" 2>/dev/null
    [ "$code" = 0 ] && code=1
  fi

  date +%s > "$d/finished"
  echo "$code" > "$d/exit"      # last: its existence is what "done" means
  _announce "$d" "$code"
}

# _announce DIR CODE — tell whoever is at the keyboard. Every attached client
# gets a tmux message; a desktop notification follows the same @agent-notify
# switch as the waiting-state hook, so one toggle governs both.
_announce() {
  local d="$1" code="$2" first prompt title msg notify c
  # The first line of prose, skipping headings: "## Answer" tells you nothing.
  first=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]>*-]*$' "$d/output.md" 2>/dev/null | head -1 | sed 's/^[>* -]*//' | cut -c1-90)
  [ -n "$first" ] || first=$(grep -m1 . "$d/output.md" 2>/dev/null | sed 's/^[#>* -]*//' | cut -c1-90)
  prompt=$(tr '\n' ' ' < "$d/prompt" | cut -c1-40)
  if [ "$code" = 0 ]; then title="✉ quick job done"; else title="✗ quick job failed"; fi
  msg="${first:-no output}"

  if tmux info >/dev/null 2>&1; then
    for c in $(tmux list-clients -F '#{client_name}' 2>/dev/null); do
      tmux display-message -c "$c" -d 8000 "$title: $prompt — $msg   (prefix + Q to read)" 2>/dev/null
    done
    tmux refresh-client -S 2>/dev/null
  fi

  notify="${TMUX_AGENT_NOTIFY:-}"
  [ -n "$notify" ] || notify=$(tmux show-option -gqv @agent-notify 2>/dev/null)
  [ "${notify:-0}" = 1 ] && "$BIN/tmux-agent-notify.sh" "$title" "$prompt — $msg"
}

# ---------------------------------------------------------------------------
# Reading results
# ---------------------------------------------------------------------------
# _pager FILE — markdown if something can render it, less otherwise.
_pager() {
  if command -v glow >/dev/null 2>&1; then glow -p "$1"
  elif command -v bat >/dev/null 2>&1; then bat --paging=always --style=plain -l md "$1"
  # -c paints from the top. Without it less scrolls a short answer up from the
  # bottom of the popup, leaving it under a screenful of blank space.
  else less -R -c -Ps'q — back to the list' -Pm'q — back to the list' "$1"; fi
}

# _view ID — the whole of one job, prompt first, then marks it read.
_view() {
  local d="$JOBS/$1" st tmp sid
  st=$(_state "$d")
  tmp=$(mktemp) || return
  {
    printf '> %s\n\n' "$(tr '\n' ' ' < "$d/prompt")"
    printf '_in %s · %s_\n\n---\n\n' "$(cat "$d/cwd")" "$st"
    case "$st" in
      running) printf 'Still running. prefix + Q again when the notification lands.\n' ;;
      lost)    printf 'The job stopped without finishing (a reboot, or it was killed).\n' ;;
      *)       cat "$d/output.md" 2>/dev/null ;;
    esac
    sid=$(cat "$d/session" 2>/dev/null)
    [ -n "$sid" ] && printf '\n---\n\n_Follow up: tj resume %s_\n' "$1"
  } > "$tmp"
  _pager "$tmp"
  rm -f "$tmp"
  [ "$st" = running ] || : > "$d/seen"
}

# ---------------------------------------------------------------------------
# prefix + Q — the popup
# ---------------------------------------------------------------------------
# One key does both jobs. Typing is a new task; the list below is every recent
# job, and it is NOT filtered by what you type (--disabled) — so enter on an
# empty prompt reads the highlighted job, and enter with text dispatches it.
popup_inside() {
  local cwd="$1" out key query sel id
  while :; do
    out=$(
      _jobs | while IFS= read -r id; do _row "$id"; done |
      fzf --disabled --print-query --expect=enter,ctrl-x,ctrl-y \
          --delimiter=$'\t' --with-nth=2 \
          --prompt='quick job> ' --reverse --height=100% --no-sort \
          --header="enter  run it in ${cwd/#$HOME/~}  ·  empty enter reads the highlighted job
ctrl-y copy its output  ·  ctrl-x forget it  ·  esc close
⚡ running  ✉ unread  ✓ read  ✗ failed" \
          --color "$(ui_fzf_colors 2>/dev/null)"
    ) || [ -n "$out" ] || return 0
    query=$(printf '%s\n' "$out" | sed -n 1p)
    key=$(printf '%s\n' "$out" | sed -n 2p)
    sel=$(printf '%s\n' "$out" | sed -n 3p | cut -f1)
    case "$key" in
      enter)
        if [ -n "${query//[[:space:]]/}" ]; then
          id=$(dispatch "$cwd" "$query") &&
            tmux display-message -d 4000 "⚡ quick job started — you'll be told when it's done" 2>/dev/null
          return 0
        fi
        [ -n "$sel" ] && _view "$sel"
        ;;
      ctrl-y)
        [ -n "$sel" ] && [ -f "$JOBS/$sel/output.md" ] && {
          if command -v pbcopy >/dev/null 2>&1; then pbcopy < "$JOBS/$sel/output.md"
          else tmux load-buffer -w "$JOBS/$sel/output.md"; fi
          : > "$JOBS/$sel/seen"
        } ;;
      ctrl-x) [ -n "$sel" ] && [ "$(_state "$JOBS/$sel")" != running ] && rm -rf "${JOBS:?}/$sel" ;;
      *) return 0 ;;
    esac
  done
}

popup() {
  local client="${1:-}" pane="${2:-}" cwd
  cwd=$(tmux display-message -p -t "${pane:-}" '#{pane_current_path}' 2>/dev/null)
  [ -n "$cwd" ] || cwd="$HOME"
  if ! command -v fzf >/dev/null 2>&1; then
    # No fzf: tmux's own prompt still dispatches; reading happens with `tj show`.
    tmux command-prompt ${client:+-t "$client"} -p "quick job>" \
      "run-shell -b \"$(_shq "$SELF") --dispatch-quiet $(_shq "$cwd") '%%'\""
    return
  fi
  # shellcheck disable=SC2046
  tmux display-popup ${client:+-c "$client"} -e "TMUX_AGENT_IN_POPUP=1" \
    $(ui_popup_style create 2>/dev/null) -T " quick job " \
    -E -w 80% -h 60% -d "$cwd" "$(_shq "$SELF") --inside $(_shq "$cwd")"
}

# ---------------------------------------------------------------------------
# Status line: ⚡running ✉unread — nothing at all when there is neither
# ---------------------------------------------------------------------------
status() {
  local run=0 unread=0 id st
  [ -d "$JOBS" ] || return 0
  for d in "$JOBS"/*/; do
    [ -f "$d/prompt" ] || continue
    if [ ! -f "$d/exit" ]; then
      st=$(_state "${d%/}"); [ "$st" = running ] && run=$((run + 1))
    elif [ ! -f "$d/seen" ]; then
      unread=$((unread + 1))
    fi
  done
  [ "$run" -gt 0 ] && printf ' #[fg=colour214]⚡%d' "$run"
  [ "$unread" -gt 0 ] && printf ' #[fg=colour39,bold]✉%d#[none]' "$unread"
  return 0
}

# ---------------------------------------------------------------------------
# tj — the shell front end
# ---------------------------------------------------------------------------
cli() {
  local id d
  case "${1:-}" in
    "")
      [ -n "$(_jobs)" ] || { echo "no quick jobs yet — tj \"what's using port 3000?\""; return 0; }
      _jobs | head -20 | while IFS= read -r id; do _row "$id"; done | cut -f2- ;;
    -h|--help|help) sed -n '2,32p' "$SELF" | sed 's/^# \{0,1\}//' ;;
    ls) _jobs | while IFS= read -r id; do _row "$id"; done ;;
    show|cat)
      id=$(_resolve "${2:-}") || return 1; [ -n "$id" ] || die "no jobs"
      d="$JOBS/$id"
      if [ "$(_state "$d")" = running ]; then echo "tj: $id is still running" >&2; return 2; fi
      cat "$d/output.md"; : > "$d/seen" ;;
    view)
      id=$(_resolve "${2:-}") || return 1; [ -n "$id" ] || die "no jobs"; _view "$id" ;;
    log)
      id=$(_resolve "${2:-}") || return 1; cat "$JOBS/$id/stderr" 2>/dev/null ;;
    wait)
      id=$(_resolve "${2:-}") || return 1
      while [ "$(_state "$JOBS/$id")" = running ]; do sleep 1; done
      cat "$JOBS/$id/output.md"; : > "$JOBS/$id/seen" ;;
    resume)
      # The job's conversation, as an interactive agent in its own folder.
      id=$(_resolve "${2:-}") || return 1; d="$JOBS/$id"
      [ -s "$d/session" ] || die "$id has no session to resume"
      (cd "$(cat "$d/cwd")" && exec ${TMUX_QUICK_JOB_CMD:-claude} -r "$(cat "$d/session")") ;;
    rm)
      [ -n "${2:-}" ] || die "rm what? a job id, or --all"
      if [ "$2" = --all ]; then
        _jobs | while IFS= read -r id; do
          [ "$(_state "$JOBS/$id")" = running ] || rm -rf "${JOBS:?}/$id"
        done
      else id=$(_resolve "$2") || return 1; rm -rf "${JOBS:?}/$id"; fi ;;
    *)
      # Anything else is the task. Quoting is optional: tj find the biggest file here
      id=$(dispatch "$PWD" "$*") || return 1
      echo "⚡ $id — tj wait $id, or you'll be notified" ;;
  esac
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  --worker)         worker "$2" ;;
  --inside)         popup_inside "$2" ;;
  --popup)          popup "${2:-}" "${3:-}" ;;
  --status)         status ;;
  --dispatch)       dispatch "$2" "$3" ;;
  --dispatch-quiet) dispatch "$2" "$3" >/dev/null &&
                      tmux display-message -d 4000 "⚡ quick job started — you'll be told when it's done" ;;
  *)                cli "$@" ;;
esac
