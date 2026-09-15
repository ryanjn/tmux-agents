#!/usr/bin/env bash
# Stage a believable tmux-agents session for the README recordings.
#
#   ./docs/demo/stage.sh          set it up and attach
#   ./docs/demo/stage.sh setup    set it up, print the socket, don't attach
#   ./docs/demo/stage.sh teardown
#
# Everything lives on the `ta-demo` socket under a throwaway HOME. Same rule as
# test/integration.sh: this must be incapable of touching your real server, not
# merely careful about it.
#
# The agents are FAKE — a shell that sets its pane title to "<glyph> <task>",
# prints a scripted screen, and sleeps. That title is the entire contract
# tmux-agents reads, so the interface being recorded is the real one; only what
# sits behind the panes is staged. Real agents would be slow, non-deterministic,
# and would put whatever they happened to be doing into a public GIF.
#
# Screens are written to files and `cat`ed rather than passed as strings: the
# pane command already travels through tmux's own quoting, and nesting ANSI
# escapes inside that is how this script broke the first time.
set -u

SOCKET="ta-demo"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_HOME="${DEMO_HOME:-/tmp/tmux-agents-demo}"
REAL_TMUX="$(command -v tmux)"

case "$SOCKET" in default|"") echo "refusing: socket would be the real server" >&2; exit 2 ;; esac
t_() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
teardown() { t_ kill-server 2>/dev/null; rm -rf "$DEMO_HOME"; }

SCREENS=""
screen() {              # screen NAME  <<'EOF' ... EOF
  mkdir -p "$DEMO_HOME/screens"
  cat > "$DEMO_HOME/screens/$1.txt"
}

agent() {               # agent SESSION GLYPH TASK SCREEN [WINDOW]
  local sess="$1" glyph="$2" task="$3" scr="$4" wname="${5:-claude}"
  local dir="$DEMO_HOME/agent-projects/$sess"
  mkdir -p "$dir"
  t_ new-session -d -s "$sess" -n "$wname" -c "$dir" \
     "printf '\033]2;$glyph $task\033\\'; cat '$DEMO_HOME/screens/$scr.txt'; while :; do sleep 1; done"
  t_ new-window -d -t "$sess" -n shell -c "$dir" "while :; do sleep 1; done"
}

sibling() {             # sibling SESSION GLYPH TASK WINDOW SCREEN
  local sess="$1" glyph="$2" task="$3" wname="$4" scr="$5"
  t_ new-window -d -t "$sess" -n "$wname" -c "$DEMO_HOME/agent-projects/$sess" \
     "printf '\033]2;$glyph $task\033\\'; cat '$DEMO_HOME/screens/$scr.txt'; while :; do sleep 1; done"
}

# A sleeping agent: the process is gone, the pane sits at a shell, and the
# @agent-session-id pane option is what says an agent lives here.
asleep_agent() {        # asleep_agent SESSION TASK
  local sess="$1" task="$2" dir="$DEMO_HOME/agent-projects/$1" pane
  mkdir -p "$dir"
  t_ new-session -d -s "$sess" -n claude -c "$dir" "while :; do sleep 1; done"
  pane=$(t_ list-panes -t "$sess" -F '#{pane_id}' | head -1)
  t_ set-option -p -t "$pane" @agent-session-id "$(uuidgen | tr 'A-Z' 'a-z')"
  t_ set-option -p -t "$pane" @agent-task "$task"
}

# "Waiting on you", and its age, come from a dated marker file.
mark_waiting() {        # mark_waiting SESSION MINUTES_AGO
  local sess="$1" mins="$2" pane wd="$DEMO_HOME/.cache/tmux-agent-status"
  pane=$(t_ list-panes -t "$sess" -F '#{pane_id}' | head -1)
  mkdir -p "$wd"; : > "$wd/${pane#%}.waiting"
  touch -t "$(date -v-"${mins}"M +%Y%m%d%H%M 2>/dev/null || date -d "-${mins} minutes" +%Y%m%d%H%M)" \
        "$wd/${pane#%}.waiting"
}

