#!/usr/bin/env bash
# tmux-agent-restore — rebuild the sessions a snapshot describes.
#
#   tmux-agent-restore.sh [-n] [-f FILE] [-L SOCKET] [--resume] [SESSION ...]
#
#     -n         dry run — print what would be created, create nothing
#     -f FILE    a specific snapshot (default: the newest)
#     --resume   start each agent immediately instead of leaving a shell
#     SESSION    restore only these sessions (default: all missing ones)
#
# WHAT IT RESTORES: sessions, windows, window names, pane splits, pane layouts,
# working directories, and which window/pane was active. Panes come up at a
# plain shell.
#
# WHAT IT DOES NOT RESTORE, on purpose: the agents themselves. This machine runs
# ~30 of them and they hold ~15GB of RSS between them; relaunching all 30 at
# login would spend several minutes and most of the machine's memory rebuilding
# state for the 27 you weren't going to touch today. So the skeleton comes back
# instantly and each agent is one keystroke away — Ctrl+b R in its pane resumes
# that conversation in place, which is the same path a stale-TCC restart takes
# and is already built for a pane sitting at a dead shell.
#
# Nothing is lost by waiting: the conversation lives in ~/.claude/projects keyed
# by directory, not in the tmux pane. --resume is there when you want them all
# back up anyway.
#
# Idempotent: a session that already exists is skipped, never merged into.
set -u

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

STATE_DIR="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
FILE="$STATE_DIR/last.tsv"
SOCKET="default"
DRY=0
RESUME=0
declare -a ONLY=()

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    -f) FILE="${2:?-f needs a file}"; shift 2 ;;
    -L) SOCKET="${2:?-L needs a socket}"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "restore: unknown option $1" >&2; exit 2 ;;
    *) ONLY+=("$1"); shift ;;
  esac
done

[ -r "$FILE" ] || { echo "restore: no snapshot at $FILE" >&2; exit 1; }

# Tell the change-triggered autosave (tmux-agent-autosave.sh, fired by hooks
# for every session this creates) to stand down until we are done: a snapshot
# of a half-built server must never become "the newest". The marker carries our
# pid so a restore killed midway cannot silence autosave for good.
RESTORING="$STATE_DIR/.restoring"
if [ "$DRY" -eq 0 ]; then
  mkdir -p "$STATE_DIR"; echo $$ > "$RESTORING"
  trap 'rm -f "$RESTORING"' EXIT
fi

TAB=$'\t'

# Same check the save side makes, on the way back in: a snapshot written before
# the locale fix (or by a hand-edit) has one field per row, and replaying it
# would create a pile of sessions with mangled names rather than fail.
badfields=$(grep -m1 '^P' "$FILE" | awk -F"$TAB" '{print NF}')
if [ "${badfields:-0}" -lt 17 ]; then
  echo "restore: $FILE is corrupt or pre-dates session-id capture ($badfields fields, expected 17) — try an older one from tsnaps" >&2
  exit 1
fi

TMUX_BIN=(tmux -L "$SOCKET")

# What a restored agent pane runs.
#
# ⚠️  Prefer `claude -r <session-id>` over `--continue`, and the difference is not
# cosmetic. --continue resumes the most recent conversation IN A DIRECTORY, and
# four agents share ~/Projects/monorepo — so --continue would put all four
# back on whichever of them spoke last, silently, and the other three
# conversations would just look gone. The snapshot carries each pane exact id.
# --continue stays the fallback for an agent that never got one.
#
# T_RESUME still wins outright, for a T_AUTOSTART tool that spells resume its
# own way.
resume_for() {
  local sid="$1"
  if [ -n "${T_RESUME:-}" ]; then printf '%s\n' "$T_RESUME"
  elif [ -n "$sid" ]; then printf '%s -r %s\n' "${T_AUTOSTART:-claude}" "$sid"
  else printf '%s --continue\n' "${T_AUTOSTART:-claude}"
  fi
}

want() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  local s
  for s in "${ONLY[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

existing=$("${TMUX_BIN[@]}" list-sessions -F '#{session_name}' 2>/dev/null || true)
session_exists() { printf '%s\n' "$existing" | grep -qxF "$1"; }

# A cwd that has since been deleted must not sink the whole session — fall back
# to $HOME and carry on, rather than failing new-session and losing the rest.
safe_dir() { [ -d "$1" ] && printf '%s\n' "$1" || printf '%s\n' "$HOME"; }

