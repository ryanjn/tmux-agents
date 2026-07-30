# tmux-agents — shell helpers
# https://github.com/ryanjn/tmux-agents
#
# Sourced from your shell rc by install.sh. Also sourced by the tmux popups, so
# the picker and your prompt share one definition of what an agent is.
#
# Scope on purpose: these cover what you do from a *shell* — attach, list, kill,
# spawn a sibling. Things you do from *inside* a session (new window, split,
# zoom, copy mode) stay on the tmux keybindings, which are already faster than
# typing a command.
#
# Bash. Under zsh the functions load and work, but tab completion is skipped
# (it uses bash's `complete`).
#
# Configuration, all overridable before this is sourced:
#
#   T_AUTOSTART             what a new session runs in window 1  (default: claude)
#   TMUX_SESSION_PATH       where session folders are looked for and made
#   TMUX_AGENT_EXTRA_PROCS  agent CLIs to detect by process name (default: none)
#
# ⚠️  Function names are short and can collide: `ts` is moreutils' timestamp
# command, and `t` is a popular alias. Check with `type t` before sourcing, or
# see the README for how to load only the tmux keybindings.

TMUX_AGENTS_VERSION="0.1.0"

command -v tmux >/dev/null 2>&1 || return 0

# ---------------------------------------------------------------------------
# Where a new session's working directory comes from
# ---------------------------------------------------------------------------
# Colon-separated search path. A new session named NAME gets a matching folder:
#
#   1. If NAME already exists as a directory anywhere on this path, use it.
#   2. Otherwise create it under the FIRST entry.
#
# Step 1 is what stops `t address-verifier` from burying your real checkout
# under a fresh empty folder of the same name. Override per-shell if you want
# agent folders somewhere else:
#
#   export TMUX_SESSION_PATH="$HOME/scratch:$HOME/Projects"
: "${TMUX_SESSION_PATH:=$HOME/agent-projects:$HOME/Projects}"

# What `t` starts in window 1 of a NEW session. Set empty for a plain shell:
#   export T_AUTOSTART=
: "${T_AUTOSTART=claude}"

# _t_workdir NAME — print the directory a new session named NAME should use,
# creating it if it doesn't exist yet. Only ever called when a session is being
# created, so attaching to an existing session never touches the filesystem.
_t_workdir() {
  local name="$1" dir
  local -a roots
  IFS=: read -ra roots <<< "$TMUX_SESSION_PATH"

  for dir in "${roots[@]}"; do
    [ -n "$dir" ] && [ -d "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
  done

  dir="${roots[0]}/$name"
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# ---------------------------------------------------------------------------
# t [NAME] — attach to a session, creating it if it doesn't exist
# ---------------------------------------------------------------------------
#   t          attach to the most recent session; start "main" if there are none
#   t pp       attach to "pp", creating it (and ~/agent-projects/pp) if needed
#
# The one command that covers ~90% of it — no more "does this session exist
# yet?" before choosing between `tmux new -s` and `tmux attach -t`.
#
# Two details that matter:
#   - "=$session" forces an exact match. Plain `-t pp` prefix-matches, so it
#     would happily attach you to "pp-eval" when you meant to create "pp".
#   - Already inside tmux, it switches instead of attaching. Nesting a session
#     inside itself is the gotcha this avoids.
t() {
  local session="$1"

  if [ -z "$session" ]; then
    if tmux has-session 2>/dev/null; then
      # Let tmux pick the most recent itself.
      if [ -n "${TMUX:-}" ]; then
        tmux switch-client -l
      else
        tmux attach
      fi
      return
    fi
    session=main
  fi

  # A slash would turn mkdir -p into a surprise directory tree.
  case "$session" in
    */*) echo "t: session name can't contain '/'" >&2; return 2 ;;
  esac

  if ! tmux has-session -t "=$session" 2>/dev/null; then
    _t_new_session "$session" >/dev/null \
      || { echo "t: could not create session '$session'" >&2; return 1; }
  fi

  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$session"
  else
    tmux attach -t "=$session"
  fi
}

# ---------------------------------------------------------------------------
# _t_new_session NAME [DIR] — create the session, print its agent pane's id
# ---------------------------------------------------------------------------
# Split out of `t` so the picker's "new agent" key (Ctrl+b a, then ctrl-n)
# builds a session that is identical to a hand-typed `t NAME` — same layout,
# same window names, same autostart. One code path, so they can't drift.
#
# Detached on purpose: the caller decides whether to jump to it.
_t_new_session() {
  local session="$1" dir="${2:-}" win1 pane

  case "$session" in
    "")   echo "t: session name can't be empty" >&2; return 2 ;;
    */*)  echo "t: session name can't contain '/'" >&2; return 2 ;;
    -*)   echo "t: session name can't start with '-'" >&2; return 2 ;;
  esac

  if [ -z "$dir" ]; then
    dir=$(_t_workdir "$session") \
      || { echo "t: could not create a working directory for '$session'" >&2; return 1; }
  fi

  # Window 1 runs the agent, window 2 is a plain shell in the same directory,
  # one keystroke away (Ctrl+b 2). Named explicitly because Claude Code
  # renames the window to its own version string otherwise.
  # Name window 1 after whatever it runs, so a T_AUTOSTART override gets a window
  # named after its own tool rather than "claude".
  win1="${T_AUTOSTART%% *}"
  win1="${win1##*/}"
  [ -n "$win1" ] || win1=shell

  _t_session_notes "$dir" "$session" "$win1"

  pane=$(tmux new-session -d -s "$session" -c "$dir" -n "$win1" -P -F '#{pane_id}') || return 1
  tmux new-window -t "=$session" -n shell -c "$dir"
  tmux select-window -t "=$session:1"

  # send-keys rather than launching claude as the pane's command, for two
  # reasons: it runs through the interactive shell so your `claude` alias
  # (and its --dangerously-skip-permissions) applies, and when claude exits
  # you drop to a live shell instead of the pane dying and taking the
  # session with it.
  [ -n "$T_AUTOSTART" ] && tmux send-keys -t "$pane" "$T_AUTOSTART" Enter

  printf '%s\n' "$pane"
}

