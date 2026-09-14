# shellcheck shell=bash
# ---------------------------------------------------------------------------
# quick-agents.sh — `tq`, agents you throw away
# ---------------------------------------------------------------------------
# `t NAME` is built to be permanent: it resolves or creates ~/agent-projects/NAME
# and drops a provenance CLAUDE.md in it so the next agent to land there knows
# what the folder is. That is right for work you come back to, and wrong for the
# 80% of asks that are one question and an answer — those leave a folder whose
# entire content is the note explaining that the folder exists.
#
# `tq` is the same session, inverted: disposal is the default and keeping is the
# thing you have to ask for.
#
#   tq [NAME]        start a quick agent in a scratch dir (nothing in ~/agent-projects)
#   tq done [NAME]   end it — removes the scratch dir, or offers to keep the work
#   tq keep [NAME]   promote the scratch dir into a real ~/agent-projects/NAME
#   tq ls            quick agents, live and orphaned
#   tq gc [-n|-y]    sweep orphaned scratch dirs and artifact-only project folders
#
# The scratch dir lives under ~/.cache, NOT $TMPDIR: macOS purges $TMPDIR on its
# own schedule, which would delete a session's working files out from under a
# running agent. ~/.cache survives until something here removes it, which also
# gives `tq gc` something to find after a crash or a reboot.
#
# Disposal happens on three paths, so no single one has to be reliable:
#   1. `tq done`   — the deliberate one, and the only one that can prompt.
#   2. a tmux session-closed hook — catches killing the agent from the picker
#      (Ctrl+b a, ctrl-x) or anywhere else. Unattended, so it only ever removes
#      a scratch dir with nothing authored in it.
#   3. `tq gc`     — catches crashes and reboots, where no hook ever ran.
#
# Requires tmux-aliases.sh: `tq` builds its session through `_t_new_session` so a
# quick agent has the identical layout, window names, and autostart as a real one.
# ---------------------------------------------------------------------------


# Where this repo lives (set already if agents.sh was sourced first).
: "${_TA_SHELL:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${_TA_BIN:=${TMUX_AGENTS_HOME:-$(cd "$_TA_SHELL/.." && pwd)}/bin}"

: "${QA_ROOT:=${XDG_CACHE_HOME:-$HOME/.cache}/quick-agents}"
: "${QA_PROJECTS:=$HOME/agent-projects}"
: "${QA_REAPER:=$_TA_BIN/quick-agent-reap.sh}"

# ---------------------------------------------------------------------------
# _tq_authored DIR — entries in DIR that are yours rather than machine-written
# ---------------------------------------------------------------------------
# Delegated to the reaper script rather than reimplemented, because the tmux
# hook can only call the script and the two must never disagree about what
# counts as work. Prints a number; "0" means disposable.
_tq_authored() {
  local dir="$1"
  [ -x "$QA_REAPER" ] || { printf '1\n'; return 0; }   # unknown ⇒ assume work
  "$QA_REAPER" count "$dir" 2>/dev/null || printf '1\n'
}

# _tq_running NAME — is a tmux session called NAME alive? Exact match, since
# `has-session -t foo` prefix-matches and would find "foo-2".
_tq_running() { tmux has-session -t "=$1" 2>/dev/null; }

# _tq_current — the scratch NAME of the session we're being run from, if any.
# Lets `tq done` and `tq keep` take no argument in the common case.
_tq_current() {
  local s
  [ -n "${TMUX:-}" ] || return 1
  s=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
  case "$s" in
    q-*) printf '%s\n' "${s#q-}" ;;
    *) return 1 ;;
  esac
}