setup() {
  teardown
  mkdir -p "$DEMO_HOME/agent-projects" "$DEMO_HOME/.cache" "$DEMO_HOME/.config" "$DEMO_HOME/screens"

  HOME="$DEMO_HOME" XDG_CONFIG_HOME="$DEMO_HOME/.config" \
    "$ROOT/install.sh" --with-extras --with-status --no-cli --no-shell --no-reload \
      --rc "$DEMO_HOME/.bash_profile" --tmux-conf "$DEMO_HOME/.tmux.conf" >/dev/null 2>&1

  local C='\033[38;5;110m' D='\033[38;5;244m' B='\033[1m' G='\033[38;5;108m' M='\033[38;5;174m' Z='\033[0m'

  screen api <<EOF
$(printf "${C}⏺${Z} The migration is ready, but ${B}orders.legacy_ref${Z} still holds\n  4,102 non-null rows and nothing in the codebase reads it.\n\n  Drop it in this migration, or leave it and open a ticket?\n\n${D}  1. Drop it now\n  2. Leave it, open a ticket${Z}\n")
EOF
  screen payments <<EOF
$(printf "${C}⏺${Z} The retry path has no currency once the quote expires.\n\n  Fall back to the account default, or fail the charge?\n")
EOF
  screen billing <<EOF
$(printf "${D}  1${Z} export async function retry<T>(\n${D}  2${Z}   fn: () => Promise<T>,\n${D}  3${Z}   attempts = 3,\n${D}  4${Z} ) {\n${D}  5${Z}   let lastError: unknown\n${D}  6${Z}   for (let i = 0; i < attempts; i++) {\n${D}  7${Z}     try { return await fn() } catch (e) {\n${D}  8${Z}       lastError = e\n${D}  9${Z}       await sleep(2 ** i * 100)\n${D} 10${Z}     }\n${D} 11${Z}   }\n")
EOF
  screen docs <<EOF
$(printf "${C}⏺${Z} Rewrote the install guide around the one-command path and\n  moved the manual steps into a collapsible section.\n\n${G}  + 84${Z}  ${M}- 121${Z}  ${D}README.md${Z}\n")
EOF
  screen bundle <<EOF
$(printf "${C}⏺${Z} Bundle is 1.42 MB gzipped. Three dependencies are 61% of it:\n\n${D}  moment        296 kB\n  lodash        210 kB\n  chart.js      178 kB${Z}\n\n  Checking what still imports moment…\n")
EOF
  screen slowquery <<EOF
$(printf "${C}⏺${Z} The N+1 is in the invoice serializer — one query per line item.\n\n${D}  EXPLAIN: Seq Scan on line_items  (cost=0.00..18402.11)${Z}\n")
EOF

  agent   api-gateway    "✳" "Should I drop the legacy column?"        api
  agent   payments-api   "✳" "Which currency should the fallback use?" payments
  agent   billing-worker "⠿" "Adding the retry backoff"                billing
  agent   docs-site      "✳" "Rewrote the install guide"               docs
  agent   web            "⠿" "Auditing the bundle size"                bundle
  sibling web            "⠿" "Tracing the slow query"  claude2         slowquery
  asleep_agent vault-tagger "Tagging every item in the vault"

  sleep 1
  mark_waiting api-gateway 32
  mark_waiting payments-api 4

  # Favorites, so `tf ls` shows a list rather than its empty state.
  # NAME <TAB> TARGET <TAB> COMMAND <TAB> NOTE
  mkdir -p "$DEMO_HOME/.config/tmux-agents"
  printf '%b\n' \
    "api-gateway\tacme/api-gateway\tclaude\tthe one that always needs me" \
    "billing-worker\t~/Projects/billing\tclaude\t-" \
    "docs-site\tacme/docs\tclaude\tquarterly docs pass" \
    > "$DEMO_HOME/.config/tmux-agents/favorites.tsv"

  # A snapshot on disk, so `tsnaps -l` has something to list.
  HOME="$DEMO_HOME" TMUX_AGENTS_STATE="$DEMO_HOME/.local/state/tmux-agents" \
    "$ROOT/bin/tmux-agent-save.sh" -L "$SOCKET" >/dev/null 2>&1

  # The snapshot header records the real hostname, and these recordings are
  # published. Neutralise it rather than leaving someone's machine name in a GIF.
  local snap
  for snap in "$DEMO_HOME/.local/state/tmux-agents/snapshots"/*.tsv; do
    [ -e "$snap" ] || continue
    awk -F'\t' -v OFS='\t' '$1 == "# host" { $2 = "workstation" } { print }' "$snap" > "$snap.tmp" \
      && mv "$snap.tmp" "$snap"
  done

  printf 'socket=%s home=%s\n' "$SOCKET" "$DEMO_HOME"
}

case "${1:-attach}" in
  setup)    setup ;;
  teardown) teardown ;;
  attach)   setup >/dev/null; HOME="$DEMO_HOME" exec t_ attach -t api-gateway ;;
  *)        echo "usage: stage.sh [setup|attach|teardown]" >&2; exit 2 ;;
esac
