#!/usr/bin/env bash
# boot-id — print an id that changes only when the machine reboots.
#
# Used to answer "is this the first run since boot?", which is what makes
# restore a once-per-boot event rather than something that resurrects 28
# sessions five minutes after you deliberately closed them. Three callers need
# it: the launchd/systemd entry point, the autosave hook, and _t_restoring.
#
# ⚠️  One file because `sysctl -n kern.boottime` is macOS-only, and the three
# copies of it that used to exist were not a style problem: on Linux they all
# returned empty, so `_t_restoring` silently never reported a pending restore
# and the test for it failed in CI while passing on every developer's Mac. A
# platform branch is a thing to have once.
#
# Prints nothing when it cannot tell. Callers must treat that as "unknown" and
# degrade, never as "the machine rebooted".
#
#   boot-id.sh            the id
#   boot-id.sh --legacy   what the pre-0.4.6 code printed, for the migration
#
# ⚠️  The old expression was `sed 's/.*sec = \([0-9]*\).*/\1/'`, and `.*` is
# greedy: it ran past "sec = " to "usec = " and captured the MICROseconds. It
# worked by accident — usec changes every boot too — but it is not the boot
# time, and it means every existing machine has a marker in the old format.
# Changing the format without recognising the old one would read as a reboot on
# the next tick and restore a server that is already running.
set -u

legacy=0
[ "${1:-}" = --legacy ] && legacy=1

case "$(uname -s 2>/dev/null)" in
  Darwin)
    # "{ sec = 1790287609, usec = 599549 } Thu Sep 24 18:06:49 2026"
    if [ "$legacy" = 1 ]; then
      sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/'
    else
      sysctl -n kern.boottime 2>/dev/null | sed -n 's/^[^0-9]*sec = \([0-9]*\).*/\1/p'
    fi
    ;;
  Linux)
    [ "$legacy" = 1 ] && exit 0      # the old code printed nothing here
    # /proc/stat's btime is the boot time in seconds since the epoch. Stable
    # across the uptime and cheap to read.
    awk '/^btime/ { print $2; exit }' /proc/stat 2>/dev/null
    ;;
  *)
    [ "$legacy" = 1 ] && exit 0
    # Anything else: the boot time of pid 1 is the nearest portable equivalent.
    ps -o lstart= -p 1 2>/dev/null | tr -s ' ' '-' | tr -d '\n'
    ;;
esac
exit 0