# ---------------------------------------------------------------------------
# _t_session_notes DIR SESSION WINDOW — leave provenance in a new agent folder
# ---------------------------------------------------------------------------
# An agent that lands in ~/agent-projects/pricing-api three days from now has no
# way to know what that folder is, who made it, or when. This writes that down,
# as CLAUDE.md so it's actually *loaded* — Claude Code reads CLAUDE.md from the
# cwd upward at session start, which no other filename gets you.
#
# Two guards, both about not vandalising real work:
#
#   - Only into an EMPTY directory. `_t_workdir` resolves a name against
#     $TMUX_SESSION_PATH first, so `t address-verifier` lands in your actual
#     checkout — dropping a file in there would be wrong, and would show up as
#     an untracked file in someone's git status. Empty is the reliable signal
#     that this folder was made for this session and nothing else. It also means
#     re-running `t NAME` on a folder you deliberately emptied re-seeds it.
#   - Never overwrite. Implied by the emptiness test, kept anyway.
#
# Failure here is never fatal: a session you can use beats a session you can't
# because a note wouldn't write.
_t_session_notes() {
  local dir="$1" session="$2" win1="$3" started started_utc origin

  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  [ -e "$dir/CLAUDE.md" ] && return 0
  [ -z "$(ls -A "$dir" 2>/dev/null)" ] || return 0

  started=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)
  started_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  origin="${_T_ORIGIN:-the \`t\` shell helper}"

  # A quoted heredoc plus one sed pass, NOT an expanding heredoc: the template
  # is full of `backticks` for code spans, and inside an unquoted heredoc those
  # are command substitution — `t NAME` would be executed while writing the file.
  sed \
    -e "s|@@SESSION@@|$session|g" \
    -e "s|@@DIR@@|$dir|g" \
    -e "s|@@STARTED@@|$started|g" \
    -e "s|@@STARTED_UTC@@|$started_utc|g" \
    -e "s|@@ORIGIN@@|$origin|g" \
    -e "s|@@WIN1@@|$win1|g" \
    -e "s|@@HOST@@|$(hostname -s 2>/dev/null)|g" \
    > "$dir/CLAUDE.md" 2>/dev/null <<'MD'
# Agent session: @@SESSION@@

This folder was created **empty** by @@ORIGIN@@ to hold the tmux agent session
`@@SESSION@@`. Nothing here is a checkout unless someone has made one since.
Treat this file as provenance, not as instructions.

