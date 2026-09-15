#!/usr/bin/env bash
# The typed half of the demo: the commands you run from a shell.
#
# Run under `asciinema rec`; see record.sh. Types each command a character at a
# time so the recording reads like someone using the tool rather than a log
# being replayed.
#
# Everything here runs against the ta-demo socket via a PATH shim, so the
# recording can never show — or touch — a real session.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_HOME="${DEMO_HOME:-/tmp/tmux-agents-demo}"

# Sourced HERE rather than by the caller: this script runs as its own process,
# so functions defined in the wrapper would not reach it. It matters twice over
# — `tf` and `tsnaps` also exist as command symlinks in a real ~/.local/bin, and
# without the functions defined a recording silently demos those instead, each
# resolving its helpers against the wrong HOME. Shell functions shadow PATH.
# shellcheck disable=SC1090,SC1091
. "$ROOT/shell/agents.sh"
# shellcheck disable=SC1090,SC1091
. "$ROOT/shell/tmux-persist.sh"
# shellcheck disable=SC1090,SC1091
. "$ROOT/shell/favorites.sh"
PROMPT=$'\033[38;5;110m~\033[0m \033[38;5;244m$\033[0m '

type_out() {            # type_out TEXT — one character at a time
  local s="$1" i
  for (( i=0; i<${#s}; i++ )); do
    printf '%s' "${s:$i:1}"
    sleep 0.045
  done
  sleep 0.35
  printf '\n'
}

run() {                 # run COMMAND [PAUSE]
  printf '%b' "$PROMPT"
  type_out "$1"
  eval "$1"
  sleep "${2:-2.4}"
  printf '\n'
}

clear
sleep 0.8

run 'ta' 3.6
run 'tl' 2.4
run 'tf ls' 2.8
run 'tsnaps -l' 3.4
sleep 1.2
