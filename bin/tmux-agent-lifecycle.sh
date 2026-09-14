#!/usr/bin/env bash
# tmux-agent-lifecycle — age agents out on their own.
#
#   inactive > 48h   -> sleep it   (process exits, conversation kept)
#   inactive > 7d    -> shut down  (session killed, conversation ARCHIVED first)
#
#   tmux-agent-lifecycle.sh [-n] [--sleep-hours H] [--shutdown-hours H]
#
# Run hourly from tmux-agent-persist.sh. Thresholds override from the environment
# (TMUX_AGENT_SLEEP_HOURS / TMUX_AGENT_SHUTDOWN_HOURS) so they can be changed
# without editing this file.
#
# ---------------------------------------------------------------------------
# What "inactive" means, and why the obvious answers are wrong
# ---------------------------------------------------------------------------
# ⚠️  NOT window_activity. That tracks the last REDRAW, so re-tiling a window
# resets it — a fortnight-old agent reads as two minutes old the moment you split
# a pane next to it. Fine for a status column, fatal for a rule that kills things.
#
# ⚠️  NOT the transcript file's mtime either, which is the trap that looks safe.
# Sleeping an agent APPENDS to its transcript, so the act of putting something to
# sleep resets its shutdown clock. Measured on this machine: five agents whose
# last real conversation was 12-21 days ago all reported "46h" — exactly when they
# were slept. Under an mtime rule, sleeping something is enough to keep it alive
# forever, which is precisely backwards.
#
# What is used: the timestamp of the last `user` or `assistant` entry INSIDE the
# transcript. That is the conversation actually doing something, and it survives
# sleeping, waking, re-tiling and reboots because nothing but a real turn writes it.
#
# ---------------------------------------------------------------------------
# Why shutting down is safe to automate
# ---------------------------------------------------------------------------
# Killing a session is only a one-way door if the way back is lost with it. Every
# shutdown appends to an append-only archive first — session, window, folder,
# session id, task, last-active — and that file is never rotated. Recovery is
# `tarchive restore NAME`: the folder was never touched, so the session comes
# back and `claude -r <id>` puts the exact conversation back in it.
#
# A shutdown that cannot be archived does not happen.
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
ARCHIVE="$STATE_DIR/archive.tsv"
LOG="$STATE_DIR/lifecycle.log"
SOCKET="${TMUX_AGENTS_SOCKET:-default}"

SLEEP_H="${TMUX_AGENT_SLEEP_HOURS:-48}"
SHUTDOWN_H="${TMUX_AGENT_SHUTDOWN_HOURS:-168}"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --sleep-hours) SLEEP_H="${2:?}"; shift 2 ;;
    --shutdown-hours) SHUTDOWN_H="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "lifecycle: unknown option $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

. "$DIR/../shell/agents.sh" 2>/dev/null || true
. "$DIR/../shell/tmux-persist.sh" 2>/dev/null || true

TAB=$'\t'

# pane<TAB>session<TAB>window<TAB>state<TAB>idle_hours, one line per agent.
# Idle is -1 when it cannot be established, and nothing acts on -1.
agent_idle() {
  tmux -L "$SOCKET" list-panes -a -F \
    "#{pane_id}${TAB}#{session_name}${TAB}#{window_name}${TAB}#{?@agent-session-id,#{@agent-session-id},-}${TAB}#{pane_current_path}${TAB}#{pane_current_command}${TAB}#{?@agent-woken,#{@agent-woken},-}" \
  | awk -F"$TAB" '$4 != "-"' \
  | python3 -c '
import sys, os, json, time, datetime
now = time.time()
for ln in sys.stdin:
    parts = ln.rstrip("\n").split("\t")
    if len(parts) < 7: continue
    pane, sess, win, sid, cwd, cmd, woken = parts[:7]
    t = os.path.expanduser("~/.claude/projects/%s/%s.jsonl" % (cwd.replace("/", "-"), sid))
    last = None
    if os.path.exists(t):
        # Backwards in 64k chunks: transcripts reach hundreds of thousands of
        # tokens and the answer is always near the end.
        try:
            with open(t, "rb") as f:
                f.seek(0, 2); pos = f.tell(); buf = b""
                while pos > 0 and last is None:
                    step = min(65536, pos); pos -= step
                    f.seek(pos); buf = f.read(step) + buf
                    for line in reversed(buf.split(b"\n")):
                        try: d = json.loads(line)
                        except Exception: continue
                        if d.get("type") in ("user", "assistant") and d.get("timestamp"):
                            last = d["timestamp"]; break
        except OSError:
            pass
    ts = None
    if last:
        try:
            ts = datetime.datetime.fromisoformat(last.replace("Z", "+00:00")).timestamp()
        except Exception:
            ts = None
    # An agent that was just woken is ACTIVE, whatever its transcript says.
    # Waking adds no conversation turn, so without this the sweep immediately
    # undoes the wake: put back to sleep within the hour, or shut down again if
    # it was already past seven days. Whichever is later wins.
    try:
        w = float(woken)
        if ts is None or w > ts: ts = w
    except ValueError:
        pass
    h = int((now - ts) / 3600) if ts is not None else -1
    state = "asleep" if cmd in ("bash", "zsh", "sh", "dash", "fish", "ksh") else "awake"
    print("\t".join([pane, sess, win, state, str(h)]))
'
}

