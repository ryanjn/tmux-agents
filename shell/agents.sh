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

TMUX_AGENTS_VERSION="0.2.4"

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
  local session="$1" dir="${2:-}" win1 pane created win_id

  case "$session" in
    "")   echo "t: session name can't be empty" >&2; return 2 ;;
    */*)  echo "t: session name can't contain '/'" >&2; return 2 ;;
    -*)   echo "t: session name can't start with '-'" >&2; return 2 ;;
  esac

  if [ -z "$dir" ]; then
    dir=$(_t_workdir "$session") \
      || { echo "t: could not create a working directory for '$session'" >&2; return 1; }
  fi

  # The first window runs the agent; the second is a plain shell in the same
  # directory, one keystroke away (Ctrl+b n). Named explicitly because Claude Code
  # renames the window to its own version string otherwise.
  # Name window 1 after whatever it runs, so a T_AUTOSTART override gets a window
  # named after its own tool rather than "claude".
  win1="${T_AUTOSTART%% *}"
  win1="${win1##*/}"
  [ -n "$win1" ] || win1=shell

  _t_session_notes "$dir" "$session" "$win1"

  # ⚠️  Capture the WINDOW ID, don't assume the agent window is index 1. With
  # tmux's default base-index of 0 the agent is window 0 and the shell is window 1,
  # so `select-window -t "=$session:1"` drops you on the shell — the wrong window,
  # silently. Ids don't care how anyone has base-index set.
  created=$(tmux new-session -d -s "$session" -c "$dir" -n "$win1" \
    -P -F '#{pane_id} #{window_id}') || return 1
  pane="${created%% *}"
  win_id="${created##* }"
  [ -n "$pane" ] || return 1
  tmux new-window -t "=$session" -n shell -c "$dir"
  tmux select-window -t "$win_id"

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
# tmv NEW — rename this agent
# ---------------------------------------------------------------------------
# The session name is the label everywhere: the picker, `ta`, the status line, the
# jump queue. An agent that started as `scratch` and turned into something real is
# a thing you can no longer find, so renaming is a legibility fix, not a nicety.
#
# `tmv` and not `tr`: tr(1) is a command people actually use, and shadowing it
# would be rude. See the collision warning at the top of this file.
tmv() {
  if [ -z "${TMUX:-}" ]; then
    echo "tmv: run this from inside the session you want to rename" >&2
    return 2
  fi
  if [ -z "${1:-}" ]; then
    echo "usage: tmv NEW-NAME" >&2
    return 2
  fi
  _t_rename_session "$(tmux display-message -p '#{session_name}')" "$1"
}