| | |
|---|---|
| Session | `@@SESSION@@` |
| Folder | `@@DIR@@` |
| Started | @@STARTED@@ (@@STARTED_UTC@@) |
| Machine | @@HOST@@ |
| Window 1 | `@@WIN1@@` — the agent |
| Window 2 | `shell` — a plain shell in this folder |

## What this session is for

_Not recorded yet._ If you are the agent working here, replace this section with
a couple of lines on what the session is actually for, and keep it current — it
is the first thing the next agent in this folder will read.

## Working with this session

- `t @@SESSION@@` — reattach from any terminal, any time. Creates nothing if it
  is already running
- `Ctrl+b d` — detach and leave the agent running. This is the normal way to
  step away; closing the terminal does not stop it
- `Ctrl+b a` — agent picker: jump between agents, `ctrl-n` start a new one,
  `ctrl-s` start a second one in this same folder, `ctrl-x` kill one
- `ta` — every running agent and what it is working on

## Housekeeping

Delete this file whenever it stops being useful. One gotcha if you are about to
clone a repo in here: `git clone URL .` refuses a non-empty directory, so either
remove this file first, or use `git init && git remote add origin URL && git pull`.
MD

  return 0
}

# ---------------------------------------------------------------------------
# _t_focus PANE — jump the client to a pane, from a shell or from a popup
# ---------------------------------------------------------------------------
# Takes a pane id (%12), not a session name, so it lands on the exact agent
# even when a session holds several. Everything downstream of the picker
# addresses agents this way: pane and window ids survive `renumber-windows`,
# where `session:2.1` does not.
#
# $TMUX_AGENT_CLIENT is the tty of the client that opened the picker, set by
# tmux-agent-pick.sh. Without it a popup switches SOME client, not necessarily
# yours — a popup has no $TMUX_PANE for tmux to resolve "current client" from.
# It's unset for a plain `ts` at a prompt, where the calling pane answers that
# question by itself.
#
# ⚠️  Two queries rather than one tab-split read, here and in the two functions
# below. `read x y < <(tmux …)` is a SYNTAX ERROR under /bin/sh — bash disables
# process substitution when invoked as sh — and `tmux run-shell` runs its command
# under sh. One `< <(…)` anywhere in this file makes sourcing it from run-shell
# fail at that line and silently lose every function defined after it. Verified:
# a stray one left `_t_agent_rows` undefined, so the status line and the picker
# both reported zero agents.
_t_focus() {
  local pane="$1" session win client from
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  [ -n "${session:-}" ] || { echo "no such pane: $pane" >&2; return 1; }

  tmux select-window -t "$win" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null

  client="${TMUX_AGENT_CLIENT:-}"

  # Called from a pane (`ts`, or a script) rather than from the picker: the
  # client that should move is the one watching the session we're leaving. Ask
  # for it by name instead of letting a bare switch-client guess — when nothing
  # is attached to this session, tmux's guess is "some other terminal window",
  # and it drags that one off to the agent instead.
  if [ -z "$client" ] && [ -n "${TMUX_PANE:-}" ]; then
    from=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
    [ -n "$from" ] && client=$(tmux list-clients -t "=$from" -F '#{client_tty}' 2>/dev/null | head -1)
  fi

  if [ -n "$client" ]; then
    tmux switch-client -c "$client" -t "=$session"
  elif [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$session"
  else
    tmux attach -t "=$session"
  fi
}

# _t_client_session — the session the client we're acting for is looking at.
# Same trap as _t_focus: `#{client_session}` with no -c resolves against a
# client picked at random once you're inside a popup.
_t_client_session() {
  if [ -n "${TMUX_AGENT_CLIENT:-}" ]; then
    tmux display-message -c "$TMUX_AGENT_CLIENT" -p '#{client_session}' 2>/dev/null
  else
    tmux display-message -p '#{client_session}' 2>/dev/null
  fi
}

# Running a different agent CLI: override T_AUTOSTART. `local` is what scopes it —
# bash's dynamic scoping means `t` sees the override, and it's gone when the
# wrapper returns. Define as many of these as you have tools:
#
#   ta2() { local T_AUTOSTART='aider'; t "$@"; }
#   tc()  { local T_AUTOSTART='codex'; t "$@"; }
#
# The window gets named after the command, so `ta2 x` gives you a window called
# "aider" rather than "claude".

# ---------------------------------------------------------------------------
# tl — list sessions
# ---------------------------------------------------------------------------
# ● = attached, · = detached (detached is the normal, healthy state for an
# agent you left running).
#
# Output always starts at the top of the screen, so the list lands in the same
# place every time and you read it without hunting.
#
# Deliberately NOT `clear`: ncurses emits the E3 capability where terminfo
# defines it, which wipes scrollback — and with history-limit at 100000 that
# scrollback is the whole point. Homing the cursor and erasing forward redraws
# the visible screen and leaves history intact.
tl() {
  local out rc
  out=$(tmux ls -F '#{?session_attached,●,·}	#{session_name}	#{session_windows} win	#{?session_attached,attached,detached}' 2>/dev/null)
  rc=$?

  if [ -t 1 ]; then
    tput home 2>/dev/null
    tput ed 2>/dev/null
  fi

  [ $rc -ne 0 ] && { echo "no tmux sessions"; return 1; }
  printf '%s\n' "$out" | column -t -s '	'
}

# ---------------------------------------------------------------------------
# ta — every Claude Code agent, and what it's doing
# ---------------------------------------------------------------------------
# Status comes free: Claude Code writes "<glyph> <task>" into the pane title
# and keeps it current, so there's nothing to poll and no hook to install.
#
#   ✳  idle     — finished, or waiting on you
#   ⠂⠐ …        — working (any braille char; it's an animating spinner)
#
# A shell pane's title is just its directory — one token, no space. An agent's
# is a single-character glyph followed by the task. That's the discriminator;
# it doesn't depend on knowing which braille frames Claude cycles through.
#
# Some agent CLIs set no pane title at all. Those can be spotted by process name
# instead: set TMUX_AGENT_EXTRA_PROCS="hermes aider" to include them. Off by
# default — guessing at tools you don't run is how you get phantom rows.
# One ps snapshot for the whole sweep, since this also feeds the status line
# every 5 seconds.
#
# Each row is eight tab-separated fields:
#
#   1 glyph   2 status   3 pane_id   4 window_id
#   5 session   6 window name   7 cwd   8 task
#
# Fields 3-4 are what every action targets. They're ids (%12, @7), not
# `session:2.1` coordinates, because `renumber-windows on` reshuffles indexes
# the moment a window dies — a stale index kills the wrong agent, a stale id
# just fails. Fields 5-7 exist so callers can label a row, spawn a sibling in
# the same folder, and decide whether killing an agent should take its session
# with it, without re-querying tmux per row.
_t_agent_rows() {
  local s pid pane win wname cwd title first extra_pids entry waitdir
  extra_pids=""
  if [ -n "${TMUX_AGENT_EXTRA_PROCS:-}" ]; then
    # "pid:name", so the row can say which tool it found. The regex keeps the
    # path boundary of the original: /usr/local/bin/aider matches, "my-aider-notes"
    # does not.
    extra_pids=" $(ps -eo ppid=,args= 2>/dev/null | awk -v names="$TMUX_AGENT_EXTRA_PROCS" '
        BEGIN { n = split(names, a, /[ ,]+/) }
        { for (i = 1; i <= n; i++) if ($0 ~ ("/" a[i] "( |$)")) { print $1 ":" a[i]; next } }
      ' | tr '\n' ' ')"
  fi

  # Claude Code renders ✳ both when it's finished and when it's sitting waiting
  # on you. Its hooks drop a marker here to tell those apart — see
  # scripts/claude-status-hook.sh.
  waitdir="$HOME/.cache/tmux-agent-status"

  tmux list-panes -a -F '#{session_name}	#{pane_pid}	#{pane_id}	#{window_id}	#{window_name}	#{pane_current_path}	#{pane_title}' 2>/dev/null \
  | while IFS=$'\t' read -r s pid pane win wname cwd title; do
      # --- Claude Code: status is in the pane title ---
      first="${title%% *}"
      if [ "$title" != "$first" ] && [ ${#first} -eq 1 ]; then
        case "$first" in
          "✳")
            if [ -f "$waitdir/${pane#%}.waiting" ]; then
              _t_row ◆ waiting "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }"
            else
              _t_row ○ idle "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }"
            fi
            ;;
          "◆") _t_row ◆ waiting "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" ;;
          *)   _t_row ● working "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" ;;
        esac
        continue
      fi

      # --- An agent with no title: detected by process name, so it's worth
      # showing, but we can't claim to know its state.
      for entry in $extra_pids; do
        case "$entry" in
          "$pid":*) _t_row ◇ running "$pane" "$win" "$s" "$wname" "$cwd" "${entry#*:}" ;;
        esac
      done
    done
}

