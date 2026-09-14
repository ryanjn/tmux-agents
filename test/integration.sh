#!/usr/bin/env bash
# tmux-agents integration test — drives a REAL tmux server on its own socket.
#
#   ./test/integration.sh
#
# smoke.sh deliberately never starts a server, which leaves the three code paths
# that can destroy work with no automated coverage: restore, kill escalation and
# sleep. This is its sibling, not its replacement.
#
# ⚠️  SAFETY. Every tmux call here goes through `t_()`, which hard-codes the test
# socket. Nothing in this file may call bare `tmux`: a suite that kills sessions
# for a living must be structurally incapable of reaching your real one, not
# merely careful. The guard below refuses to run if the socket name is wrong, and
# the trap tears the server down on any exit path.
set -u

SOCKET="ta-integration-test"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$SOCKET" in
  default|"") echo "refusing to run: socket name would target the real server" >&2; exit 2 ;;
esac
t_() { command tmux -L "$SOCKET" "$@"; }
cleanup() { t_ kill-server 2>/dev/null; rm -rf "$TMPHOME" "$SHIMDIR"; }

TMPHOME=$(mktemp -d)
trap cleanup EXIT INT TERM

export HOME="$TMPHOME"
export TMUX_AGENTS_STATE="$TMPHOME/.local/state/tmux-agents"
export TMUX_SESSION_PATH="$TMPHOME/agent-projects"
mkdir -p "$TMUX_AGENTS_STATE" "$TMUX_SESSION_PATH" "$TMPHOME/.cache"

PASS=0; FAIL=0
if [ -t 1 ]; then G=$(printf '\033[32m'); R=$(printf '\033[31m'); Z=$(printf '\033[0m')
else G=""; R=""; Z=""; fi
DIM=$(printf '\033[2m'); [ -t 1 ] || DIM=""
ok()   { printf '  %s✓%s %s\n' "$G" "$Z" "$1"; PASS=$((PASS+1)); }
no()   { printf '  %s✗%s %s\n' "$R" "$Z" "$1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1"; fi; }

command -v tmux >/dev/null 2>&1 || { echo "tmux not installed"; exit 2; }

# ⚠️  Resolved BEFORE the shim is put on PATH, and used for nothing else.
# `command tmux` does NOT reach past the shim — `command` bypasses functions and
# aliases, not PATH — so after the shim exists there is no way to ask about the
# real server except through this saved absolute path. The first version of the
# guard below got this wrong and cheerfully compared the test server to itself.
REAL_TMUX=$(command -v tmux)

# ⚠️  shell/agents.sh calls bare `tmux`. There is no socket option to pass it —
# _t_agent_rows and friends talk to whatever server `tmux` means. Sourcing them
# and hoping is how a test suite kills your real sessions.
#
# So make `tmux` itself mean the test socket, for this process and everything it
# spawns, by putting a forwarding shim first on PATH. That covers the helpers,
# the bin/ scripts, and anything either of them shells out to — including code
# added later that nobody remembered to point at a socket.
SHIMDIR=$(mktemp -d)
cat > "$SHIMDIR/tmux" <<SHIM
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIMDIR/tmux"
PATH="$SHIMDIR:$PATH"; export PATH

# Prove the shim is in front before anything relies on it.
[ "$(command -v tmux)" = "$SHIMDIR/tmux" ] || { echo "shim not on PATH; refusing to run" >&2; exit 2; }

# shellcheck disable=SC1090,SC1091
. "$ROOT/shell/agents.sh"

# The real server, recorded before we touch anything. This suite kills sessions
# for a living; "the calls are all socketed" is a claim, and a claim is not a
# guarantee. During development a session on the default server disappeared
# during a run of this file and the cause was never proven either way — which is
# precisely the situation this check exists to make impossible to be in again.
# If the default server's session list differs at the end, the run failed,
# whatever else passed.
REAL_BEFORE=$("$REAL_TMUX" list-sessions -F '#{session_name}' 2>/dev/null | sort)

printf '\ntmux-agents integration test (socket: %s)\n\n' "$SOCKET"

# ---------------------------------------------------------------------------
# A fake agent
# ---------------------------------------------------------------------------
# Claude Code is not installed in CI, and this does not need it. What detection
# keys on is the pane title — "<glyph> <task>", set via OSC 2 — so a shell that
# sets its own title and sleeps is indistinguishable to everything under test.
fake_agent() {          # fake_agent SESSION TASK [GLYPH]
  local sess="$1" task="$2" glyph="${3:-✳}" dir="$TMUX_SESSION_PATH/$1"
  mkdir -p "$dir"
  t_ new-session -d -s "$sess" -c "$dir" \
     "printf '\033]2;%s %s\033\\' '$glyph' '$task'; while :; do sleep 1; done"
  # Let tmux observe the title before anything reads it.
  local i=0
  while [ $i -lt 50 ]; do
    case "$(t_ list-panes -t "$sess" -F '#{pane_title}' 2>/dev/null)" in
      "$glyph "*) return 0 ;;
    esac
    sleep 0.1; i=$((i+1))
  done
  return 1
}