# _t_rename_session OLD NEW — rename, and keep the folder's provenance honest.
#
# The FOLDER is deliberately left alone. Moving it out from under a running agent
# would leave its cwd pointing at an inode with a different name — every absolute
# path it has already written down (in its own notes, a scratch dir, a git remote)
# would rot, and it would have no way to notice. A stale folder name is a much
# smaller problem than a silently wrong one.
_t_rename_session() {
  local old="$1" new="$2" dir

  case "$new" in
    "")   echo "rename: new name can't be empty" >&2; return 2 ;;
    */*)  echo "rename: name can't contain '/'" >&2; return 2 ;;
    -*)   echo "rename: name can't start with '-'" >&2; return 2 ;;
  esac
  [ "$old" = "$new" ] && return 0

  if tmux has-session -t "=$new" 2>/dev/null; then
    echo "rename: '$new' is already a session" >&2
    return 1
  fi

  dir=$(tmux list-panes -s -t "=$old" -F '#{pane_current_path}' 2>/dev/null | head -1)
  tmux rename-session -t "=$old" "$new" || return 1

  # Only touch a CLAUDE.md we recognise as ours, and only the identity lines. An
  # agent may have rewritten the rest of that file, and it owns it.
  if [ -n "$dir" ] && [ -f "$dir/CLAUDE.md" ] && grep -q '^# Agent session: ' "$dir/CLAUDE.md" 2>/dev/null; then
    # %% as the delimiter, not | — that table row is full of pipes. Session
    # names are sanitised to [A-Za-z0-9._-], so %% can never appear in one.
    # The comments go ABOVE: a comment between backslash-continued lines
    # silently cuts the command in half.
    _t_sed_inplace "$dir/CLAUDE.md" \
      -e "s%^# Agent session: .*%# Agent session: $new%" \
      -e "s%^| Session | \`$old\` |%| Session | \`$new\` |%"
    printf '\n_Renamed from `%s` to `%s` on %s._\n' \
      "$old" "$new" "$(date '+%Y-%m-%d %H:%M')" >> "$dir/CLAUDE.md"
  fi
}

# sed -i takes an argument on BSD and refuses one on GNU. One wrapper beats
# remembering which machine you are on.
_t_sed_inplace() {
  local f="$1"; shift
  if sed --version >/dev/null 2>&1; then
    sed -i "$@" "$f"
  else
    sed -i '' "$@" "$f"
  fi
}

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
#   5 session   6 window name   7 cwd   8 task   9 seconds waiting
#   10 seconds since it last printed anything   11 pane pid
#
# Field 9 is empty unless the agent is waiting on you. Raw seconds, not "6m": the
# jump-to-next-waiting binding sorts on it, and formatting is display's problem.
#
# Field 10 comes from tmux's own #{window_activity}, so "how long has this been
# silent" costs nothing to track. It's the only thing that separates an agent
# thinking hard from one that wedged half an hour ago — the spinner can't.
#
# Field 11 is the pane's process, which _t_agent_display uses to count how many
# processes the agent has spawned underneath it.
#
# Fields 3-4 are what every action targets. They're ids (%12, @7), not
# `session:2.1` coordinates, because `renumber-windows on` reshuffles indexes
# the moment a window dies — a stale index kills the wrong agent, a stale id
# just fails. Fields 5-7 exist so callers can label a row, spawn a sibling in
# the same folder, and decide whether killing an agent should take its session
# with it, without re-querying tmux per row.
_t_agent_rows() {
  local s pid pane win wname cwd title act silent first extra_pids entry waitdir waited
  # One clock read for the whole sweep. The while loop below runs in a pipeline
  # subshell, which inherits this.
  local _T_NOW
  _T_NOW=$(date +%s 2>/dev/null)
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

  tmux list-panes -a -F '#{session_name}	#{pane_pid}	#{pane_id}	#{window_id}	#{window_name}	#{pane_current_path}	#{pane_title}	#{window_activity}' 2>/dev/null \
  | while IFS=$'\t' read -r s pid pane win wname cwd title act; do
      # Seconds since this window last produced output.
      silent=""
      case "${act:-}" in
        ''|*[!0-9]*) ;;
        *) [ -n "${_T_NOW:-}" ] && silent=$(( _T_NOW - act )) ;;
      esac
      # --- Claude Code: status is in the pane title ---
      first="${title%% *}"
      if [ "$title" != "$first" ] && [ ${#first} -eq 1 ]; then
        case "$first" in
          "✳")
            if [ -f "$waitdir/${pane#%}.waiting" ]; then
              waited=$(_t_waited_for "$waitdir/${pane#%}.waiting")
              _t_row ◆ waiting "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" "$waited" "$silent" "$pid"
            else
              _t_row ○ idle "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" "" "$silent" "$pid"
            fi
            ;;
          # A tool publishing ◆ itself, with no marker file to date it.
          "◆") _t_row ◆ waiting "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" \
                 "$(_t_waited_for "$waitdir/${pane#%}.waiting")" "$silent" "$pid" ;;
          *)   _t_row ● working "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" "" "$silent" "$pid" ;;
        esac
        continue
      fi

      # --- An agent with no title: detected by process name, so it's worth
      # showing, but we can't claim to know its state.
      for entry in $extra_pids; do
        case "$entry" in
          "$pid":*) _t_row ◇ running "$pane" "$win" "$s" "$wname" "$cwd" "${entry#*:}" "" "$silent" "$pid" ;;
        esac
      done
    done
}

# One printf for the row layout, so adding a field means editing one line.
_t_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

# _t_context_tokens PANE CWD — how much context that agent is currently carrying,
# in tokens. Empty when it can't be known, which is often, and that's fine.
#
# Claude Code records per-turn usage in its transcript, so the last assistant turn
# tells you the size of the prompt it just sent:
#
#     input_tokens + cache_creation_input_tokens + cache_read_input_tokens
#
# ⚠️  TOKENS, NOT A PERCENTAGE, on purpose. The transcript records the model as
# "claude-opus-5" whether it is the 200k or the 1M variant, so the denominator is
# genuinely unknowable from here — a percentage would be a confident guess, and
# wrong by 5x for anyone on a 1M model. Set TMUX_AGENT_CTX_WINDOW if all your
# agents share a window and you want percentages instead.
#
# ⚠️  Reads Claude Code's on-disk transcript, which is not a public interface. It
# is therefore written to fail closed: anything unexpected yields an empty string
# and the column simply disappears.
_t_context_tokens() {
  local pane="$1" cwd="$2" marker f dir n cache mtime cached_mtime cached_tokens tokens

  # Exact route: the hook records which transcript belongs to which pane. Two
  # agents sharing a folder (a `ts` sibling) can only be told apart this way.
  marker="$HOME/.cache/tmux-agent-status/${pane#%}.transcript"
  if [ -f "$marker" ]; then
    f=$(cat "$marker" 2>/dev/null)
  fi

  if [ -z "${f:-}" ] || [ ! -f "$f" ]; then
    # Fallback for agents that started before the hook learned to record it:
    # Claude Code names the directory after the cwd, with / turned into -.
    [ -n "$cwd" ] || return 0
    dir="$HOME/.claude/projects/$(printf '%s' "$cwd" | tr '/' '-')"
    [ -d "$dir" ] || return 0
    # Newest transcript in that folder — NOT "one modified recently". An agent
    # waiting on you for five hours hasn't written a line in five hours, and it is
    # the one you most want this number for.
    #
    # Whether this folder is unambiguous is _t_context_map's problem: it is the
    # only place that knows how many *live agents* share a cwd.
    f=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  fi
  [ -n "$f" ] && [ -f "$f" ] || return 0

  # Cached against the transcript's mtime. These files reach tens of megabytes and
  # this runs for every agent on every refresh; without the cache a six-agent
  # sweep cost 326ms, which is far too much to spend on a column.
  cache="$HOME/.cache/tmux-agent-status/${pane#%}.ctx"
  mtime=$(stat -f %m "$f" 2>/dev/null) || mtime=$(stat -c %Y "$f" 2>/dev/null) || mtime=""
  if [ -n "$mtime" ] && [ -f "$cache" ]; then
    IFS=' ' read -r cached_mtime cached_tokens < "$cache" 2>/dev/null
    if [ "$cached_mtime" = "$mtime" ] && [ -n "${cached_tokens:-}" ]; then
      printf '%s' "$cached_tokens"
      return 0
    fi
  fi

  # Only the tail: these files reach tens of megabytes. Sidechain entries are
  # subagent turns — their usage is not the main thread's context.
  # LC_ALL=C so awk treats the input as bytes: `tail -c` cuts mid-character, and
  # macOS awk aborts on the resulting invalid UTF-8 with a screenful of the
  # offending line. Everything matched here is ASCII, so bytes are the right unit.
  # stderr is closed too — this must never be able to spray into a picker.
  tokens=$(tail -c 65536 "$f" 2>/dev/null | LC_ALL=C awk '
    /"usage":/ && !/"isSidechain":true/ { last = $0 }
    END {
      if (last == "") exit
      n = split(last, parts, "\"usage\":{")
      u = parts[n]
      # Bound it to that one object. Without this the scan runs on into
      # whatever else the line holds and sums the same fields twice — which
      # showed up as a perfectly plausible 1.4M against a 1M window.
      b = index(u, "}")
      if (b > 0) u = substr(u, 1, b - 1)
      total = 0
      while (match(u, /"(input_tokens|cache_creation_input_tokens|cache_read_input_tokens)":[0-9]+/)) {
        f = substr(u, RSTART, RLENGTH)
        sub(/.*:/, "", f)
        total += f
        u = substr(u, RSTART + RLENGTH)
      }
      if (total > 0) print total
    }' 2>/dev/null)

  [ -n "${tokens:-}" ] || return 0
  [ -n "$mtime" ] && printf '%s %s\n' "$mtime" "$tokens" > "$cache" 2>/dev/null
  printf '%s' "$tokens"
}

# _t_context_map — "PANE:TOKENS …" for every agent we can attribute confidently.
# Reads rows on stdin so the caller's single _t_agent_rows sweep is reused.
#
# ⚠️  The guard is the whole point. Two agents in the same folder (a `ts` sibling,
# or several agents started from ~/agent-projects) resolve to the same transcript
# directory, and the newest file there belongs to whichever wrote last. Left
# unguarded that reported one agent's context against another's name — two agents
# both showing 487408, which looks entirely plausible and is simply false.
#
# So: a pane with a hook-recorded transcript is always trusted, and otherwise the
# agent must be the only live one in its folder.
_t_context_map() {
  local rows dups g st pane win s wn cwd rest tok out=""
  rows=$(cat)
  [ -n "$rows" ] || return 0
  # The shared folders, computed once rather than re-counted per agent.
  dups=$'\n'$(printf '%s\n' "$rows" | awk -F'\t' '{ c[$7]++ } END { for (k in c) if (c[k] > 1) print k }')$'\n'
  while IFS=$'\t' read -r g st pane win s wn cwd rest; do
    [ -n "${pane:-}" ] || continue
    if [ ! -f "$HOME/.cache/tmux-agent-status/${pane#%}.transcript" ]; then
      case "$dups" in *$'\n'"$cwd"$'\n'*) continue ;; esac
    fi
    tok=$(_t_context_tokens "$pane" "$cwd")
    [ -n "$tok" ] && out="$out$pane:$tok "
  done <<< "$rows"
  printf '%s' "$out"
}

# _t_proc_counts — "PID:N PID:N …": how many processes each pane has underneath it.
#
# An agent that has fanned out is invisible today. The preview says "Running 1
# shell command" while a thread pool spawns hundreds of short-lived processes —
# which is exactly how an afternoon of macOS permission dialogs starts, and how a
# bulk operation on something important goes unnoticed until it's done.
#
# One ps snapshot, then walk each process up to its pane. Deliberately NOT part of
# _t_agent_rows: that feeds the status line every few seconds and should stay to a
# single tmux call.
_t_proc_counts() {
  local panes
  panes=$(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
  [ -n "$panes" ] || return 0
  ps -axo pid=,ppid= 2>/dev/null | awk -v panes="$panes" '
    BEGIN { n = split(panes, P, " "); for (i = 1; i <= n; i++) if (P[i] != "") want[P[i]] = 1 }
    { parent[$1] = $2 }
    END {
      for (p in parent) {
        # Walk up from the parent, so a pane never counts itself. The depth cap is
        # a guard against a cycle in a truncated ps snapshot, not a real limit.
        c = parent[p]; d = 0
        while (c != "" && c != 1 && d < 40) {
          if (c in want) { cnt[c]++; break }
          c = parent[c]; d++
        }
      }
      out = ""
      for (w in want) out = out w ":" (w in cnt ? cnt[w] : 0) " "
      print out
    }'
}

# _t_waited_for FILE — seconds since FILE was last written; empty if it's not
# there. The waiting marker is written once, when the agent starts waiting, so its
# mtime is the timestamp and there's nothing extra to record.
#
# stat's flags differ by platform and neither build accepts the other's.
_t_waited_for() {
  local f="$1" m
  [ -f "$f" ] || return 0
  m=$(stat -f %m "$f" 2>/dev/null) || m=$(stat -c %Y "$f" 2>/dev/null) || return 0
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "${_T_NOW:-}" ] || return 0
  printf '%s' "$(( _T_NOW - m ))"
}

# _t_agent_display — _t_agent_rows with a ready-to-print label attached:
#
#   1 pane_id   2 session   3 cwd   4 glyph   5 status   6 label   7 task   8 age
#   9 process count, but only when it's high enough to be worth saying
#   10 context carried, in tokens ("730k") — or a percentage if you set
#      TMUX_AGENT_CTX_WINDOW, and empty when it can't be attributed confidently
#
# Field 8 is "how long has it been like this": time waiting for an agent that's
# waiting on you, time since it last printed anything otherwise. Both answer the
# same question — is this where I left it? — and the status word beside it says
# which one you're reading ("waiting 32m", "working 8m", "idle 2h").
#
# The label is the bare session name, or "session:window" once that session
# holds more than one agent — which happens the moment you spawn a sibling with
# `ts`. Without that, two agents in one folder are indistinguishable in the
# picker. Truncated to 30 columns so a long name can't push the task column off
# the popup.
#
# Rows come out ordered as a WORK QUEUE, not alphabetically: waiting first (longest
# waiting at the top), then working, then idle, alphabetical within each. A ◆
# sitting at the bottom of five rows is the routing failure this tool exists to fix.
#
# Longest-waiting-first is what keeps the list honest against `prefix + j`, which
# jumps to exactly that agent: the top row is always the one the key would take
# you to. Two orderings that disagree would be worse than either alone.
#
# Sorting happens in `sort`, not awk: the awk that ships with macOS has no asort().
# So awk emits two leading sort keys, sort orders on them, and cut drops them.
#
# Shared by `ta` and the picker so both name and order agents identically.
_t_agent_display() {
  local rows procs ctx
  # One sweep, shared by all three enrichments.
  rows=$(_t_agent_rows)
  [ -n "$rows" ] || return 0
  procs=$(_t_proc_counts)
  ctx=$(printf '%s\n' "$rows" | _t_context_map)
  printf '%s\n' "$rows" | awk -F'\t' -v procs="$procs" -v ctx="$ctx" \
      -v busy="${TMUX_AGENT_BUSY_PROCS:-8}" -v window="${TMUX_AGENT_CTX_WINDOW:-0}" '
    # One place to add a state. Anything unknown sorts last rather than vanishing.
    BEGIN {
      rank["waiting"] = 0; rank["working"] = 1; rank["idle"] = 2; rank["running"] = 3
      # k, not n: n is the per-session row counter further down, and awk will not
      # let you use a name as both a scalar and an array.
      k = split(procs, P, " ")
      for (i = 1; i <= k; i++) if (split(P[i], kv, ":") == 2) pcount[kv[1]] = kv[2]
      k = split(ctx, C, " ")
      for (i = 1; i <= k; i++) if (split(C[i], kv, ":") == 2) ctok[kv[1]] = kv[2]
    }

    # Tokens by default, because the denominator is not knowable — see
    # _t_context_tokens. A percentage only when you have told us the window.
    function ctxcol(tok) {
      if (tok == "") return ""
      if (window + 0 > 0) return int(tok * 100 / window) "%"
      if (tok >= 1000) return int(tok / 1000) "k"
      return tok
    }

    # Compact on purpose: this column shares a line with the task.
    function age(sec) {
      if (sec == "") return ""
      if (sec < 60)   return sec "s"
      if (sec < 3600) return int(sec / 60) "m"
      return int(sec / 3600) "h"
    }

    { g[NR]=$1; st[NR]=$2; p[NR]=$3; s[NR]=$5; wn[NR]=$6; c[NR]=$7; t[NR]=$8; a[NR]=$9
      sil[NR]=$10; pp[NR]=$11; n[$5]++ }
    END {
      for (i = 1; i <= NR; i++) {
        label = (n[s[i]] > 1) ? s[i] ":" wn[i] : s[i]
        if (length(label) > 30) label = substr(label, 1, 29) "…"
        r = (st[i] in rank) ? rank[st[i]] : 9
        # Waiting time for an agent that is waiting on you; silence otherwise.
        shown = (st[i] == "waiting" && a[i] != "") ? a[i] : sil[i]
        # Only shown when it means something: a healthy agent runs a couple of
        # children, a fan-out runs dozens.
        np = (pp[i] in pcount) ? pcount[pp[i]] : 0
        procs_col = (np + 0 >= busy + 0) ? "⚙" np : ""
        printf "%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
               r, (a[i] == "" ? 0 : a[i]), tolower(label),
               p[i], s[i], c[i], g[i], st[i], label, t[i], age(shown), procs_col,
               ctxcol(p[i] in ctok ? ctok[p[i]] : "")
      }
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2nr -k3,3 | cut -f4-
}

ta() {
  local out
  # "waiting 6m" rather than a separate column: it belongs with the state, and a
  # column of its own would push the task off a narrow terminal.
  # Everything about "what state is this in" folded into one column. A column of
  # its own would be empty for any agent we can't attribute, and `column -t`
  # collapses empty fields — which slides every later column left on that row.
  out=$(_t_agent_display | awk -F'\t' '
    { st = $5 ($8 != "" ? " " $8 : "") ($9 != "" ? " " $9 : "") ($10 != "" ? " " $10 : "")
      printf "%s\t%s\t%s\t%s\n", $4, st, $6, $7 }')

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