# One printf for the row layout, so adding a field means editing one line.
_t_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

# _t_agent_display — _t_agent_rows with a ready-to-print label attached:
#
#   1 pane_id   2 session   3 cwd   4 glyph   5 status   6 label   7 task
#
# The label is the bare session name, or "session:window" once that session
# holds more than one agent — which happens the moment you spawn a sibling with
# `ts`. Without that, two agents in one folder are indistinguishable in the
# picker. Truncated to 30 columns so a long name can't push the task column off
# the popup.
#
# Shared by `ta` and the picker so both name agents identically.
_t_agent_display() {
  _t_agent_rows | awk -F'\t' '
    { g[NR]=$1; st[NR]=$2; p[NR]=$3; s[NR]=$5; wn[NR]=$6; c[NR]=$7; t[NR]=$8; n[$5]++ }
    END {
      for (i = 1; i <= NR; i++) {
        label = (n[s[i]] > 1) ? s[i] ":" wn[i] : s[i]
        if (length(label) > 30) label = substr(label, 1, 29) "…"
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", p[i], s[i], c[i], g[i], st[i], label, t[i]
      }
    }'
}

ta() {
  local out
  out=$(_t_agent_display | cut -f4-)

  if [ -t 1 ]; then
    tput home 2>/dev/null
    tput ed 2>/dev/null
  fi

  [ -z "$out" ] && { echo "no agents running"; return 1; }
  printf '%s\n' "$out" | column -t -s '	'
}