# _tq_validate NAME — reject names tmux or the filesystem can't round-trip.
# Mirrors _t_new_session's rules, checked here so the error names `tq` and
# arrives before we've created a directory.
_tq_validate() {
  case "$1" in
    "")    echo "tq: name can't be empty" >&2; return 2 ;;
    */*)   echo "tq: name can't contain '/'" >&2; return 2 ;;
    -*)    echo "tq: name can't start with '-'" >&2; return 2 ;;
    # tmux parses every target as session:window.pane, so a dot makes the
    # session unaddressable by name — including un-killable from the picker.
    *.*)   echo "tq: name can't contain '.' — tmux reads it as a pane index (try ${1//./-})" >&2; return 2 ;;
    done|keep|gc|ls|help)
      echo "tq: '$1' is a subcommand — pick another name" >&2; return 2 ;;
  esac
  return 0
}

# _tq_sweep_silent — reap orphaned, empty scratch dirs. No output, no prompts.
# Runs at the top of every `tq` invocation so a crashed or rebooted-away session
# doesn't leave litter for `tq gc` to have to be remembered for.
_tq_sweep_silent() {
  local d name
  [ -d "$QA_ROOT" ] || return 0
  [ -x "$QA_REAPER" ] || return 0
  for d in "$QA_ROOT"/*/; do
    [ -d "$d" ] || continue
    name="${d%/}"; name="${name##*/}"
    _tq_running "q-$name" && continue
    "$QA_REAPER" reap "${d%/}" >/dev/null 2>&1
  done
}

# ---------------------------------------------------------------------------
# _tq_scratch_notes DIR NAME — the one file a quick agent starts with
# ---------------------------------------------------------------------------
# Deliberately not the provenance note `t` writes. That one exists so a folder
# found three days later can explain itself; this one exists to tell the agent
# reading it that there will be no three days later, which changes how it should
# work — keep findings in the reply, not in files nobody will read.
#
# Written BEFORE the session starts, which is also what suppresses `t`'s note:
# _t_session_notes only writes into a directory that is completely empty, so a
# scratch dir that already has files in it is left alone. One behaviour, two
# jobs — there is no flag to keep in sync.
#
# The `quick-agent-scratch` marker line is load-bearing: it is how the reaper
# recognises this file as machine-written, so rewording the prose below is safe
# but removing that string makes every scratch dir look like it holds work.
_tq_scratch_notes() {
  local dir="$1" name="$2" started

  started=$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)

  printf '%s\n' "quick-agent-scratch $name $started" > "$dir/.quick-agent" 2>/dev/null

  # Quoted heredoc plus a sed pass: the text has `backticks` in it, and in an
  # expanding heredoc those run as command substitution while writing the file.
  sed -e "s|@@NAME@@|$name|g" -e "s|@@DIR@@|$dir|g" -e "s|@@STARTED@@|$started|g" \
    > "$dir/CLAUDE.md" 2>/dev/null <<'MD'
# Quick agent: @@NAME@@ (disposable)

<!-- quick-agent-scratch -->

This is a **scratch session**. The folder is `@@DIR@@`, outside
`~/agent-projects`, and it is deleted when the session ends. Started @@STARTED@@.

## What that means for you

- **Answer in the conversation, not in files.** Nobody will open a report you
  write here — the folder will not exist. Write files only when the file *is*
  the deliverable, or when you need scratch space to do the work.
- Anything you do write survives only if the session is promoted, and the
  promotion prompt is the user's to answer, not yours to assume.
- Don't write a summary, a notes file, or a README out of habit. That habit is
  the reason this session type exists.

## Ending it

- `tq done` — end the session. With nothing written it just disappears; with
  files written it asks whether to keep them.
- `tq keep [NEWNAME]` — promote this into a permanent `~/agent-projects/` folder
  and carry on working. Use it the moment the work turns out to be real.
MD
}

