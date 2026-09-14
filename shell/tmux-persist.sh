# tmux-persist — shell front end for surviving a macOS restart.
#
# A tmux server is a process. A reboot kills it, and every session with it —
# there is no flag that changes that. What CAN be kept is the shape of the
# server, written to disk while it is running and replayed afterwards. The
# agents' actual work was never in tmux to begin with: Claude Code stores each
# conversation in ~/.claude/projects keyed by working directory, so an agent
# restored into the same folder resumes with `claude --continue`.
#
#   tsave              snapshot the running server now
#   trestore           rebuild every session in the newest snapshot that is
#                      not already running (agents come back at a shell)
#   trestore --resume  ...and start every agent immediately
#   trestore -n        dry run
#   trestore NAME...   only these sessions
#   tsnaps             list the snapshots on disk
#   tsnaps -l          what the newest snapshot holds, agent tasks and all
#
# A launchd job (com.tmux-agents.persist) already runs tsave every 5 minutes
# and trestore once at login, so in normal use you never type any of this. It is
# here for the cases the job cannot cover: snapshotting before you deliberately
# tear something down, restoring one session you killed by mistake, and looking
# at what was running before the machine went away.


# Where this repo lives (set already if agents.sh was sourced first).
: "${_TA_SHELL:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${_TA_BIN:=${TMUX_AGENTS_HOME:-$(cd "$_TA_SHELL/.." && pwd)}/bin}"

TMUX_AGENTS_STATE="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"

tsave()    { "$_TA_BIN/tmux-agent-save.sh" "$@"; }
trestore() { "$_TA_BIN/tmux-agent-restore.sh" "$@"; }
# tpower — the low-battery guard: battery, threshold, and who is awake.
# `tpower -n` shows what a tick would sleep right now.
tpower()   {
  case "${1:-}" in
    -h|--help) echo "tpower            battery, threshold, awake agents"; echo "tpower -n         what the guard would sleep right now"; return 0 ;;
    -n|--dry-run) "$_TA_BIN/tmux-agent-power.sh" -n ;;
    *) "$_TA_BIN/tmux-agent-power.sh" status ;;
  esac
}

# tsnaps — what is on disk. Without -l, one line per snapshot. With -l, the
# contents of the newest: every session, and for each agent the task its status
# line was showing when the snapshot was taken. That last part is the reason to
# look: after a reboot it is the only record of what 30 agents were mid-way
# through, and it reads as a to-do list.
tsnaps() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local dir="$TMUX_AGENTS_STATE/snapshots" f
  if [ "${1:-}" = "-l" ]; then
    f=$(ls -1t "$dir"/*.tsv 2>/dev/null | head -1)
    [ -n "$f" ] || { echo "no snapshots in $dir" >&2; return 1; }
    sed -n '2,4p' "$f" | sed 's/^# //'
    echo
    awk -F'\t' '
      /^P/ {
        n[$2]++
        if ($12 == 1) { a[$2]++; if (task[$2] == "") task[$2] = $13; else task[$2] = task[$2] "; " $13 }
      }
      END { for (s in n) printf "%-44s %d panes  %d agents  %s\n", s, n[s], a[s]+0, task[s] }
    ' "$f" | sort
    return 0
  fi
  ls -1t "$dir"/*.tsv 2>/dev/null | while read -r f; do
    printf '%s  %s sessions  %s panes\n' \
      "$(basename "$f" .tsv)" \
      "$(awk -F'\t' '/^P/{print $2}' "$f" | sort -u | wc -l | tr -d ' ')" \
      "$(grep -c '^P' "$f")"
  done
}

# ---------------------------------------------------------------------------
# Sleeping agents
# ---------------------------------------------------------------------------
# A reboot forces the question, but it is worth asking without one: 30 agents
# hold ~15GB of RSS between them, and most are waiting on an answer nobody is
# about to give. Sleeping one exits the process and keeps the conversation —
# same trade the reboot restore makes, taken deliberately.
#
#   tsleep                 sleep every agent idle more than 24h
#   tsleep --idle 4        ...more than 4h
#   tsleep NAME|%pane ...  sleep these, whatever their idle time
#   tsleep -n              dry run: what would go, and how much memory it frees
#   twake  NAME|%pane ...  wake them again, each on its own exact conversation
#
# Sleep is only safe because the session id is exact. `claude --continue` would
# resume the most recent conversation in the directory, so sleeping the four
# agents in ~/Projects/monorepo and waking them would land all four on the
# same conversation and lose the other three.

# _t_sleep_candidates [IDLE_HOURS] [TARGET...] — agent panes worth sleeping, as
# "pane<TAB>idle_seconds<TAB>rss_kb<TAB>session:window<TAB>task".
_t_sleep_candidates() {
  local idle_h="$1"; shift
  local now pane ppid sess win act title cwd pid rss idle want
  now=$(date +%s)
  while IFS=$'\t' read -r pane ppid sess win act cwd title; do
    pid=$(_t_agent_pid "$ppid") || true
    [ -n "$pid" ] || continue          # nothing running here to put to sleep
    if [ $# -gt 0 ]; then
      want=0
      for t in "$@"; do
        case "$t" in
          %*) [ "$t" = "$pane" ] && want=1 ;;
          *)  [ "$t" = "$sess" ] && want=1 ;;
        esac
      done
      [ "$want" = 1 ] || continue
    else
      case "$act" in ''|*[!0-9]*) idle=0 ;; *) idle=$(( (now - act) / 3600 )) ;; esac
      [ "$idle" -ge "$idle_h" ] || continue
    fi
    case "$act" in ''|*[!0-9]*) idle=0 ;; *) idle=$(( now - act )) ;; esac
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\n' "$pane" "$idle" "${rss:-0}" "$sess:$win" "${title#* }"
    # LC_ALL is set on the command itself, not the shell: tmux replaces a TAB in
    # a format string with "_" unless the locale is UTF-8, which would collapse
    # every row here into a single unusable field.
  done < <(LC_ALL=en_US.UTF-8 tmux list-panes -a -F $'#{pane_id}\t#{pane_pid}\t#{session_name}\t#{window_name}\t#{window_activity}\t#{pane_current_path}\t#{pane_title}' 2>/dev/null)
}

tsleep() {
  local dry=0 idle_h=24
  local -a targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--dry-run) dry=1; shift ;;
      --idle) idle_h="${2:?--idle needs hours}"; shift 2 ;;
      -h|--help) echo "tsleep [-n] [--idle HOURS] [SESSION|%PANE ...]"; return 0 ;;
      *) targets+=("$1"); shift ;;
    esac
  done

  local pane idle rss where task sid pid ppid hint freed=0 n=0
  while IFS=$'\t' read -r pane idle rss where task; do
    [ -n "$pane" ] || continue
    n=$((n + 1)); freed=$((freed + rss))
    if [ "$dry" = 1 ]; then
      printf '  %-34s %4dh idle  %5d MB  %s\n' "$where" "$((idle / 3600))" "$((rss / 1024))" "$task"
      continue
    fi

    # Stamp before killing: once the process is gone the pane title loses its
    # glyph and nothing else records that this pane was ever an agent.
    sid=$(_t_agent_sid "$pane" 2>/dev/null)
    [ -n "$sid" ] && tmux set-option -p -t "$pane" @agent-session-id "$sid" 2>/dev/null
    [ -n "$task" ] && tmux set-option -p -t "$pane" @agent-task "$task" 2>/dev/null

    ppid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
    pid=$(_t_agent_pid "$ppid") || true
    if [ -n "$pid" ]; then
      # SIGTERM, not send-keys: a keystroke lands in whatever UI state the agent
      # is in. Claude writes its transcript continuously, so nothing is lost.
      kill -TERM "$pid" 2>/dev/null
      local waited=0
      while kill -0 "$pid" 2>/dev/null; do
        [ "$waited" -ge 40 ] && kill -KILL "$pid" 2>/dev/null
        [ "$waited" -ge 55 ] && break
        sleep 0.2; waited=$((waited + 1))
      done
    fi
    # The task is a sentence, so it has to be quoted for the shell the keystrokes
    # land in — unquoted, printf takes each word as a separate argument and the
    # hint shows only the first one.
    hint=$(printf '%q' "${task:-agent}")
    tmux send-keys -t "$pane" \
      "printf '\\033[2m-- sleeping: %s\\n   Ctrl+b R to wake --\\033[0m\\n' $hint" Enter 2>/dev/null
    printf '  slept %-34s %5d MB  %s\n' "$where" "$((rss / 1024))" "$task"
    # ⚠️  ${targets[@]} on an EMPTY array is an "unbound variable" error under
    # set -u in bash 3.2, which is the /bin/bash macOS ships. Interactive shells
    # do not set -u so this only fails from a script — where the symptom is
    # "nothing to sleep", not an obvious crash.
  done < <(_t_sleep_candidates "$idle_h" ${targets[@]+"${targets[@]}"})

  if [ "$n" = 0 ]; then
    echo "nothing to sleep (no agent idle more than ${idle_h}h)"
  elif [ "$dry" = 1 ]; then
    printf '%d agents, %d MB — run without -n to sleep them\n' "$n" "$((freed / 1024))"
  else
    printf '%d agents asleep, ~%d MB freed. twake or Ctrl+b R brings any of them back.\n' "$n" "$((freed / 1024))"
  fi
}

# twake SESSION|%PANE ... — wake sleeping agents, each on its own conversation.
twake() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local pane sess win sid cmd n=0
  [ $# -gt 0 ] || { echo "twake SESSION|%PANE ..." >&2; return 2; }
  while IFS=$'\t' read -r pane sess win sid; do
    [ -n "$sid" ] || continue
    for t in "$@"; do
      case "$t" in
        %*) [ "$t" = "$pane" ] || continue ;;
        *)  [ "$t" = "$sess" ] || continue ;;
      esac
      cmd=$(_t_agent_resume_cmd "$pane")
      _t_agent_touch "$pane"
      tmux send-keys -t "$pane" "$cmd" Enter
      printf '  woke %s:%s  %s\n' "$sess" "$win" "$cmd"
      n=$((n + 1))
      break
    done
  done < <(LC_ALL=en_US.UTF-8 tmux list-panes -a -F $'#{pane_id}\t#{session_name}\t#{window_name}\t#{@agent-session-id}' 2>/dev/null)
  [ "$n" = 0 ] && echo "no sleeping agents matched" >&2
  return 0
}

# ---------------------------------------------------------------------------
# The archive — what a shut-down session leaves behind
# ---------------------------------------------------------------------------
#   tarchive                 list every session that has been aged out
#   tarchive restore NAME    bring one back, on its exact conversation
#
# tmux-agent-lifecycle.sh shuts a session down after 7 days of no conversation,
# and writes a row here first. That row is the whole reason shutting down is safe
# to automate: the working folder is never touched, so restoring is just
# recreating the session on it and resuming the recorded session id.
#
# Append-only and never rotated, unlike the snapshots. A snapshot describes a
# server that exists; this describes ones that don't, and there is no later
# snapshot that could bring them back.
# _t_lost_agents — "session<TAB>window<TAB>cwd<TAB>sid<TAB>task" for every agent
# the newest snapshot recorded that has no live pane carrying that session id now.
_t_lost_agents() {
  local snap="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}/last.tsv"
  [ -r "$snap" ] || return 0
  local live
  live=$'\n'$(tmux list-panes -a -F '#{@agent-session-id}' 2>/dev/null | grep -v '^$')$'\n'
  awk -F'\t' -v OFS='\t' '$1=="P" && $15==1 && $17!="-" { print $2, $4, $9, $17, $16 }' "$snap" \
  | while IFS=$'\t' read -r sess win cwd sid task; do
      case "$live" in *$'\n'"$sid"$'\n'*) continue ;; esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$sess" "$win" "$cwd" "$sid" "$task"
    done
}

tarchive() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local file="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}/archive.tsv"
  local when sess win cwd sid task idle name found=0 win1 target shown=

  if [ "${1:-}" != "restore" ]; then
    if [ -s "$file" ]; then
      printf '%-20s %-34s %-8s %s\n' "SHUT DOWN" "SESSION" "IDLE" "TASK"
      while IFS=$'\t' read -r when sess win cwd sid task idle; do
        [ -n "$sess" ] || continue
        printf '%-20s %-34s %-8s %s\n' "$when" "$sess" "$idle" "$task"
      done < "$file"
    else
      echo "nothing aged out yet"
    fi

    # Agents the last snapshot knew about that are not running now. The archive
    # only covers what the lifecycle shut down; this covers everything else —
    # above all a window closed by hand. Typing `exit` at a sleeping agent's
    # shell closes its pane, and the pane carries @agent-session-id, so the way
    # back goes with it. The snapshot is the backstop, and it is five minutes old
    # at worst.
    _t_lost_agents | while IFS=$'\t' read -r sess win cwd sid task; do
      [ -n "$sess" ] || continue
      [ "$shown" ] || { printf '\n%-34s %s\n' "NOT RUNNING (window closed?)" "TASK"; shown=1; }
      printf '%-34s %s\n' "$sess${win:+:$win}" "$task"
    done
    echo
    echo "tarchive restore NAME — bring one back on its exact conversation"
    return 0
  fi

  name="${2:-}"
  [ -n "$name" ] || { echo "tarchive restore NAME" >&2; return 2; }
  # An agent lost with its window has no archive row — the lifecycle never shut
  # it down. Fall back to the newest snapshot so one command covers both ways an
  # agent goes missing.
  if ! grep -q "	$name	" "$file" 2>/dev/null; then
    local lrow
    lrow=$(_t_lost_agents | awk -F'\t' -v n="$name" '$1 == n { print; exit }')
    if [ -n "$lrow" ]; then
      IFS=$'\t' read -r sess win cwd sid task <<< "$lrow"
      [ -d "$cwd" ] || { echo "tarchive: $cwd is gone — cannot restore '$name'" >&2; return 1; }
      win1="${win:-claude}"
      if ! tmux has-session -t "=$name" 2>/dev/null; then
        tmux new-session -d -s "$name" -c "$cwd" -n "$win1" || return 1
        tmux new-window -d -t "=$name" -n shell -c "$cwd"
      else
        win1=$(_t_uniq_window "$name" "$win1")
        tmux new-window -d -t "=$name" -n "$win1" -c "$cwd"
      fi
      tmux set-option -p -t "=$name:$win1" @agent-session-id "$sid" 2>/dev/null
      [ -n "$task" ] && [ "$task" != "-" ] && \
        tmux set-option -p -t "=$name:$win1" @agent-task "$task" 2>/dev/null
      _t_agent_touch "=$name:$win1"
      tmux send-keys -t "=$name:$win1" "${T_AUTOSTART:-claude} -r $sid" Enter
      echo "recovered '$name' from the last snapshot — resuming its conversation"
      return 0
    fi
  fi

  # ⚠️  The "already running" guard belongs HERE, not at the top. The lost-agent
  # case above is precisely "the session still exists, its agent window does
  # not" — checking first refused to recover the very thing this is for.
  if tmux has-session -t "=$name" 2>/dev/null; then
    echo "tarchive: '$name' is already running" >&2; return 1
  fi

  # Last row wins: a session can be archived, restored, and aged out again.
  while IFS=$'\t' read -r when sess win cwd sid task idle; do
    [ "$sess" = "$name" ] || continue
    found=1
    [ -d "$cwd" ] || { echo "tarchive: $cwd is gone — cannot restore '$name'" >&2; return 1; }
    win1="${win:-claude}"; [ "$win1" = "-" ] && win1=claude
    # ⚠️  The pane runs a plain SHELL, and the agent is started by send-keys into
    # it. Never `new-window "claude -r <id>"`. Two reasons, both learned the hard
    # way when a restored session vanished:
    #
    #   1. If claude is the pane's command, the pane dies when claude exits — and
    #      sleeping an agent exits claude. So the lifecycle pass slept a restored
    #      session and took its only pane, its window, and the session with it.
    #   2. `sh -c 'claude …'` has no job control, so claude shares the wrapper's
    #      process group and tmux reports pane_current_command as the shell. That
    #      is the exact signal used to tell awake from asleep, so a running agent
    #      would read as sleeping. Sent through an INTERACTIVE shell, claude gets
    #      its own foreground group and reports correctly.
    if ! tmux has-session -t "=$name" 2>/dev/null; then
      tmux new-session -d -s "$name" -c "$cwd" -n "$win1" || return 1
      tmux new-window -d -t "=$name" -n shell -c "$cwd"
      target="=$name:$win1"
    else
      # A second agent that shared the session: same folder, its own window.
      win1=$(_t_uniq_window "$name" "$win1")
      tmux new-window -d -t "=$name" -n "$win1" -c "$cwd"
      target="=$name:$win1"
    fi
    tmux set-option -p -t "$target" @agent-session-id "$sid" 2>/dev/null
    [ -n "$task" ] && [ "$task" != "-" ] && \
      tmux set-option -p -t "$target" @agent-task "$task" 2>/dev/null
    _t_agent_touch "$target"
    tmux send-keys -t "$target" "${T_AUTOSTART:-claude} -r $sid" Enter
  done < "$file"

  [ "$found" = 1 ] || { echo "tarchive: nothing archived under '$name'" >&2; return 1; }
  echo "restored '$name' — resuming its conversation"
}
