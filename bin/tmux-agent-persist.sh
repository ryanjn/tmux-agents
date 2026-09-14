#!/usr/bin/env bash
# tmux-agent-persist — the launchd entry point behind surviving a macOS restart.
#
# One job, two behaviours, decided by whether this is the first run since boot:
#
#   first run after a reboot -> restore the sessions from the last snapshot
#   every run after that     -> save a fresh snapshot
#
# ⚠️  The boot check is what makes this safe, and it is not optional. The obvious
# rule — "restore whenever the server is empty" — means that the moment you
# deliberately close every session, the next tick five minutes later silently
# resurrects all 28 of them. Restore is a once-per-boot event, so it is keyed to
# the actual boot time, not to emptiness.
set -u
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
BOOT_MARK="$STATE_DIR/last-boot"
LOG="$STATE_DIR/persist.log"
SOCKET="${TMUX_AGENTS_SOCKET:-default}"

mkdir -p "$STATE_DIR"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# kern.boottime changes only across a real boot, so it identifies this uptime.
boot_id=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/')
[ -n "$boot_id" ] || boot_id="unknown"
seen=$(cat "$BOOT_MARK" 2>/dev/null || echo "")

if [ "$boot_id" != "$seen" ]; then
  # First run of this uptime. Claim it before restoring, so a restore that dies
  # halfway cannot loop: a half-restored server is fixed by hand, not by retry.
  printf '%s\n' "$boot_id" > "$BOOT_MARK"
  if [ -e "$STATE_DIR/last.tsv" ]; then
    out=$("$HERE/tmux-agent-restore.sh" -L "$SOCKET" 2>&1)
    log "boot $boot_id: $out"
  else
    log "boot $boot_id: no snapshot to restore"
  fi
  exit 0
fi

out=$("$HERE/tmux-agent-save.sh" -L "$SOCKET" 2>&1) && log "$out"

# Age agents out: sleep at 48h of no conversation, shut down at 7 days. Hourly,
# not every tick — this reads the tail of every transcript and, at the far end,
# kills sessions. A five-minute cadence would buy nothing and cost twelve times
# the work.
LIFECYCLE_MARK="$STATE_DIR/last-lifecycle"
last=$(cat "$LIFECYCLE_MARK" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $(( $(date +%s) - last )) -ge 3600 ]; then
  date +%s > "$LIFECYCLE_MARK"
  out=$("$HERE/tmux-agent-lifecycle.sh" 2>&1) && [ "$out" != "slept 0, shut down 0" ] && log "lifecycle: $out"
fi