# ---------------------------------------------------------------------------
# tq [NAME] — start a quick agent
# ---------------------------------------------------------------------------
tq() {
  local sub="${1:-}"

  case "$sub" in
    done|keep|gc|ls|help) shift; _tq_"$sub" "$@"; return ;;
    -h|--help)            _tq_help; return ;;
  esac

  local name="$sub" dir session pane

  _tq_sweep_silent

  # Unnamed is the point of `tq` — you shouldn't have to name a question you're
  # about to throw away. Hex from urandom rather than $RANDOM so two agents
  # started in the same second can't collide.
  if [ -z "$name" ]; then
    name="q$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ "$name" = "q" ] && name="q$$"
  fi

  _tq_validate "$name" || return $?

  # Sourced out of order, `_t_new_session` is missing and the failure would
  # otherwise be a bare "command not found" after the scratch dir already exists.
  if ! declare -F _t_new_session >/dev/null 2>&1; then
    echo "tq: needs tmux-aliases.sh sourced first (it builds the session)" >&2
    return 1
  fi

  session="q-$name"
  dir="$QA_ROOT/$name"

  # Already running: attach, don't make a second one. Same idempotence as `t`.
  if _tq_running "$session"; then
    if [ -n "${TMUX:-}" ]; then tmux switch-client -t "=$session"
    else tmux attach -t "=$session"; fi
    return
  fi

  mkdir -p "$dir" || { echo "tq: could not create $dir" >&2; return 1; }

  # Only seed the notes into a dir we just made. Re-running `tq NAME` after the
  # session died but before it was reaped resumes the scratch dir as it was,
  # rather than overwriting a CLAUDE.md the agent may have edited.
  [ -e "$dir/.quick-agent" ] || _tq_scratch_notes "$dir" "$name"

  pane=$(_t_new_session "$session" "$dir") \
    || { echo "tq: could not create session '$session'" >&2; return 1; }

  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "=$session"
  else tmux attach -t "=$session"; fi
}

# ---------------------------------------------------------------------------
# tq done [NAME] — end a quick agent and dispose of its scratch dir
# ---------------------------------------------------------------------------
# The only disposal path that can prompt, and so the only one allowed to delete
# something you wrote. Called with no argument from inside a quick session, it
# targets that session.
_tq_done() {
  local name="${1:-}" dir session count reply

  [ -n "$name" ] || name=$(_tq_current) || {
    echo "tq done: not in a quick agent — pass a name (tq ls to list)" >&2; return 2; }

  session="q-$name"
  dir="$QA_ROOT/$name"

  [ -d "$dir" ] || { echo "tq done: no scratch dir for '$name'" >&2; return 1; }

  count=$(_tq_authored "$dir")

  if [ "$count" != "0" ]; then
    printf '%s file(s) written in %s\n' "$count" "$dir" >&2
    printf 'keep as %s/%s? [Y/n] ' "$QA_PROJECTS" "$name" >&2
    read -r reply
    case "$reply" in
      ""|y|Y|yes|YES)
        _tq_keep "$name" || return 1
        # Promoted, so the session now belongs to a real folder. Killing it
        # would be the opposite of what "keep" means — leave it running.
        return 0
        ;;
    esac
    # Discarding real files is the one genuinely irreversible thing here, so it
    # gets its own confirmation with a default of "no".
    printf 'discard %s file(s) permanently? [y/N] ' "$count" >&2
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "tq done: cancelled, nothing removed" >&2; return 1 ;;
    esac
    # The reaper refuses anything with authored files, which is the whole point
    # of it — so this one case removes the directory itself, and has to
    # re-derive the blast-radius check on its own.
    #
    # ⚠️  Both sides resolved with `pwd -P` before comparing. Comparing the
    # unresolved strings would fail to match whenever ~/.cache sits behind a
    # symlink, and a prefix test on the raw path would accept "$QA_ROOT/../..".
    local resolved root_c
    resolved=$(cd "$dir" 2>/dev/null && pwd -P)
    root_c=$(cd "$QA_ROOT" 2>/dev/null && pwd -P)
    if [ -n "$resolved" ] && [ -n "$root_c" ] && [ "$(dirname "$resolved")" = "$root_c" ]; then
      rm -rf -- "$resolved"
    else
      echo "tq done: refusing to remove '$dir' — not directly under $QA_ROOT" >&2
      return 1
    fi
  else
    "$QA_REAPER" reap "$dir" >/dev/null 2>&1
  fi

  # Last, because from inside the session this terminates the shell running it.
  _tq_running "$session" && tmux kill-session -t "=$session" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# tq keep [NEWNAME] — promote a scratch dir into a real project folder