run() { [ "$DRY" -eq 1 ] && { printf '    tmux %s\n' "$*"; return 0; }; "${TMUX_BIN[@]}" "$@"; }

# Create a pane and return its id. Panes have to be created in the snapshot's
# index order or select-layout puts them in the wrong cells (see the split below),
# and tracking the id is how each split knows what to split.
#
# WARNING: -P -F must come BEFORE the pane shell command, not after. tmux takes
# everything following the command word as arguments to it, so appending the
# flags made them part of the command and new-session silently created nothing —
# visible only as "can't find session" from the next call. It went unnoticed
# while agent panes had no command to pass.
run_pane() {
  local -a args=("$@")
  if [ -n "${pane_cmd:-}" ]; then args+=(-P -F '#{pane_id}' "$pane_cmd")
  else args+=(-P -F '#{pane_id}'); fi
  if [ "$DRY" -eq 1 ]; then printf '    tmux %s\n' "${args[*]}"; echo "%dry"; return 0; fi
  "${TMUX_BIN[@]}" "${args[@]}"
}

made=0; skipped=0; agents=0; exact=0
declare -a eager=()
# ⚠️  "am I building this session" is its own flag, NOT cur_session="". Blanking
# cur_session to mean "skip" makes the next pane of the same session look like a
# new session, so a skipped 2-pane session gets counted twice and a wanted one
# gets rebuilt from scratch on its second pane.
cur_session=""; building=0; cur_window=""; active_win=""; active_pane=""; last_pane=""

# Layouts and the active window/pane can only be applied once every pane of the
# window exists, so both are deferred to the end of a session's rows.
declare -a PENDING_LAYOUT=()

flush_session() {
  [ -n "$cur_session" ] && [ "$building" -eq 1 ] || return 0
  local entry win lay
  for entry in "${PENDING_LAYOUT[@]}"; do
    win="${entry%%$TAB*}"; lay="${entry#*$TAB}"
    run select-layout -t "=$cur_session:$win" "$lay" 2>/dev/null || true
  done
  PENDING_LAYOUT=()
  [ -n "$active_win" ] && run select-window -t "=$cur_session:$active_win" 2>/dev/null || true
  [ -n "$active_pane" ] && run select-pane -t "=$cur_session:$active_win.$active_pane" 2>/dev/null || true
  active_win=""; active_pane=""
}

while IFS="$TAB" read -r tag session widx wname wactive wlayout pidx pactive cwd cmd title paneid optsid opttask isagent task sid; do
  [ "${tag:-}" = "P" ] || continue
  # "-" is the save side placeholder for an empty field; see the IFS note there.
  [ "$title" = "-" ] && title=""
  [ "$task" = "-" ] && task=""
  [ "$sid" = "-" ] && sid=""
  [ "$optsid" = "-" ] && optsid=""

  if [ "$session" != "$cur_session" ]; then
    flush_session
    cur_session="$session"; cur_window=""
    if ! want "$session"; then building=0; continue; fi
    if session_exists "$session"; then
      skipped=$((skipped + 1)); building=0; continue
    fi
    building=1; made=$((made + 1))
    [ "$DRY" -eq 1 ] && echo "  + $session"
  fi
  [ "$building" -eq 1 ] || continue

  dir=$(safe_dir "$cwd")