rows=$(agent_idle) || exit 0
[ -n "$rows" ] || exit 0

attached=$(tmux -L "$SOCKET" list-sessions -F '#{?session_attached,#{session_name},}' 2>/dev/null | grep -v '^$' || true)
is_attached() { printf '%s\n' "$attached" | grep -qxF "$1"; }

slept=0; killed=0

# ---------------------------------------------------------------------------
# Sleep pass — per agent, and reversible, so the only guard needed is "awake and
# old enough".
# ---------------------------------------------------------------------------
while IFS="$TAB" read -r pane sess win state idle; do
  [ "$state" = "awake" ] || continue
  [ "$idle" -ge 0 ] 2>/dev/null || continue
  [ "$idle" -gt "$SLEEP_H" ] || continue
  if [ "$DRY" = 1 ]; then
    printf '  SLEEP     %-42s %4dh\n' "$sess:$win" "$idle"; slept=$((slept + 1)); continue
  fi
  if tsleep "$pane" >/dev/null 2>&1; then
    slept=$((slept + 1)); log "slept $sess:$win (idle ${idle}h)"
  fi
done <<< "$rows"

# ---------------------------------------------------------------------------
# Shutdown pass — per SESSION, not per agent.
# ---------------------------------------------------------------------------
# A session is only shut down when EVERY agent in it is past the threshold. One
# session can hold four agents (that is what `ts` is for), and killing the
# session because the oldest of them went quiet would take the other three with
# it — including one you used this morning.
sessions=$(printf '%s\n' "$rows" | cut -d"$TAB" -f2 | sort -u)
while IFS= read -r sess; do
  [ -n "$sess" ] || continue
  is_attached "$sess" && continue          # never reap what you are looking at

  total=$(printf '%s\n' "$rows" | awk -F"$TAB" -v s="$sess" '$2 == s' | wc -l | tr -d ' ')
  stale=$(printf '%s\n' "$rows" | awk -F"$TAB" -v s="$sess" -v h="$SHUTDOWN_H" '$2 == s && $5 >= 0 && $5 > h' | wc -l | tr -d ' ')
  [ "$total" -gt 0 ] && [ "$stale" -eq "$total" ] || continue

  # Anything running in this session that is neither an agent nor a shell — a
  # build, an editor, a tail -f — means someone left work here that the idle
  # clock cannot see. Skip it and say so rather than guess.
  busy=$(tmux -L "$SOCKET" list-panes -s -t "=$sess" -F '#{pane_current_command}' 2>/dev/null \
    | grep -vE '^(bash|zsh|sh|dash|fish|ksh)$' | grep -vE '^[0-9]+\.[0-9]+' || true)
  if [ -n "$busy" ]; then
    log "skipped $sess — something is running in it: $(printf '%s' "$busy" | tr '\n' ' ')"
    continue
  fi

  if [ "$DRY" = 1 ]; then
    printf '  SHUTDOWN  %-42s %s agents, all stale\n' "$sess" "$total"; killed=$((killed + 1)); continue
  fi

  # Archive EVERY agent in the session before anything is killed. If the archive
  # cannot be written the session simply lives another hour — never the reverse.
  arc=""
  while IFS="$TAB" read -r pane s2 win state idle; do
    [ "$s2" = "$sess" ] || continue
    sid=$(tmux -L "$SOCKET" show-options -pqv -t "$pane" @agent-session-id 2>/dev/null)
    task=$(tmux -L "$SOCKET" show-options -pqv -t "$pane" @agent-task 2>/dev/null)
    cwd=$(tmux -L "$SOCKET" display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
    arc="$arc$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$(date '+%Y-%m-%dT%H:%M:%S')" "$sess" "${win:--}" "${cwd:--}" "${sid:--}" "${task:--}" "${idle}h")"$'\n'
  done <<< "$rows"

  if [ -z "$arc" ] || ! printf '%s' "$arc" >> "$ARCHIVE"; then
    log "REFUSED to shut down $sess — could not archive it"
    continue
  fi

  if tmux -L "$SOCKET" kill-session -t "=$sess" 2>/dev/null; then
    killed=$((killed + 1))
    log "shut down $sess ($total agents, all idle > ${SHUTDOWN_H}h) — archived, restore with: tarchive restore $sess"
  else
    log "failed to kill $sess after archiving it"
  fi
done <<< "$sessions"

if [ "$DRY" = 1 ]; then
  echo "dry run: would sleep $slept, shut down $killed"
else
  [ $((slept + killed)) -gt 0 ] && log "pass complete: slept $slept, shut down $killed"
  echo "slept $slept, shut down $killed"
fi