# ---------------------------------------------------------------------------
# ⚠️  `mv` rather than copy-then-delete, on purpose. ~/.cache and ~/agent-projects
# are on the same APFS volume, so this is a rename(2): the inode doesn't change,
# and the cwd of the ALREADY RUNNING agent follows it. That is what lets you
# promote mid-conversation without restarting the agent. If the move ever
# crosses a filesystem the fallback copies, and says plainly that the running
# agent is now working in the old place.
_tq_keep() {
  local name dest_name dir dest session

  if [ -n "${1:-}" ] && [ -d "$QA_ROOT/$1" ]; then
    name="$1"; dest_name="${2:-$1}"
  else
    name=$(_tq_current) || {
      echo "tq keep: not in a quick agent — pass a name (tq ls to list)" >&2; return 2; }
    dest_name="${1:-$name}"
  fi

  dir="$QA_ROOT/$name"
  dest="$QA_PROJECTS/$dest_name"
  session="q-$name"

  [ -d "$dir" ] || { echo "tq keep: no scratch dir for '$name'" >&2; return 1; }
  _tq_validate "$dest_name" || return $?
  [ -e "$dest" ] && { echo "tq keep: $dest already exists" >&2; return 1; }
  _tq_running "$dest_name" && {
    echo "tq keep: a session called '$dest_name' is already running" >&2; return 1; }

  # Strip the ephemeral marker and note before the move: they say the folder is
  # disposable, which stops being true one line from now.
  rm -f -- "$dir/.quick-agent"
  if [ -f "$dir/CLAUDE.md" ] && grep -qF 'quick-agent-scratch' "$dir/CLAUDE.md" 2>/dev/null; then
    rm -f -- "$dir/CLAUDE.md"
  fi

  mkdir -p "$QA_PROJECTS" 2>/dev/null
  if mv -- "$dir" "$dest" 2>/dev/null; then
    :
  else
    cp -R -- "$dir" "$dest" 2>/dev/null || { echo "tq keep: could not move $dir" >&2; return 1; }
    rm -rf -- "$dir"
    echo "tq keep: copied across filesystems — the running agent is still in the old directory, restart it" >&2
  fi

  # Rename so it stops looking disposable in `ta` and the picker.
  _tq_running "$session" && tmux rename-session -t "=$session" "$dest_name" 2>/dev/null

  printf 'kept: %s\n' "$dest" >&2
  _tq_running "$dest_name" && printf 'session renamed: %s → %s\n' "$session" "$dest_name" >&2
  return 0
}

# ---------------------------------------------------------------------------
# tq ls — quick agents, live and orphaned
# ---------------------------------------------------------------------------
_tq_ls() {
  local d name count state any=0

  [ -d "$QA_ROOT" ] || { echo "no quick agents"; return 0; }

  for d in "$QA_ROOT"/*/; do
    [ -d "$d" ] || continue
    any=1
    name="${d%/}"; name="${name##*/}"
    count=$(_tq_authored "${d%/}")
    if _tq_running "q-$name"; then state="running"; else state="orphaned"; fi
    printf '%-24s %-9s %s file(s)  %s\n' "$name" "$state" "$count" "${d%/}"
  done

  [ "$any" = "1" ] || echo "no quick agents"
}