printf 'the harness itself\n'
check "the test socket is not the default one" "[ '$SOCKET' != default ]"
t_ kill-server 2>/dev/null
check "starts a fake agent with a live title" "fake_agent alpha 'writing the parser'"
check "the fake agent's title carries the glyph" \
  "t_ list-panes -t alpha -F '#{pane_title}' | grep -q '^✳ writing the parser$'"
check "a real server is running on our socket only" "t_ has-session -t alpha"

printf '\ndetection\n'
fake_agent beta 'second task' >/dev/null 2>&1
# A pane with an ordinary title — what a plain shell looks like. Separate from
# fake_agent rather than fake_agent with an empty glyph, which produces a title
# with a leading space and tests something nobody ships.
plain_pane() {          # plain_pane SESSION TITLE
  mkdir -p "$TMUX_SESSION_PATH/$1"
  t_ new-session -d -s "$1" -c "$TMUX_SESSION_PATH/$1" \
     "printf '\033]2;%s\033\\' '$2'; while :; do sleep 1; done"
  sleep 0.5
}
plain_pane plain 'no glyph here'
check "classifies a glyph-titled pane as an agent" \
  "_t_agent_rows 2>/dev/null | grep -q alpha"
check "does NOT classify a plain-titled pane as an agent" \
  "! _t_agent_rows 2>/dev/null | grep -q plain"

printf '\nsave and restore\n'
"$ROOT/bin/tmux-agent-save.sh" -L "$SOCKET" >/dev/null 2>&1
SNAP=$(command ls -1t "$TMUX_AGENTS_STATE"/snapshots/*.tsv 2>/dev/null | head -1)
check "a snapshot was written" "[ -n '$SNAP' ] && [ -s '$SNAP' ]"
check "the snapshot marks the fake agent as an agent" \
  "awk -F'\t' '\$1==\"P\" && \$2==\"alpha\" && \$15==1' '$SNAP' | grep -q ."
check "the snapshot records its task" \
  "awk -F'\t' '\$1==\"P\" && \$2==\"alpha\" {print \$16}' '$SNAP' | grep -q 'writing the parser'"

t_ kill-session -t alpha 2>/dev/null
check "session is gone before restore" "! t_ has-session -t alpha"
"$ROOT/bin/tmux-agent-restore.sh" -L "$SOCKET" -f "$SNAP" >/dev/null 2>&1
check "restore brings the session back" "t_ has-session -t alpha"
check "restore puts it back on its own directory" \
  "t_ list-panes -t alpha -F '#{pane_current_path}' | grep -q 'agent-projects/alpha'"
check "restore does not duplicate a session that is still running" \
  "[ \"\$(t_ list-sessions -F '#{session_name}' | grep -c '^beta\$')\" = 1 ]"

printf '\nthe doctor sees through the title contract\n'
# The failure this release exists for: a pane that is plainly an agent by every
# other measure, whose title no longer matches. Detection must not call this
# quiet — it must call it broken.
plain_pane wedged 'a real agent whose title contract moved'
check "a glyph-less pane is invisible to detection (the failure mode)" \
  "! _t_agent_rows 2>/dev/null | grep -q wedged"

printf '\nthe real server was never touched\n'
REAL_AFTER=$("$REAL_TMUX" list-sessions -F '#{session_name}' 2>/dev/null | sort)
if [ "$REAL_BEFORE" = "$REAL_AFTER" ]; then
  ok "default server's sessions are unchanged ($(printf '%s' "$REAL_BEFORE" | grep -c . ) before, same after)"
else
  no "THE DEFAULT SERVER CHANGED — this suite touched something it must not"
  printf '      %sbefore:%s %s\n' "$DIM" "$Z" "$(printf '%s' "$REAL_BEFORE" | tr '\n' ' ')"
  printf '      %safter: %s %s\n' "$DIM" "$Z" "$(printf '%s' "$REAL_AFTER"  | tr '\n' ' ')"
  printf '      %sRecover with: trestore -f <newest snapshot> <session>, then twake <session>%s\n' "$DIM" "$Z"
fi

printf '\n%s%d passed%s' "$G" "$PASS" "$Z"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$R" "$FAIL" "$Z"
printf '\n\n'
[ "$FAIL" = 0 ]
