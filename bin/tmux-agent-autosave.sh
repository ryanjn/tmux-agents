#!/usr/bin/env bash
# tmux-agent-autosave — snapshot when the server's shape changes, coalesced.
#
# Fired by tmux hooks (session-created, window-linked, pane-exited, …) with
# `run-shell -b`, so the timed snapshot every 5 minutes is the fallback, not the
# only line: a session you started 30 seconds before the power went is in the
# snapshot too. Hooks come in bursts (one new session fires three of them), so
# this coalesces: the first caller becomes the runner, marks dirty, waits
# TMUX_AGENT_AUTOSAVE_SETTLE seconds (2) and saves; anyone arriving meanwhile
# just re-marks dirty and leaves, and the runner loops until nothing is dirty.
#
# Two things it must NOT do, both learned the hard way on the timed job:
#
#   ⚠️  Never save while a restore is replaying a snapshot. The hooks fire for
#   every session restore creates, and a snapshot of a half-built server would
#   become "the newest" — the one restore reads on the next boot. Restore leaves
#   a .restoring marker (with its pid) for the duration; a marker whose pid is
#   dead is ignored, so a restore killed midway cannot silence autosave forever.
#
#   ⚠️  Never save before this boot's restore has run. If you open a terminal and
#   start one session before launchd gets to the restore, that one-session server
#   must not become the snapshot the restore then replays. The persist job marks
#   the boot it has restored for; until that mark matches the running kernel's
#   boot time, this does nothing.
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
LOCK="$STATE_DIR/.autosave.lock"
DIRTY="$STATE_DIR/.autosave.dirty"
RESTORING="$STATE_DIR/.restoring"
SETTLE="${TMUX_AGENT_AUTOSAVE_SETTLE:-2}"
mkdir -p "$STATE_DIR"

if [ -e "$RESTORING" ]; then
  rpid=$(head -n1 "$RESTORING" 2>/dev/null)
  if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; then exit 0; fi
  rm -f "$RESTORING"
fi

# Either format counts as "this boot's restore has claimed it" — persist.sh
# rewrites the old one on its next tick, and until then saving must not stop.
boot_id=$("$DIR/boot-id.sh" 2>/dev/null)
if [ -n "$boot_id" ]; then
  seen=$(cat "$STATE_DIR/last-boot" 2>/dev/null)
  if [ "$seen" != "$boot_id" ] && [ "$seen" != "$("$DIR/boot-id.sh" --legacy 2>/dev/null)" ]; then
    exit 0
  fi
fi

touch "$DIRTY"
while :; do
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Someone holds the runner slot. Alive: they will see DIRTY and save. Dead
    # (a power cut mid-save — precisely the event all this exists for): the lock
    # would block every autosave until someone noticed, so take it over.
    pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then exit 0; fi
    rm -rf "$LOCK"; continue
  fi
  echo $$ > "$LOCK/pid"
  while [ -e "$DIRTY" ]; do
    rm -f "$DIRTY"
    sleep "$SETTLE"
    "$DIR/tmux-agent-save.sh" >/dev/null 2>&1 || true
  done
  rm -rf "$LOCK"
  # A hook that fired between the loop ending and the lock going away found the
  # lock held and left; its dirty mark is still here, so go round again.
  [ -e "$DIRTY" ] || exit 0
done