# ---------------------------------------------------------------------------
# tq gc [-n|--dry-run] [-y] — sweep both kinds of leftover folder
# ---------------------------------------------------------------------------
# Two sources, one rule. Orphaned scratch dirs are the litter `tq` itself can
# leave when a session dies without the hook firing. Artifact-only folders in
# ~/agent-projects are the older problem `tq` exists to stop creating: a folder
# whose only content is the provenance note explaining that the folder exists.
#
# Nothing is removed without showing the list first. Everything it proposes has
# an authored count of zero — see quick-agent-reap.sh for what that means and
# why it is stricter than "the note looks untouched".
_tq_gc() {
  local dry=0 yes=0 arg d name count reply n=0
  local -a targets=()

  for arg in "$@"; do
    case "$arg" in
      -n|--dry-run) dry=1 ;;
      -y|--yes) yes=1 ;;
      *) echo "tq gc: unknown option '$arg'" >&2; return 2 ;;
    esac
  done

  [ -x "$QA_REAPER" ] || { echo "tq gc: reaper not found at $QA_REAPER" >&2; return 1; }

  if [ -d "$QA_ROOT" ]; then
    for d in "$QA_ROOT"/*/; do
      [ -d "$d" ] || continue
      name="${d%/}"; name="${name##*/}"
      _tq_running "q-$name" && continue
      count=$(_tq_authored "${d%/}")
      if [ "$count" = "0" ]; then
        targets+=("${d%/}")
      else
        printf 'keeping  %-30s %s file(s) — promote with: tq keep %s\n' "$name" "$count" "$name" >&2
      fi
    done
  fi

  if [ -d "$QA_PROJECTS" ]; then
    for d in "$QA_PROJECTS"/*/; do
      [ -d "$d" ] || continue
      name="${d%/}"; name="${name##*/}"
      # A running session means it's in use whatever the folder looks like.
      _tq_running "$name" && continue
      [ "$(_tq_authored "${d%/}")" = "0" ] && targets+=("${d%/}")
    done
  fi

  n=${#targets[@]}
  [ "$n" -gt 0 ] || { echo "tq gc: nothing to remove"; return 0; }

  # A variable, not \~ — a backslash in the replacement half of ${var/#pat/str}
  # is literal, so escaping the tilde to stop expansion prints it: "\~/agent-projects".
  local tilde='~'
  printf '\n%s folder(s) with no authored files:\n\n' "$n"
  for d in "${targets[@]}"; do printf '  %s\n' "${d/#$HOME/$tilde}"; done
  printf '\n'

  [ "$dry" = "1" ] && { echo "dry run — nothing removed"; return 0; }

  if [ "$yes" != "1" ]; then
    printf 'remove all %s? [y/N] ' "$n" >&2
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) echo "cancelled, nothing removed" >&2; return 1 ;;
    esac
  fi

  local removed=0
  for d in "${targets[@]}"; do
    "$QA_REAPER" reap "$d" >/dev/null 2>&1 && removed=$((removed + 1))
  done
  printf 'removed %s of %s\n' "$removed" "$n"
}

_tq_help() {
  cat <<'TXT'
tq — agents you throw away

  tq [NAME]          start a quick agent (scratch dir, nothing in ~/agent-projects)
  tq done [NAME]     end it — removes the scratch dir, or offers to keep the work
  tq keep [NEWNAME]  promote the scratch dir into a real ~/agent-projects folder
  tq ls              quick agents, live and orphaned
  tq gc [-n] [-y]    sweep orphaned scratch dirs and artifact-only project folders
                     -n dry run, -y skip the confirmation

Started with no name, it invents one. Kill it however you like — the picker's
ctrl-x, `tmux kill-session`, closing the laptop — and the scratch dir goes with
it as long as nothing was written. If something was written, it survives until
`tq done` or `tq gc` asks you about it.
TXT
}

# ---------------------------------------------------------------------------
# session-closed hook — reap when the agent is killed from anywhere else
# ---------------------------------------------------------------------------
# Indexed slot rather than a bare `set-hook -g session-closed`, which REPLACES
# whatever else is on that hook. Index 50 leaves room either side for hooks that
# want to run before or after this one.
#
# Unattended, so quick-agent-reap.sh only ever removes a scratch dir with
# nothing authored in it. A quick agent that produced files outlives its session
# and waits for `tq done` or `tq gc`.
#
# ⚠️  QA_ROOT is baked into the hook command rather than left to the
# environment. `run-shell` executes under the tmux SERVER's environment, not the
# shell that set the hook, so a QA_ROOT you exported here would be invisible to
# it and the reaper would quietly sweep the default location instead.
# `tmux info` rather than `command -v tmux`: set-hook -g needs a running SERVER,
# not just the binary. With tmux installed and no server up — every first shell
# after a reboot — set-hook fails, and being the last command in the file it
# became the file's return status. A non-zero return from something your rc
# sources is a real footgun: under `set -e` it aborts the rest of your shell
# startup, and a prompt that shows $? greets you with an error you cannot place.
#
# Nothing is lost by skipping it. The shell that opens INSIDE the new session
# sources this file again, with a server up, and sets the hook then.
if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
  tmux set-hook -g 'session-closed[50]' \
    "run-shell -b 'QA_ROOT=\"$QA_ROOT\" QA_PROJECTS=\"$QA_PROJECTS\" \"$QA_REAPER\" session \"#{hook_session_name}\"'" \
    2>/dev/null || true
fi

# Last line on purpose: a sourced file must not hand its caller the exit status
# of whatever it happened to do last.
:
