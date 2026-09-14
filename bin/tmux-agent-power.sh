#!/usr/bin/env bash
# tmux-agent-power — sleep every awake agent before the battery does it for you.
#
#   tmux-agent-power.sh            one tick: act if on battery and low, else nothing
#   tmux-agent-power.sh -n         dry run: what a tick would sleep right now
#   tmux-agent-power.sh status     battery, threshold, and which agents are awake
#
# Run every 60s by launchd (com.tmux-agents.power). It does nothing at all
# unless the machine is on battery AND at or below TMUX_AGENT_BATTERY_SLEEP_PCT
# (default 10 — where macOS itself starts warning, with ~18 minutes left on this
# machine). Below that, each tick:
#
#   1. snapshots the server, so the shape on disk is seconds old, not minutes
#   2. sleeps every awake agent through the same tsleep path Ctrl+b S uses —
#      SIGTERM, transcript intact, session id stamped on the pane — so what the
#      power cut eventually finds is a set of shells, not 15GB of agents mid-turn
#   3. notifies once per discharge
#
# WHY: 2026-09-08 the battery ran from its 2% warning to dead with every agent
# awake. Nothing was lost — Claude appends its transcript per turn and the last
# snapshot was 5 minutes old — but any turn in flight was cut mid-tool-call, and
# that is the one kind of loss no snapshot covers. A power cut cannot be made
# graceful. Sleeping at 10% moves the graceful part earlier, to a moment that
# still has power, and turns "how did it die" into "it was slept", which is a
# state this setup already knows how to come back from.
#
# It NEVER wakes anything. Coming back on power clears the mark and logs it;
# Ctrl+b R, twake, or enter in the picker bring an agent back, same as after a
# reboot. A slept agent is one keystroke from awake, so nothing here is one-way.
#
# TMUX_AGENT_BATT_CMD replaces `pmset -g batt` (tests feed it a fake reading);
# TMUX_AGENT_NOTIFY_CMD is honoured by the notifier as everywhere else.
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
LOG="$STATE_DIR/power.log"
MARK="$STATE_DIR/low-battery"
PCT_SLEEP="${TMUX_AGENT_BATTERY_SLEEP_PCT:-10}"
MODE=tick

case "${1:-}" in
  -n|--dry-run) MODE=dry ;;
  status) MODE=status ;;
  -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) echo "power: unknown argument $1" >&2; exit 2 ;;
esac

mkdir -p "$STATE_DIR"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# The sleep machinery lives in the interactive shell helpers, exactly as the
# hourly lifecycle sweep uses it: tsleep is what Ctrl+b S runs, so an agent slept
# here is indistinguishable from one you slept yourself.
. "$DIR/../shell/agents.sh" 2>/dev/null || true
. "$DIR/../shell/tmux-persist.sh" 2>/dev/null || true
declare -F tsleep >/dev/null 2>&1 || { echo "power: tsleep not found next to $DIR" >&2; exit 1; }

# --- read the battery ---------------------------------------------------------
# pmset prints "Now drawing from 'Battery Power'" (or 'AC Power') and then one
# line per battery: " -InternalBattery-0 (id=…)  26%; discharging; 1:58 remaining".
# A machine with no battery prints only the first line, and reads as on AC.
if [ -n "${TMUX_AGENT_BATT_CMD:-}" ]; then batt=$($TMUX_AGENT_BATT_CMD 2>/dev/null)
else batt=$(pmset -g batt 2>/dev/null); fi
case "$batt" in *"Battery Power"*) on_battery=1 ;; *) on_battery=0 ;; esac
pct=$(printf '%s\n' "$batt" | grep -o '[0-9]\{1,3\}%' | head -1 | tr -d '%')
[ -n "$pct" ] || pct=100

awake=$(_t_sleep_candidates 0 2>/dev/null)
n_awake=$(printf '%s' "$awake" | grep -c . || true)

if [ "$MODE" = status ]; then
  if [ "$on_battery" = 1 ]; then src="battery"; else src="AC"; fi
  printf 'battery: %s%%, on %s — agents sleep at %s%% on battery (TMUX_AGENT_BATTERY_SLEEP_PCT)\n' "$pct" "$src" "$PCT_SLEEP"
  if [ "$n_awake" = 0 ]; then echo "awake agents: none"
  else
    echo "awake agents ($n_awake):"
    printf '%s\n' "$awake" | awk -F'\t' '{printf "  %-34s %5d MB  %s\n", $4, $3/1024, $5}'
  fi
  [ -e "$MARK" ] && echo "low-battery mark set: $(cat "$MARK")"
  exit 0
fi

# --- on AC: clear the mark, wake nothing --------------------------------------
if [ "$on_battery" = 0 ]; then
  if [ -e "$MARK" ]; then
    rm -f "$MARK"
    [ "$MODE" = dry ] || log "back on AC at ${pct}% — agents stay asleep; twake or Ctrl+b R brings them back"
  fi
  [ "$MODE" = dry ] && echo "on AC at ${pct}% — nothing to do"
  exit 0
fi

# --- on battery, above the line: nothing --------------------------------------
if [ "$pct" -gt "$PCT_SLEEP" ]; then
  [ "$MODE" = dry ] && echo "on battery at ${pct}%, above ${PCT_SLEEP}% — nothing to do ($n_awake awake)"
  exit 0
fi

# --- on battery, at or below the line -----------------------------------------
if [ "$MODE" = dry ]; then
  echo "on battery at ${pct}% — would snapshot, then sleep $n_awake awake agent(s):"
  tsleep -n --idle 0
  exit 0
fi

if [ "$n_awake" = 0 ]; then
  # Log the crossing once, then stay quiet: every later tick finds nothing awake.
  if [ ! -e "$MARK" ]; then
    date '+%Y-%m-%d %H:%M:%S' > "$MARK"
    log "battery ${pct}% (<= ${PCT_SLEEP}%), nothing awake — snapshot only"
    out=$("$DIR/tmux-agent-save.sh" 2>&1) && log "$out"
  fi
  exit 0
fi

# Snapshot FIRST: if the machine dies during the sleep pass, the snapshot still
# carries every session id, and tsleep stamps each pane before killing anyway.
out=$("$DIR/tmux-agent-save.sh" 2>&1) && log "$out"
out=$(tsleep --idle 0 2>&1) || true
log "battery ${pct}% (<= ${PCT_SLEEP}%): sleeping $n_awake awake agent(s)"
printf '%s\n' "$out" | sed 's/^/    /' >> "$LOG"
if [ ! -e "$MARK" ]; then
  date '+%Y-%m-%d %H:%M:%S' > "$MARK"
  "$DIR/tmux-agent-notify.sh" "tmux agents: battery at ${pct}%" \
    "Slept $n_awake agent(s) before the battery dies. Ctrl+b R wakes one; nothing was lost." 2>/dev/null || true
fi
exit 0