# ---------------------------------------------------------------------------
# ts [NAME] — a second agent alongside this one, same folder
# ---------------------------------------------------------------------------
# The "I want a second Claude on this same checkout" command. A new *window* in
# the current session rather than a split pane: two agents side by side in one
# window is unreadable, and a window gets its own activity dot in the status
# bar. Ctrl+b n / Ctrl+b p moves between them.
#
# Same folder, deliberately — that's the whole point. It does not create or
# touch anything on $TMUX_SESSION_PATH.
ts() {
  if [ -z "${TMUX:-}" ]; then
    echo "ts: run this from inside a tmux session (or use: t NAME)" >&2
    return 2
  fi
  _t_agent_alongside "${TMUX_PANE:-}" "${1:-}"
}

# _t_agent_alongside PANE [NAME] — spawn an agent beside PANE, in PANE's cwd.
# Prints the new pane's id. Focuses it too, since you asked for it.
_t_agent_alongside() {
  local ref="$1" name="${2:-}" session cwd base win pane

  session=$(tmux display-message -p -t "$ref" '#{session_name}' 2>/dev/null)
  cwd=$(tmux display-message -p -t "$ref" '#{pane_current_path}' 2>/dev/null)
  [ -n "${session:-}" ] || { echo "no such pane: $ref" >&2; return 1; }
  [ -n "${cwd:-}" ] || cwd="$HOME"

  base="$name"
  if [ -z "$base" ]; then
    base="${T_AUTOSTART%% *}"
    base="${base##*/}"
  fi
  base="${base##*/}"
  [ -n "$base" ] || base=agent

  win=$(_t_uniq_window "$session" "$base")
  pane=$(tmux new-window -t "=$session" -n "$win" -c "$cwd" -P -F '#{pane_id}') || return 1
  [ -n "$T_AUTOSTART" ] && tmux send-keys -t "$pane" "$T_AUTOSTART" Enter

  _t_focus "$pane" >/dev/null 2>&1
  printf '%s\n' "$pane"
}

# _t_uniq_window SESSION BASE — BASE, or BASE2/BASE3/… if that name is taken.
# Window names are how you tell siblings apart in the status bar and in the
# picker's label, so two windows called "claude" defeats the point.
_t_uniq_window() {
  local session="$1" base="$2" existing cand n=2
  existing=$'\n'$(tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null)$'\n'
  cand="$base"
  while [ "${existing/$'\n'$cand$'\n'/}" != "$existing" ]; do
    cand="$base$n"
    n=$((n + 1))
    [ "$n" -gt 99 ] && break
  done
  printf '%s\n' "$cand"
}