# ⚠️  A restored pane MUST be stamped with its session id, or the next snapshot
# loses it. The id is normally recovered from the status hook transcript marker,
# but a restored pane is a brand-new pane with a brand-new id and no marker, and
# the hook does not fire again until you actually wake the agent. Without the
# stamp the chain breaks at exactly one reboot deep: restore once and it works,
# reboot again before waking and the id is gone.
stamp_pane() {
  [ "$DRY" -eq 1 ] && return 0
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  "${TMUX_BIN[@]}" set-option -p -t "$1" @agent-session-id "$2" 2>/dev/null || true
  [ -n "${3:-}" ] && "${TMUX_BIN[@]}" set-option -p -t "$1" @agent-task "$3" 2>/dev/null || true
}

  # The command a pane comes up running. An agent pane prints a one-line hint and
  # then execs the interactive shell, so the pane is a normal shell you can type
  # in AND tells you what it was and how to bring it back. Printing it this way
  # rather than send-keys leaves the prompt clean and works under any shell.
  if [ "${isagent:-0}" = "1" ]; then
    agents=$((agents + 1))
    [ -n "$sid" ] && exact=$((exact + 1))
    this_resume=$(resume_for "$sid")
    if [ "$RESUME" -eq 1 ]; then
      # Started by send-keys after the pane exists, never as the pane's command:
      # a pane whose command IS claude dies when claude exits, and sleeping an
      # agent exits claude. See the note in tarchive restore.
      pane_cmd=""
      eager+=("$last_pane")
    else
      pane_cmd=$(printf 'printf "\\033[2m-- sleeping agent: %%s\\n   Ctrl+b R (or: %%s) to wake --\\033[0m\\n" %s %s; exec "${SHELL:-/bin/bash}"' \
        "$(printf '%q' "${task:-agent}")" "$(printf '%q' "$this_resume")")
    fi
  else
    pane_cmd=""
  fi

  stamped=0
  if [ "$widx" != "$cur_window" ]; then
    # First window of the session comes from new-session; the rest from
    # new-window at their saved index, so a session that had windows 1,2,5 gets
    # 1,2,5 back and Ctrl+b 5 still means the same thing.
    if [ -z "$cur_window" ]; then
      last_pane=$(run_pane new-session -d -s "$session" -n "$wname" -c "$dir") \
        || { building=0; continue; }
      # new-session lands on base-index, which is not necessarily the saved index.
      base=$("${TMUX_BIN[@]}" show-options -gv base-index 2>/dev/null || echo 0)
      [ "$DRY" -eq 0 ] && [ "$widx" != "$base" ] && \
        "${TMUX_BIN[@]}" move-window -s "=$session:$base" -t "=$session:$widx" 2>/dev/null || true
    else
      last_pane=$(run_pane new-window -d -t "=$session:$widx" -n "$wname" -c "$dir") || true
    fi
    cur_window="$widx"
    [ "${isagent:-0}" = "1" ] && stamp_pane "$last_pane" "$sid" "$task"
    stamped=1
    [ -n "$wlayout" ] && PENDING_LAYOUT+=("$widx$TAB$wlayout")
    [ "$wactive" = "1" ] && active_win="$widx"
    [ "$pactive" = "1" ] && active_pane="$pidx"
  else
    # A second-or-later pane in the same window: a split. Geometry is wrong until
    # select-layout runs at the end of the session, which is why layout is saved.
    #
    # ⚠️  Split the LAST pane created, by id — not the window, and not with -d.
    # select-layout hands panes to the layout string's cells in pane-INDEX order,
    # so the restored indexes have to come out in the snapshot's order. Splitting
    # the window (whose active pane stays pane 1 under -d) inserts each new pane
    # directly after pane 1 and renumbers the rest, which reverses everything
    # after the first split: a 3-pane window came back with its geometry exactly
    # right and panes 2 and 3 swapped — right shape, wrong agent in each half.
    last_pane=$(run_pane split-window -d -t "$last_pane" -c "$dir") || true
    [ "$pactive" = "1" ] && active_pane="$pidx"
  fi
  [ "$stamped" -eq 0 ] && [ "${isagent:-0}" = "1" ] && stamp_pane "$last_pane" "$sid" "$task"
done < "$FILE"

flush_session

# --resume: now that every pane exists and the layout is applied, start the
# agents by typing into their shells.
if [ "$RESUME" -eq 1 ] && [ "$DRY" -eq 0 ]; then
  for ep in ${eager[@]+"${eager[@]}"}; do
    [ -n "$ep" ] || continue
    esid=$("${TMUX_BIN[@]}" show-options -pqv -t "$ep" @agent-session-id 2>/dev/null)
    "${TMUX_BIN[@]}" set-option -p -t "$ep" @agent-woken "$(date +%s)" 2>/dev/null || true
    "${TMUX_BIN[@]}" send-keys -t "$ep" "$(resume_for "$esid")" Enter 2>/dev/null || true
  done
fi

if [ "$DRY" -eq 1 ]; then
  echo "dry run: would create $made sessions ($agents agent panes, $exact with an exact session id), skip $skipped already running"
else
  echo "restored $made sessions ($agents agent panes, $exact with an exact session id), skipped $skipped already running"
  [ "$RESUME" -eq 0 ] && [ "$agents" -gt 0 ] && \
    echo "agents are asleep at a shell — Ctrl+b R in a pane wakes that exact conversation"
fi