# _t_kill_agent PANE — kill one agent, taking as little else with it as possible
#
# Scope escalates only as far as it has to:
#   the pane, if its window holds other panes (a shell you split off)
#   the window, if the session holds other agents
#   the session, if this was its only agent — that's the `t NAME` case, where
#     the leftover shell window is scaffolding, not work
_t_kill_agent() {
  local pane="$1" session win agents panes
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  [ -n "${session:-}" ] || { echo "no such pane: $pane" >&2; return 1; }

  # Least destructive first. A pane you split off beside the agent is something
  # you set up on purpose — a tailed log, a dev server — so it outlives the
  # agent even when that agent was the session's last.
  panes=$(tmux list-panes -t "$win" -F x 2>/dev/null | wc -l | tr -d ' ')
  if [ "${panes:-1}" -gt 1 ]; then
    tmux kill-pane -t "$pane"
    return
  fi

  agents=$(_t_agent_rows | awk -F'\t' -v s="$session" '$5 == s' | wc -l | tr -d ' ')
  if [ "${agents:-0}" -gt 1 ]; then
    tmux kill-window -t "$win"
  else
    tmux kill-session -t "=$session"
  fi
}

# ---------------------------------------------------------------------------
# tw — every pane across every session, and what's running in it
# ---------------------------------------------------------------------------
# The "where did I leave that agent?" command. Answers it without attaching to
# each session in turn and looking. The command column is the real process, so
# a wedged pane still shows what it's stuck on.
tw() {
  local out
  out=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{window_name}	[#{pane_current_command}]	#{pane_current_path}' 2>/dev/null) \
    || { echo "no tmux sessions"; return 1; }
  printf '%s\n' "$out" | column -t -s '	'
}

# ---------------------------------------------------------------------------
# tk SESSION — kill one session
# ---------------------------------------------------------------------------
# Deliberately no kill-all/kill-server alias. Losing running agents is the
# exact failure this whole setup exists to prevent; that one stays a thing you
# type out in full.
tk() {
  if [ -z "$1" ]; then
    echo "usage: tk SESSION   (list them with: tl)" >&2
    return 2
  fi
  tmux kill-session -t "=$1"
}

# ---------------------------------------------------------------------------
# td — detach, leaving everything running
# ---------------------------------------------------------------------------
# Same as Ctrl+b d, for when your hands are already on the command line.
alias td='tmux detach'

# ---------------------------------------------------------------------------
# Completion — bash only
# ---------------------------------------------------------------------------
# `complete` and COMP_WORDS are bash. Under zsh everything above still works;
# this block is simply skipped rather than erroring on load.
if [ -n "${BASH_VERSION:-}" ]; then
# `tk` can only kill something that's running, so it completes live sessions.
_tmux_session_names() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=( $(compgen -W "$(tmux ls -F '#{session_name}' 2>/dev/null)" -- "$cur") )
}
complete -F _tmux_session_names tk

# `t` completes live sessions AND every folder on TMUX_SESSION_PATH, because
# that's exactly the set of names it can resolve without creating anything.
# Completing only live sessions would hide the folders you'd most want to
# reattach to.
_t_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}" root d name
  local -a roots
  local -a names=()

  # Only the session-name argument.
  [ "$COMP_CWORD" -gt 1 ] && return 0

  # A herestring, not `done < <(tmux ls …)`: process substitution is a syntax
  # error under /bin/sh, and one anywhere in this file breaks sourcing it from
  # `tmux run-shell`. It failed here quietly for a while — this is the last
  # function in the file, so everything above it still got defined.
  while IFS= read -r name; do
    [ -n "$name" ] && names+=( "$name" )
  done <<< "$(tmux ls -F '#{session_name}' 2>/dev/null)"

  IFS=: read -ra roots <<< "$TMUX_SESSION_PATH"
  for root in "${roots[@]}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for d in "$root"/*/; do
      [ -d "$d" ] || continue        # no matches: the glob came back unexpanded
      name="${d%/}"
      names+=( "${name##*/}" )
    done
  done

  [ ${#names[@]} -eq 0 ] && return 0

  COMPREPLY=( $(compgen -W "$(printf '%s\n' "${names[@]}" | sort -u)" -- "$cur") )
}
complete -F _t_complete t
fi
