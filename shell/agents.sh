# shellcheck shell=bash
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

TMUX_AGENTS_VERSION="0.4.5"

command -v tmux >/dev/null 2>&1 || return 0

# Where this repo lives, so the shell helpers can reach bin/. Derived from this
# file's own path, which is what makes the clone location free.
_TA_SHELL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TA_BIN="${TMUX_AGENTS_HOME:-$(cd "$_TA_SHELL/.." && pwd)}/bin"

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

# Agent CLIs that set no pane title are detected by process name instead.
# Empty by default — see TMUX_AGENT_EXTRA_PROCS in `t --help`.
: "${TMUX_AGENT_EXTRA_PROCS:=}"

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
# Checking a repo out into a new agent's folder
# ---------------------------------------------------------------------------
# An empty folder is the right default — most sessions are a scratch space for
# one question — but when the session IS a codebase, "make the folder, then go
# clone into it" is three steps with a known trap in the middle (see the CLAUDE.md
# note about `git clone URL .`). So a repo is accepted anywhere a session name
# goes, and the name falls out of the repo:
#
#   t acme/brand-console          -> session brand-console, cloned
#   t acme/brand-console pa-bug   -> session pa-bug, same repo
#   t git@github.com:foo/bar.git             -> session bar
#   t ~/Projects/brand-console               -> session brand-console, WORKTREE
#
# The last form is the one worth knowing about. Two agents pointed at one
# checkout share a working tree and a HEAD, so they overwrite each other's edits
# and fight over which branch is out. `git worktree` gives the second agent its
# own files and its own branch against the same object store — no re-clone, and
# nothing already vendored in .git gets fetched twice.
#
# Only ever into a folder that was just created empty. `_t_workdir` resolves a
# name against $TMUX_SESSION_PATH first, so a folder with anything in it is
# somebody's real work and is left alone.

# _t_is_repo_spec SPEC — true if SPEC names a repo rather than a session.
# A slash is the whole test: session names may not contain one (`t` rejects
# them, and they'd turn mkdir -p into a surprise directory tree), so anything
# with a slash was meant as a repo. URLs and bare `foo.git` cover the rest.
_t_is_repo_spec() {
  case "${1:-}" in
    ''|-*)        return 1 ;;
    *\ *)         return 1 ;;   # "notes / ideas" is a clumsy name, not a repo
    *://*|*@*:*)  return 0 ;;   # https://…, ssh://…, git@host:owner/repo
    *.git)        return 0 ;;
    */*)          return 0 ;;   # owner/repo, or any path
  esac
  return 1
}

# _t_repo_name SPEC — the session name a repo spec implies.
# Basename minus .git, then the same character rules a typed name gets.
_t_repo_name() {
  local n="${1:-}"
  while [ "$n" != "${n%/}" ]; do n="${n%/}"; done   # trailing slash on a path
  n="${n##*/}"
  n="${n##*:}"                                      # git@host:repo with no owner
  n="${n%.git}"
  # Dots included — a repo called next.js would otherwise name a session tmux
  # can never address again. See the guard in _t_new_session.
  n="${n//[^A-Za-z0-9_-]/-}"
  while [ "$n" != "${n//--/-}" ]; do n="${n//--/-}"; done
  while [ "$n" != "${n#[-.]}" ]; do n="${n#[-.]}"; done
  printf '%s' "$n"
}

# _t_workdir_new NAME — like _t_workdir, but always a FRESH folder under the first
# root, never an existing one found on the path.
#
# ⚠️  This is the one place the two must differ. `t prescriber-point` should find
# your real checkout in ~/Projects and use it — that is the whole point of the
# search path. But `t acme/acme-web` must NOT: checking a repo
# out into a folder that already holds that repo is refused, so reusing the found
# directory turned "start an agent on this repo" into an error for every repo
# already on disk, which is most of them. It is also the wrong thing to want —
# what you want there is a worktree, which _t_repo_checkout now goes and finds.
_t_workdir_new() {
  local name="$1" dir
  local -a roots
  IFS=: read -ra roots <<< "$TMUX_SESSION_PATH"

  dir="${roots[0]}/$name"
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "t: $dir already exists and has something in it — give the session its own name: t REPO NAME" >&2
    return 1
  fi
  mkdir -p "$dir" || return 1
  printf '%s\n' "$dir"
}

# _t_repo_key SPEC — a repo identity that survives how it was written.
# github.com/owner/repo, lowercased, for all of:
#
#   git@github.com:Owner/Repo.git   https://github.com/owner/repo
#   ssh://git@github.com/owner/repo Owner/Repo
#
# Comparing raw URLs does not work: the same repo is a git@ URL in one checkout's
# origin and https:// in the spec you typed, and GitHub owners are case-insensitive
# while string equality is not.
_t_repo_key() {
  local u="${1:-}"
  while [ "$u" != "${u%/}" ]; do u="${u%/}"; done
  u="${u%.git}"
  case "$u" in
    *://*)  u="${u#*://}"; u="${u#*@}" ;;           # scheme, then any user@
    *@*:*)  u="${u#*@}"; u="${u%%:*}/${u#*:}" ;;    # git@host:owner/repo
    */*/*)  ;;                                       # already host/owner/repo
    */*)    u="github.com/$u" ;;                     # owner/repo shorthand
  esac
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

# _t_repo_origin DIR — DIR's origin URL, read straight out of .git/config.
# `git remote get-url` is ~5ms of process startup and _t_repo_local_source runs
# this over every folder on the search path — ~150 of them here. The git call is
# kept only as the fallback for linked worktrees, whose .git is a file.
_t_repo_origin() {
  local url
  url=$(sed -n '/^\[remote "origin"\]/,/^\[/s/^[[:space:]]*url[[:space:]]*=[[:space:]]*//p' \
        "$1/.git/config" 2>/dev/null | head -1)
  [ -n "$url" ] || url=$(git -C "$1" --no-optional-locks remote get-url origin 2>/dev/null)
  printf '%s' "$url"
}

# _t_repo_local_source SPEC — a checkout of SPEC already on $TMUX_SESSION_PATH,
# if there is one. Prints its toplevel.
#
# Worth the look: these are private repos of real size, and cloning a second copy
# of something already on disk costs minutes and gigabytes to produce a worse
# result than the worktree it could have had.
_t_repo_local_source() {
  local spec="$1" want root d top
  local -a roots
  want=$(_t_repo_key "$spec")
  [ -n "$want" ] || return 1
  IFS=: read -ra roots <<< "$TMUX_SESSION_PATH"

  # Named the same as the repo, which is nearly always true — two stats instead
  # of a sweep of every folder you own.
  for root in "${roots[@]}"; do
    [ -n "$root" ] || continue
    d="$root/${want##*/}"
    [ -d "$d" ] || continue
    if [ "$(_t_repo_key "$(_t_repo_origin "$d")")" = "$want" ]; then
      top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && {
        printf '%s' "$top"; return 0; }
    fi
  done

  # Cloned under a different folder name. Rarer, so it pays for the sweep only
  # when the cheap answer missed.
  for root in "${roots[@]}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for d in "$root"/*/; do
      d="${d%/}"
      [ -e "$d/.git" ] || continue
      if [ "$(_t_repo_key "$(_t_repo_origin "$d")")" = "$want" ]; then
        top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] && {
          printf '%s' "$top"; return 0; }
      fi
    done
  done
  return 1
}

# _t_repo_checkout SPEC DIR NAME — put SPEC's working tree in DIR
#
# DIR has just been made by _t_workdir, so it exists and is empty. git refuses
# to clone into a directory that exists with anything in it, and `worktree add`
# refuses one that exists at all — hence the rmdir before each. Both are undone
# with mkdir on failure so the caller's dir invariant holds either way.
#
# ⚠️  The summary goes to STDERR, not stdout. `_t_new_session` returns the new
# agent's pane id on stdout and every caller captures it with `$(…)` — one line
# of chat printed there and `_t_focus` is handed "cloned owner/repo\n%168"
# instead of a pane id, and the session is created but never jumped to. Verified:
# it fails exactly that way. git's own progress goes to the terminal when there
# is one, and to a log when there isn't (the picker runs this under `run-shell`,
# which has no tty at all).
_t_repo_checkout() {
  local spec="$1" dir="$2" name="$3" src branch log n

  command -v git >/dev/null 2>&1 || { echo "t: git is not installed" >&2; return 1; }

  if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "t: $dir already has something in it — not checking out '$spec'" >&2
    return 1
  fi

  log="${TMPDIR:-/tmp}/t-checkout-$name.log"

  # Two routes to a local source, in order of directness:
  #   1. SPEC is itself a path to a checkout — `t ~/Projects/brand-console`
  #   2. SPEC is a remote we already have a clone of on $TMUX_SESSION_PATH —
  #      `t acme/acme-web` when ~/Projects/acme-web
  #      is that repo
  # Either way the answer is a worktree, not a clone.
  src=$(git -C "$spec" rev-parse --show-toplevel 2>/dev/null)
  [ -n "$src" ] || src=$(_t_repo_local_source "$spec" 2>/dev/null)
  if [ -n "$src" ]; then
    # ⚠️  A branch can only be checked out in ONE worktree — git refuses the
    # second, it doesn't share it. So a name that's been used before has to get
    # its own branch rather than reuse agent/NAME, or `t ~/Projects/x` would
    # work exactly once per repo and fail ever after.
    branch="agent/$name"
    n=2
    while git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; do
      branch="agent/$name-$n"
      n=$((n + 1))
    done

    rmdir "$dir" 2>/dev/null
    if git -C "$src" worktree add -b "$branch" "$dir" >"$log" 2>&1; then
      printf 'worktree of %s on %s\n' "${src##*/}" "$branch" >&2
      return 0
    fi
    mkdir -p "$dir"
    echo "t: could not add a worktree of $src — see $log" >&2
    return 1
  fi

  rmdir "$dir" 2>/dev/null
  case "$spec" in
    *://*|*@*:*|*.git)
      git clone "$spec" "$dir" 2>&1 | tee "$log" >&2
      ;;
    *)
      # owner/repo. gh knows the host, the protocol and your credentials, so
      # private repos work without spelling any of that out here.
      if command -v gh >/dev/null 2>&1; then
        gh repo clone "$spec" "$dir" 2>&1 | tee "$log" >&2
      else
        git clone "https://github.com/$spec.git" "$dir" 2>&1 | tee "$log" >&2
      fi
      ;;
  esac

  # ⚠️  $? is tee's. The clone's own status is ${PIPESTATUS[0]} — checking the
  # wrong one made every failed clone look like a success.
  if [ "${PIPESTATUS[0]}" -ne 0 ] || [ ! -d "$dir/.git" ]; then
    mkdir -p "$dir"
    echo "t: could not check out '$spec' — see $log" >&2
    return 1
  fi

  printf 'cloned %s\n' "$spec" >&2
}

# _t_favorite_defaults NAME — read NAME's favorite, if any, into the CALLER's
# fav_dir / repo / fav_cmd (they must be declared there; bash dynamic scoping is
# what makes this a three-line helper instead of a parser in two places). A
# target that is a directory becomes fav_dir; anything else is a repo spec.
_t_favorite_defaults() {
  local row ftarget fcmd
  row=$(_tf_resolve "$1" 2>/dev/null) || return 0
  IFS=$'\t' read -r ftarget fcmd _ <<< "$row"
  ftarget="${ftarget/#\~/$HOME}"
  if [ "$ftarget" != - ] && [ -n "$ftarget" ]; then
    if [ -d "$ftarget" ]; then fav_dir="$ftarget"; else repo="$ftarget"; fi
  fi
  [ "$fcmd" != - ] && [ -n "$fcmd" ] && fav_cmd="$fcmd"
  return 0
}

# _t_name_candidates — names you could start an agent on, newest first.
#
# Every folder on $TMUX_SESSION_PATH that has no session running. These are
# exactly the names `t NAME` would land IN rather than create fresh, which makes
# them the useful completions when naming a new agent: picking one resumes work
# in a folder that already exists, and a typo silently makes a near-duplicate.
#
# Three tab-separated fields: name, the root it lives under, and "git" when it's
# a checkout.
#
# ⚠️  Deduplicated by name, keeping the FIRST root that has it — the same
# precedence `_t_workdir` resolves with. Listing ~/agent-projects/foo and
# ~/Projects/foo as two choices would imply you can pick between them; you can't,
# the search path decides.
#
# `ls -dt` for the ordering: it sorts by mtime in one process, where stat'ing
# ~270 directories from the shell would not.
_t_name_candidates() {
  local root d name mark running label tilde='~'
  local -a roots
  IFS=: read -ra roots <<< "$TMUX_SESSION_PATH"
  running=$'\n'$(tmux list-sessions -F '#{session_name}' 2>/dev/null)$'\n'

  for root in "${roots[@]}"; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    # A variable, not \~ — a backslash in the replacement of ${var/#pat/str} is
    # literal, so escaping the tilde to stop expansion prints it: "\~/Projects".
    label="${root/#$HOME/$tilde}"
    ls -dt "$root"/*/ 2>/dev/null | while IFS= read -r d; do
      name="${d%/}"; name="${name##*/}"
      [ -n "$name" ] || continue
      case "$running" in *$'\n'"$name"$'\n'*) continue ;; esac
      # A dot can never be a session name (tmux reads it as a pane index — see
      # _t_new_session), so a folder named that way cannot host an agent under
      # its own name. Offering it as a completion would be a trap: picking it
      # either fails, or silently creates a differently-named folder next to it.
      case "$name" in *.*) continue ;; esac
      mark=""
      [ -e "${d%/}/.git" ] && mark="git"
      printf '%s\t%s\t%s\n' "$name" "$label" "$mark"
    done
  done | awk -F'\t' '!seen[$1]++'
}

# ---------------------------------------------------------------------------
# t [NAME|REPO] [NAME] — attach to a session, creating it if it doesn't exist
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
# _t_help — one screen for the whole toolkit.
#
# It grew past the point where remembering it was reasonable: sessions, agents,
# sleeping, snapshots, and recovery are five different vocabularies. Grouped by
# what you are trying to do rather than alphabetically, because the question is
# always "how do I get back to X", never "what does tk stand for".
_t_help() {
  cat <<'HELP'
tmux agents — sessions that hold Claude Code agents

SESSIONS
  t NAME               attach — creating the session and its folder if needed, and
                       waking the agent if it is asleep or came back from a reboot
  t REPO [NAME]        same, but the folder is a checkout (owner/repo, URL, path)
  t                    attach to the most recent session
  tl                   list sessions      tw   every pane, and what runs in it
  tk NAME              kill one session   tmv OLD NEW   rename one
  td                   detach (same as Ctrl+b d)

QUICK JOBS          ask, walk away, read the answer — no agent to babysit
  tj TASK...           run `claude -p` on it, detached, in this folder
  tj                   recent jobs: ⚡ running  ✉ unread  ✓ read  ✗ failed
  tj show [ID]         print an answer (no ID: the newest)   tj wait [ID]   block for it
  tj reply [ID] TEXT   follow up — same conversation, still in the background
  tj resume ID         carry on as an interactive agent      tj rm ID|--all
                       TMUX_QUICK_JOB_FLAGS="--model sonnet" etc. passes flags to claude

THROWAWAY AGENTS    a scratch dir, nothing left behind in ~/agent-projects
  tq [NAME]            start one (no name: one is invented)
  tq done [NAME]       end it — removes the scratch dir, or offers to keep the work
  tq keep [NEWNAME]    promote it into a real ~/agent-projects folder
  tq ls                quick agents, live and orphaned
  tq gc [-n] [-y]      sweep orphaned scratch dirs   (-n dry run, -y no prompt)

FAVORITES           the agents you start often, in ~/.config/tmux-agents/favorites.tsv
  tf                   pick one and start it (or switch to it if running)
  tf NAME              start that one      tf add [NAME]   add (no NAME: this session)
  tf ls / rm / edit    the list / drop one / edit the file
                       a favorite is defaults for a NAME — its folder or repo, and
                       what window 1 runs — so `t NAME` and the picker honour it too

AGENTS
  ta                   every agent: live status, context used, and its task
                       ● working  ⊘ stuck  ○ idle  ◆ waiting on you  ☾ asleep  ◇ other CLI
  ts [NAME]            a second agent beside this one, same folder
  ts -s [NAME]         the same, but split into this window

SLEEPING            an idle agent holds ~400MB; sleeping keeps the conversation
  tsleep -n            what would be slept, and how much it would free
  tsleep               sleep everything idle over 24h   (--idle H to change)
  tsleep NAME...       sleep these, whatever their idle time   (%PANE works too)
  twake NAME...        wake them, each on its own exact conversation
  tlifecycle -n        the hourly sweep, dry run: slept at 48h idle, shut down at 7d
                       (--sleep-hours H / --shutdown-hours H)
  tpower               low-battery guard: battery, threshold, who is awake
  tpower -n            what it would sleep right now (agents sleep at 10% on battery)

SURVIVING A RESTART   snapshots on every change and every 5 min; rebuilt at login
  tsnaps               snapshots on disk
  tsnaps -l            what the newest holds — every agent and its task
  tsave                snapshot now
  trestore             rebuild every session in the newest snapshot that is not running
  trestore NAME...     only these            trestore -f FILE   from an older snapshot
  trestore --resume    ...and start every agent, not just its shell     -n dry run

WHEN SOMETHING GOES MISSING
  tarchive             sessions aged out, plus agents that are NOT RUNNING
  tarchive restore NAME   bring one back on its exact conversation
  claude -r            in the folder: pick from every conversation there
  tdoctor              is all of this wired up? deps, hooks, keys, shadowed names

KEYS, INSIDE TMUX
  Ctrl+b a             agent picker — enter jumps (and wakes a sleeping one)
                       ctrl-n new   ctrl-s clone   ctrl-v clone in a split
                       ctrl-g pull it into this window   ctrl-t rename
                       ctrl-o sleep/wake   ctrl-x kill   ctrl-f files   ctrl-r refresh
  Ctrl+b j             jump to whoever has waited on you longest
  Ctrl+b F             favorites — enter starts one
  Ctrl+b Q             quick job: type a task, enter, done — empty enter reads results,
                       then type a follow-up under the answer (or: type, ctrl-f)
  Ctrl+b f             the files this agent is working on — enter opens, ctrl-l Quick
                       Look, ctrl-f Finder, ctrl-y copy path, ctrl-e $EDITOR, ctrl-a recurse
  Ctrl+b A / B         split an agent in here / send this one back
  Ctrl+b S / R         sleep this pane's agent / wake it in place (R also cures a
                       "permissions not granted" that System Settings says is granted)
  Ctrl+b | / -         split right / below      Ctrl+b c   new window — all in this folder
  Alt+arrows           move between panes, no prefix
  Ctrl+b z             zoom this pane full screen (toggle)
  Ctrl+b [             scroll / copy mode, vi keys: v select, y copy (mouse drag copies too)
  Ctrl+b w             tree of every session, window and pane
  Ctrl+b r             reload ~/.tmux.conf
  Ctrl+b d             detach, leaving everything running

KNOBS               environment, set before the shell sources these
  T_AUTOSTART          what window 1 of a new session runs (claude; empty = a shell)
  TMUX_SESSION_PATH    where session folders are looked for, and made
  TMUX_AGENT_EXTRA_PROCS   other agent CLIs to recognise by process name ("aider codex")
  T_AGENT_LAYOUT       layout for shared windows (even-horizontal, tiled, …, none)
  TMUX_AGENT_CTX_WINDOW    context size, if you want ta to show % rather than tokens
  TMUX_AGENT_STUCK_MINS    silent this long while "working" = ⊘ stuck (10; 0 off)
  TMUX_AGENT_SLEEP_HOURS / _SHUTDOWN_HOURS / _BATTERY_SLEEP_PCT      48 / 168 / 10
  tmux set -g @agent-notify 1     desktop notification when an agent waits on you

Every command takes --help. Full notes, and why each works the way it does:
  the README at https://github.com/ryanjn/tmux-agents
HELP
}


t() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local session="${1:-}" repo=""

  # A repo where a name goes. Checked before anything else, because the slash
  # that identifies a repo is the same character the name rules below reject.
  if _t_is_repo_spec "$session"; then
    repo="$session"
    session=$(_t_repo_name "${2:-$repo}")
    [ -n "$session" ] || {
      echo "t: could not work out a session name for '$repo'" >&2; return 2; }
  fi

  if [ -z "$session" ]; then
    if tmux has-session 2>/dev/null; then
      # Resolve the target rather than letting `switch-client -l` / `attach` pick
      # it: knowing WHICH session this lands on is what makes waking it possible.
      # Most recently attached, skipping the one we are sitting in.
      local here=""
      [ -n "${TMUX:-}" ] && here=$(tmux display-message -p '#{session_name}' 2>/dev/null)
      session=$(tmux list-sessions -F '#{session_last_attached}	#{session_name}' 2>/dev/null |
                LC_ALL=C sort -rn | cut -f2- | grep -vxF "${here:-$(printf '\001')}" | head -1)
      [ -n "$session" ] || session="$here"
    fi
    [ -n "$session" ] || session=main
  fi

  # A slash would turn mkdir -p into a surprise directory tree.
  case "$session" in
    */*) echo "t: session name can't contain '/'" >&2; return 2 ;;
  esac

  if ! tmux has-session -t "=$session" 2>/dev/null; then
    # A favorite (shell/favorites.sh) is a set of defaults for NAME: where it
    # starts and what window 1 runs. Applied only when creating, and only when
    # nothing explicit was typed — `t owner/repo NAME` still means that repo.
    local fav_dir="" fav_cmd=""
    if [ -z "$repo" ] && declare -F _tf_resolve >/dev/null 2>&1; then
      _t_favorite_defaults "$session"   # sets fav_dir / repo / fav_cmd in this scope
    fi
    if [ -n "$fav_cmd" ]; then local T_AUTOSTART="$fav_cmd"; fi
    _t_new_session "$session" "$fav_dir" "$repo" >/dev/null \
      || { echo "t: could not create session '$session'" >&2; return 1; }
  elif [ -n "$repo" ]; then
    # Idempotent, same as a bare `t NAME`: an existing session wins, and the
    # repo is ignored rather than checked out somewhere unexpected.
    echo "t: '$session' is already running — attaching, not checking out '$repo'" >&2
  fi

  # Sleeping agents in there come back before you land, so `t NAME` means the
  # same thing whether the agent is running, asleep, or restored from a snapshot
  # after a reboot.
  local woke
  woke=$(_t_wake_session "$session")
  [ -n "$woke" ] && echo "t: waking $woke agent(s) in '$session' on their own conversations" >&2

  if [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "=$session"
  else
    tmux attach -t "=$session"
  fi
}

# ---------------------------------------------------------------------------
# _t_new_session NAME [DIR] [REPO] — create the session, print its agent pane's id
# ---------------------------------------------------------------------------
# Split out of `t` so the picker's "new agent" key (Ctrl+b a, then ctrl-n)
# builds a session that is identical to a hand-typed `t NAME` — same layout,
# same window names, same autostart. One code path, so they can't drift. REPO is
# the third thing that has to stay identical between the two, which is why it is
# handled here rather than in either caller.
#
# Detached on purpose: the caller decides whether to jump to it.
_t_new_session() {
  local session="$1" dir="${2:-}" repo="${3:-}" win1 pane created win_id

  # ⚠️  The dot is not a style rule. tmux parses every target as
  # session:window.pane, so a session called "release-2.0" can never be addressed
  # by name again — `kill-session -t "=release-2.0"` answers "can't find pane: 0"
  # and the session survives. Even creating it only half works: `t` makes the
  # session, then its own `new-window -t "=$session"` fails the same way and you
  # get an agent with no shell window beside it, and no way to kill it from the
  # picker. Caught here because `t` and the picker both funnel through this.
  case "$session" in
    "")   echo "t: session name can't be empty" >&2; return 2 ;;
    */*)  echo "t: session name can't contain '/'" >&2; return 2 ;;
    -*)   echo "t: session name can't start with '-'" >&2; return 2 ;;
    *.*)  echo "t: session name can't contain '.' — tmux reads it as a pane index (try ${session//./-})" >&2
          return 2 ;;
  esac

  if [ -z "$dir" ]; then
    if [ -n "$repo" ]; then
      dir=$(_t_workdir_new "$session") || return 1
    else
      dir=$(_t_workdir "$session") \
        || { echo "t: could not create a working directory for '$session'" >&2; return 1; }
    fi
  fi

  # The first window runs the agent; the second is a plain shell in the same
  # directory, one keystroke away (Ctrl+b n). Named explicitly because Claude Code
  # renames the window to its own version string otherwise.
  # Name window 1 after whatever it runs, so a T_AUTOSTART override gets a window
  # named after its own tool rather than "claude".
  win1="${T_AUTOSTART%% *}"
  win1="${win1##*/}"
  [ -n "$win1" ] || win1=shell

  # Before the notes, not after: a checkout leaves the folder non-empty, which
  # is exactly the signal _t_session_notes uses to keep its CLAUDE.md out of a
  # real repo. Ordering these the other way round would both write the note into
  # someone's checkout AND make `git clone` refuse the directory.
  if [ -n "$repo" ]; then
    _t_repo_checkout "$repo" "$dir" "$session" \
      || { rmdir "$dir" 2>/dev/null; return 1; }
  fi

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

## Putting a repo in a session

A session can start on a checkout instead of an empty folder — pass a repo where
the name goes, and the name comes from the repo:

- `t owner/repo` — GitHub `owner/repo` into a new session `repo`
- `t owner/repo bugfix` — same, session named `bugfix` instead
- `t ~/Projects/thing` — an existing local checkout

You get a **worktree** on a new branch `agent/NAME` whenever the repo is already
on disk — whether you named a path, or named a remote that a folder on
`$TMUX_SESSION_PATH` turns out to be a clone of. Otherwise it is cloned. The
worktree is the good case: it costs seconds rather than minutes, and it gives
this session its own files and its own branch, so it cannot overwrite whatever
another agent is doing in the original checkout.

The same works from the picker: type the repo instead of a name and press `ctrl-n`.

## Housekeeping

Delete this file whenever it stops being useful. If you are cloning a repo in
here by hand rather than with the commands above, note that `git clone URL .`
refuses a non-empty directory: remove this file first, or use
`git init && git remote add origin URL && git pull`.
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
  local pane="$1" session win sid client from
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  # Same reason as _t_kill_agent: switch-client -t "=name" cannot reach a session
  # whose name has a dot in it, so jumping to one silently failed too.
  sid=$(tmux display-message -p -t "$pane" '#{session_id}' 2>/dev/null)
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
    tmux switch-client -c "$client" -t "${sid:-=$session}"
  elif [ -n "${TMUX:-}" ]; then
    tmux switch-client -t "${sid:-=$session}"
  else
    tmux attach -t "${sid:-=$session}"
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
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
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
# _t_session_id NAME — a session's id ($7) looked up by EXACT name.
#
# ⚠️  Matched against `list-sessions` output rather than passed to `-t`, because
# `-t` parses its argument as session:window.pane before any matching happens.
# A name with a dot in it therefore cannot be targeted at all — and the `=`
# prefix does not save you, the split comes first. Everything that has to reach
# a session BY NAME goes through here and then uses the id.
_t_session_id() {
  local name="$1"
  [ -n "$name" ] || return 1
  tmux list-sessions -F '#{session_id} #{session_name}' 2>/dev/null |
    awk -v n="$name" '{ id = $1; sub(/^[^ ]* /, ""); if ($0 == n) { print id; exit } }'
}

_t_rename_session() {
  local old="$1" new="$2" dir oid

  case "$new" in
    "")   echo "rename: new name can't be empty" >&2; return 2 ;;
    */*)  echo "rename: name can't contain '/'" >&2; return 2 ;;
    -*)   echo "rename: name can't start with '-'" >&2; return 2 ;;
    *.*)  echo "rename: name can't contain '.' — tmux reads it as a pane index (try ${new//./-})" >&2
          return 2 ;;
  esac
  [ "$old" = "$new" ] && return 0

  if [ -n "$(_t_session_id "$new")" ]; then
    echo "rename: '$new' is already a session" >&2
    return 1
  fi

  # By id, so renaming is the way OUT of a dotted name rather than another thing
  # it blocks. This is the escape hatch for sessions created before the guard.
  oid=$(_t_session_id "$old")
  [ -n "$oid" ] || { echo "rename: no session named '$old'" >&2; return 1; }

  dir=$(tmux list-panes -s -t "$oid" -F '#{pane_current_path}' 2>/dev/null | head -1)
  tmux rename-session -t "$oid" "$new" || return 1

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

# tdoctor — is all of this wired up? Runs bin/tmux-agents-doctor.sh, which
# had no short name until now and so could not be listed in `t --help`.
tdoctor() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  "$_TA_BIN/tmux-agents-doctor.sh" "$@"
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
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
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
# instead: set TMUX_AGENT_EXTRA_PROCS="aider codex" to include them. Off by
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
  # hooks/claude-status-hook.sh.
  waitdir="$HOME/.cache/tmux-agent-status"

  # ⚠️  Every optional field is defaulted to "-" by the format itself. TAB is IFS
  # whitespace, so `read` COLLAPSES a run of tabs rather than yielding an empty
  # field between them — one blank column and every later variable shifts left.
  # @agent-session-id is empty on most panes, so without the guard this breaks
  # for the majority of rows rather than the rare one.
  tmux list-panes -a -F '#{session_name}	#{pane_pid}	#{pane_id}	#{window_id}	#{window_name}	#{pane_current_path}	#{?pane_title,#{pane_title},-}	#{window_activity}	#{pane_current_command}	#{?@agent-session-id,#{@agent-session-id},-}	#{?@agent-task,#{@agent-task},-}' 2>/dev/null \
  | while IFS=$'\t' read -r s pid pane win wname cwd title act cmd sid atask; do
      # Seconds since this window last produced output.
      silent=""
      case "${act:-}" in
        ''|*[!0-9]*) ;;
        *) [ -n "${_T_NOW:-}" ] && silent=$(( _T_NOW - act )) ;;
      esac
      # --- Claude Code: status is in the pane title ---
      # What counts as an agent's glyph. Must stay identical to the rule in
      # bin/tmux-agent-save.sh — when the two drift, the same pane is an agent
      # to the status line and a plain shell to the snapshot, or the reverse,
      # and neither side reports a problem. test/smoke.sh pins them together.
      #
      # Two conditions, and both earn their place:
      #   - no alphanumeric in the first token. Without this, ANY title whose
      #     first word is one letter is a "working agent": "a real fix for the
      #     parser" and "I think so" both classified, and a pane running a
      #     plain shell showed up in `ta` as busy.
      #   - at most 4 BYTES. Not characters: awk counts bytes, and so does bash
      #     outside a UTF-8 locale — which is exactly the environment launchd
      #     hands these scripts. "✳" is three bytes there and one character
      #     here, and a rule written in characters quietly stops matching.
      first="${title%% *}"
      _t_is_glyph=0
      if [ "$title" != "$first" ] && [ -n "$first" ] && [ ${#first} -le 4 ]; then
        case "$first" in
          *[[:alnum:]]*) ;;
          *) _t_is_glyph=1 ;;
        esac
      fi
      if [ "$_t_is_glyph" = 1 ]; then
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
          # Any other glyph is Claude Code's spinner: the agent is running. Whether
          # it is getting anywhere is a separate question — see _t_stuck.
          *)   if _t_stuck "$pane" "$cwd" "$silent"; then
                 _t_row ⊘ stuck "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" "" "$silent" "$pid"
               else
                 _t_row ● working "$pane" "$win" "$s" "$wname" "$cwd" "${title#* }" "" "$silent" "$pid"
               fi ;;
        esac
        continue
      fi

      # --- A SLEEPING agent: the process is gone, so there is no glyph and no
      # title to read. Without this the agent is invisible everywhere that
      # matters — `ta`, the picker, prefix+j, the status counts — and the only
      # way back to it is to remember which pane it was in. With 23 asleep that
      # is not a workflow.
      #
      # The @agent-session-id pane option is what says "an agent lives here",
      # and the pane running a plain shell is what says it is not running now.
      # Deliberately NOT a `ps` check: this feeds the status line every few
      # seconds and must stay to one tmux call, and pane_current_command already
      # distinguishes them for free (an awake agent reports its version string,
      # never "bash", because Claude Code sets its own process title).
      if [ "$sid" != "-" ]; then
        case "${cmd##*/}" in
          bash|zsh|sh|dash|fish|ksh)
            [ "$atask" = "-" ] && atask=""
            # No age column. Both durations this list can show mean "how long
            # has it been like this", and neither is knowable here: window
            # activity tracks the last REDRAW, so re-tiling a window makes a
            # fortnight-old sleeper look two minutes old. The word "asleep" is
            # the whole state; a number beside it would only ever be wrong.
            _t_row ☾ asleep "$pane" "$win" "$s" "$wname" "$cwd" "$atask" "" "" ""
            continue
            ;;
        esac
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
# _t_transcript_path PANE CWD — the transcript file that belongs to this agent,
# or nothing. Two readers depend on it: how much context the agent carries, and
# whether it has written anything lately (_t_stuck). One route, so the two can
# never disagree about which conversation they are describing.
_t_transcript_path() {
  local pane="$1" cwd="$2" marker f dir

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
  [ -n "$f" ] && [ -f "$f" ] && printf '%s' "$f"
}

_t_context_tokens() {
  local pane="$1" cwd="$2" f n cache mtime cached_mtime cached_tokens tokens
  f=$(_t_transcript_path "$pane" "$cwd")
  [ -n "$f" ] || return 0

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

# ---------------------------------------------------------------------------
# Agents that can't see a permission change made after they started
# ---------------------------------------------------------------------------
# macOS caches a process's TCC (privacy) decision for that process's LIFETIME.
# An agent that was told "no" to Accessibility or Screen Recording keeps the
# denial even after you grant it in System Settings — it never re-reads the
# database. So `computer-use` reports "permission(s) not yet granted" against
# settings that visibly show granted, and re-toggling them changes nothing.
#
# Long-lived agent sessions are what make this bite: `t NAME` sessions run for
# days, so any grant made in the meantime lands behind them. The fix is to
# restart the *claude process* — not `tmux kill-server`, not System Settings.
# Diagnosed 2026-07-30/31; the full write-up, including the four probes that
# each give a false green, is in the macOS permissions note in the README.
#
# ⚠️  This is reported by `tmux-agents-doctor.sh` and in the picker's preview,
# and deliberately NOT as a column in `ta` or the status line. TCC.db's mtime
# moves whenever *any* app's privacy setting changes, so "started before the
# last permission change" is true of nearly every agent nearly all the time —
# measured 12 of 14 on the machine this was written on. A marker that is on 86%
# of rows is not a warning, it is wallpaper. It earns its place where you have
# gone looking for an explanation, and nowhere else.

# _t_tcc_mtime — when a privacy permission was last changed, as an epoch second.
# Empty off macOS, or if neither database can be stat'd. Both are checked and the
# newer wins: Accessibility lives in the system database, Screen Recording in the
# per-user one, and computer-use needs both.
_t_tcc_mtime() {
  local f m newest=0
  for f in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
           "/Library/Application Support/com.apple.TCC/TCC.db"; do
    m=$(stat -f %m "$f" 2>/dev/null) || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -gt "$newest" ] && newest="$m"
  done
  [ "$newest" -gt 0 ] && printf '%s' "$newest"
  return 0
}

# _t_tcc_stale [PANE_PID …] — of the pane pids given (default: all panes), the
# ones whose agent process started before that change. Prints them space-separated.
#
# ⚠️  It is the AGENT's process that has the stale decision, not the pane's. The
# pane pid is the shell — `t` starts claude with send-keys, so claude is a child
# of it and is minutes-to-days younger. Testing the shell would call an agent you
# restarted ten seconds ago stale because the shell around it is three days old.
#
# ⚠️  `ps -o etimes=` (seconds) is a GNU extension; macOS ps rejects the keyword
# outright. Hence `etime` and the [[DD-]HH:]MM:SS parse below — and comparing
# elapsed-seconds against the age of the change, rather than reconstructing a
# start date, which would mean parsing `lstart` across two date(1) dialects.
_t_tcc_stale() {
  local tcc now panes cutoff
  tcc=$(_t_tcc_mtime)
  [ -n "$tcc" ] || return 0
  now=$(date +%s 2>/dev/null) || return 0
  cutoff=$(( now - tcc ))

  panes="$*"
  [ -n "$panes" ] || panes=$(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
  [ -n "$panes" ] || return 0

  ps -axo pid=,ppid=,etime=,comm= 2>/dev/null | awk \
      -v panes="$panes" -v cutoff="$cutoff" -v extra="${TMUX_AGENT_EXTRA_PROCS:-}" '
    BEGIN {
      n = split(panes, P, /[ \t\n]+/)
      for (i = 1; i <= n; i++) if (P[i] != "") want[P[i]] = 1
      agent["claude"] = 1
      n = split(extra, E, /[ ,]+/)
      for (i = 1; i <= n; i++) if (E[i] != "") agent[E[i]] = 1
    }
    {
      parent[$1] = $2
      cmd = $4; sub(/.*\//, "", cmd)          # /usr/local/bin/claude -> claude
      if (!(cmd in agent)) next
      # [[DD-]HH:]MM:SS. The array is `dd`, not `d`: awk will not let a name be
      # both an array and a scalar, and `d` is the hop counter in END.
      n = split($3, dd, "-"); rest = (n == 2 ? dd[2] : dd[1]); days = (n == 2 ? dd[1] + 0 : 0)
      m = split(rest, p, ":")
      sec = (m == 3 ? p[1] * 3600 + p[2] * 60 + p[3] : p[1] * 60 + p[2]) + days * 86400
      if (sec > cutoff) old[$1] = 1
    }
    END {
      for (pid in old) {
        # From the process itself, not its parent: an agent launched as the
        # pane command IS the pane pid, and would never match otherwise.
        c = pid; d = 0
        while (c != "" && c != 1 && d < 40) {
          if (c in want) { stale[c] = 1; break }
          c = parent[c]; d++
        }
      }
      out = ""
      for (w in stale) out = out w " "
      print out
    }'
}

# _t_stuck PANE CWD SILENT — is this agent wedged rather than thinking?
# Exit 0 for stuck. Off with TMUX_AGENT_STUCK_MINS=0.
#
# `●` today means two different things: productively grinding, and hung since
# breakfast. Only one of them wants you, and the spinner cannot tell them apart —
# it animates from a timer, not from progress.
#
# Two independent signals, and BOTH must say nothing is happening:
#
#   1. the pane has produced no output for N minutes (#{window_activity}).
#      Claude Code repaints its spinner and elapsed-time counter every second
#      while it works, and prints a line for every tool call, so a genuinely
#      working agent is never silent for minutes.
#   2. its transcript has not been appended to for N minutes. That is the agent
#      writing to disk rather than to a screen, which covers the case a silent
#      pane cannot: a long tool call whose output has not come back yet.
#
# ⚠️  Requiring both is the whole design, not caution. Either one alone is a
# guess: a pane can be silent while the agent is mid-write, and a transcript can
# be idle while a tool streams to the screen. A "stuck" badge that fires on a
# working agent is a tax-zero failure — it teaches you to distrust the column,
# and after that the column may as well not exist.
#
# When the transcript cannot be found at all, signal 2 is unavailable and this
# says nothing rather than guessing from silence alone.
_t_stuck() {
  local pane="$1" cwd="$2" silent="$3" mins secs f m
  mins="${TMUX_AGENT_STUCK_MINS:-10}"
  case "$mins" in ''|*[!0-9]*) return 1 ;; esac
  [ "$mins" -gt 0 ] || return 1
  secs=$(( mins * 60 ))

  case "${silent:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$silent" -ge "$secs" ] || return 1

  f=$(_t_transcript_path "$pane" "$cwd")
  [ -n "$f" ] || return 1
  m=$(stat -f %m "$f" 2>/dev/null) || m=$(stat -c %Y "$f" 2>/dev/null) || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${_T_NOW:-}" ] || return 1
  [ $(( _T_NOW - m )) -ge "$secs" ]
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

# _t_restoring — sessions that are coming back after a reboot but do not exist
# yet, one per line as "NAME<TAB>STATE":
#
#   restoring   a restore is running and has not reached this one
#   pending     this boot's restore has not started (launchd has yet to fire it)
#
# Without this the picker just lacks them for the minutes a restore takes on a
# machine still indexing after boot, which looks exactly like losing them.
#
# The running case reads the list the restore wrote into its marker, so a
# filtered `trestore NAME` shows only what it will actually build. The pending
# case is the same test persist.sh makes — this boot has not been claimed — and
# offers the whole last snapshot, which is what that restore will replay.
_t_restoring() {
  local state_dir="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
  local marker="$state_dir/.restoring" pid names state boot live
  if [ -r "$marker" ]; then
    pid=$(head -n1 "$marker" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
    names=$(tail -n +2 "$marker" 2>/dev/null); state=restoring
  else
    [ -r "$state_dir/last.tsv" ] || return 0
    boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*sec = \([0-9]*\).*/\1/')
    [ -n "$boot" ] || return 0
    [ "$(cat "$state_dir/last-boot" 2>/dev/null)" = "$boot" ] && return 0
    names=$(awk -F'\t' '$1 == "P" && !seen[$2]++ { print $2 }' "$state_dir/last.tsv")
    state=pending
  fi
  [ -n "$names" ] || return 0
  live=$'\n'$(tmux list-sessions -F '#{session_name}' 2>/dev/null)$'\n'
  printf '%s\n' "$names" | while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$live" in *$'\n'"$n"$'\n'*) continue ;; esac
    printf '%s\t%s\n' "$n" "$state"
  done
}

# _t_agent_display — _t_agent_rows with a ready-to-print label attached:
#
#   1 pane_id   2 session   3 cwd   4 glyph   5 status   6 label   7 task   8 age
#   9 process count, but only when it's high enough to be worth saying
#   10 context carried, in tokens ("730k") — or a percentage if you set
#      TMUX_AGENT_CTX_WINDOW, and empty when it can't be attributed confidently
#   11 the group this row belongs under: "Needs you", "Today", "Yesterday",
#      "This week", "Older", "Asleep". Appended LAST so that every consumer that
#      reads by position keeps working; renderers draw a heading when it changes.
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
# Above that ordering sits a coarser one, by WHEN YOU LAST SAW ACTIVITY: today,
# yesterday, this week, older. Twenty agents is too many to read as one list, and
# "which of these did I touch today" is the question you actually arrive with.
#
# ⚠️  "Needs you" is a group, not a day, and it stays at the top whatever the
# dates say. Filing a ◆ that has waited since Monday under "This week" — below
# today's idle rows — would undo the one thing this list is for. Asleep is a
# group for the same reason, at the other end: a sleeper has no last-output time
# (see _t_agent_rows), so it has no day to be filed under.
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
  # Seconds since local midnight, so "today" means the calendar day you are
  # having and not "the last 24 hours" — at 09:00 those differ by most of a day.
  #
  # ⚠️  Overridable because it makes every row's group a function of WHEN THE
  # TEST RAN. CI found this the honest way: at 00:01 UTC "two hours ago" is
  # yesterday, so two order-sensitive tests that passed all evening failed on the
  # push. Tests pin it; nothing else sets it.
  local since_midnight="${_T_TODAY_SECS:-}"
  [ -n "$since_midnight" ] ||
    since_midnight=$(( $(date +%-H) * 3600 + $(date +%-M) * 60 + $(date +%-S) ))
  printf '%s\n' "$rows" | awk -F'\t' -v procs="$procs" -v ctx="$ctx" \
      -v busy="${TMUX_AGENT_BUSY_PROCS:-8}" -v window="${TMUX_AGENT_CTX_WINDOW:-0}" \
      -v midnight="$since_midnight" '
    # One place to add a state. Anything unknown sorts last rather than vanishing.
    BEGIN {
      # Stuck sits directly under waiting: it wants you too, it just has not
      # worked out how to ask.
      rank["waiting"] = 0; rank["stuck"] = 1; rank["working"] = 2; rank["idle"] = 3
      rank["running"] = 4
      # Asleep sorts below every live state: it is the one thing on the list that
      # is definitively not waiting on you.
      rank["asleep"] = 5
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

    # group(state, seconds-since-last-activity) -> "RANK LABEL".
    # Rank leads the sort; the label is printed. Unknown timing on a LIVE agent
    # reads as today: it is running now, and burying it under "Older" would be a
    # worse lie than the one the missing timestamp already tells.
    function group(state, sec) {
      if (state == "waiting" || state == "stuck") return "0 Needs you"
      if (state == "asleep")  return "5 Asleep"
      if (sec == "")          return "1 Today"
      if (sec <= midnight)              return "1 Today"
      if (sec <= midnight + 86400)      return "2 Yesterday"
      if (sec <= midnight + 7 * 86400)  return "3 This week"
      return "4 Older"
    }

    # Compact on purpose: this column shares a line with the task.
    function age(sec) {
      if (sec == "") return ""
      if (sec < 60)   return sec "s"
      if (sec < 3600) return int(sec / 60) "m"
      return int(sec / 3600) "h"
    }

    { g[NR]=$1; st[NR]=$2; p[NR]=$3; s[NR]=$5; wn[NR]=$6; c[NR]=$7; t[NR]=$8; a[NR]=$9
      sil[NR]=$10; pp[NR]=$11; n[$5]++
      # Agents sharing ONE window (ts -s) all carry the same window name, so the
      # session:window label below cannot tell them apart. Number them in the
      # order list-panes walks the window, so "#2" is the second agent across.
      # Second *agent*, not second pane: a shell you split off sits in the same
      # window and is not a row here, so the numbering skips it.
      wk[NR] = $5 SUBSEP $6; wc[wk[NR]]++; ord[NR] = wc[wk[NR]] }
    END {
      for (i = 1; i <= NR; i++) {
        label = (n[s[i]] > 1) ? s[i] ":" wn[i] : s[i]
        if (wc[wk[i]] > 1) label = label "#" ord[i]
        if (length(label) > 30) label = substr(label, 1, 29) "…"
        r = (st[i] in rank) ? rank[st[i]] : 9
        # Waiting time for an agent that is waiting on you; silence otherwise.
        shown = (st[i] == "waiting" && a[i] != "") ? a[i] : sil[i]
        # Only shown when it means something: a healthy agent runs a couple of
        # children, a fan-out runs dozens.
        np = (pp[i] in pcount) ? pcount[pp[i]] : 0
        procs_col = (np + 0 >= busy + 0) ? "⚙" np : ""
        split(group(st[i], shown), grp, " ")
        glabel = substr(group(st[i], shown), length(grp[1]) + 2)
        printf "%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
               grp[1], r, (a[i] == "" ? 0 : a[i]), tolower(label),
               p[i], s[i], c[i], g[i], st[i], label, t[i], age(shown), procs_col,
               ctxcol(p[i] in ctok ? ctok[p[i]] : ""), glabel
      }
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3nr -k4,4 | cut -f5-
}

ta() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local out
  # "waiting 6m" rather than a separate column: it belongs with the state, and a
  # column of its own would push the task off a narrow terminal.
  # Everything about "what state is this in" folded into one column. A column of
  # its own would be empty for any agent we can't attribute, and `column -t`
  # collapses empty fields — which slides every later column left on that row.
  #
  # The group (field 11) rides along as a leading column so `column -t` can size
  # the rest as one table; the heading is drawn and the column stripped after.
  # Sizing the groups separately would step the columns in and out down the page.
  out=$(_t_agent_display | awk -F'\t' '
    { st = $5 ($8 != "" ? " " $8 : "") ($9 != "" ? " " $9 : "") ($10 != "" ? " " $10 : "")
      gsub(/ /, "\031", $11)    # one token, so the first field is unambiguous
                                 # (\031, not a Unicode escape: awk outside macOS
                                 # has no \u, and it silently leaves the literal)
      printf "%s\t%s\t%s\t%s\t%s\n", $11, $4, st, $6, $7 }')

  if [ -t 1 ]; then
    tput home 2>/dev/null
    tput ed 2>/dev/null
  fi

  [ -z "$out" ] && { echo "no agents running"; return 1; }
  printf '%s\n' "$out" | column -t -s '	' | awk '
    { group = $1; sub(/^[^ ]+ +/, "")
      gsub(/\031/, " ", group)
      if (group != seen) {
        printf "%s%s %s %s%s\n", (NR > 1 ? "\n" : ""), dim, group, rule, off
        seen = group
      }
      print }' dim="$(printf '\033[2m')" off="$(printf '\033[0m')" rule="────────────────"
}

# ---------------------------------------------------------------------------
# ts [-s] [NAME] — a second agent alongside this one, same folder
# ---------------------------------------------------------------------------
# The "I want a second Claude on this same checkout" command.
#
#   ts          a new *window* — one agent per window, Ctrl+b n / Ctrl+b p
#   ts -s       a new *pane* in this window — agents visible side by side
#
# ⚠️  The default used to be the only option, on the reasoning that "two agents
# side by side in one window is unreadable". That is a claim about width, and it
# is only true on a narrow terminal: Claude Code wants ~80 columns, so the real
# rule is `window_width / panes >= 80`. On a full-screen Ghostty window (371
# cols here) that is four agents before it bites, and `-s` warns when a split
# would cross the line rather than refusing it.
#
# What a window still buys you, and a pane does not, is its own activity dot in
# the status bar. `-s` compensates with pane borders that carry each agent's own
# status glyph and task — see _t_agent_split.
#
# Same folder, deliberately — that's the whole point. It does not create or
# touch anything on $TMUX_SESSION_PATH.
ts() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local split=0
  case "${1:-}" in
    -s|--split) split=1; shift ;;
  esac

  if [ -z "${TMUX:-}" ]; then
    echo "ts: run this from inside a tmux session (or use: t NAME)" >&2
    return 2
  fi

  if [ "$split" -eq 1 ]; then
    _t_agent_split "${TMUX_PANE:-}" "${1:-}"
  else
    _t_agent_alongside "${TMUX_PANE:-}" "${1:-}"
  fi
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

# _t_agent_split PANE [NAME] — spawn an agent in a new PANE beside PANE.
# Prints the new pane's id. Focuses it too, since you asked for it.
#
# The pane-based sibling of _t_agent_alongside. Everything downstream already
# works on this without a change, because _t_agent_rows sweeps `list-panes -a`
# and keys every row on #{pane_id}: `ta`, the picker, Ctrl+b j and the notifier
# see a split agent the moment it starts. _t_kill_agent likewise already scopes
# a kill to the pane when its window holds others. This function only has to
# create the pane and make the result legible.
#
# Legibility is the part that needs doing, and it is two settings:
#
#   - The layout is re-tiled on every split, so N agents share the window evenly
#     instead of the newest one getting half of whatever you last focused. Set
#     T_AGENT_LAYOUT (even-horizontal, main-vertical, …) if you want another, or
#     to "none" to keep a hand-arranged layout.
#   - Pane borders carry #{pane_title}, which is where Claude Code writes its own
#     "<glyph> <task>" — the same string `ta` reads. So each pane is labelled with
#     what that agent is doing, which is the thing a shared window otherwise
#     costs you. Set per-window, not globally: windows with one agent keep their
#     full height.
_t_agent_split() {
  local ref="$1" name="${2:-}" session win cwd pane panes width each layout

  session=$(tmux display-message -p -t "$ref" '#{session_name}' 2>/dev/null)
  win=$(tmux display-message -p -t "$ref" '#{window_id}' 2>/dev/null)
  cwd=$(tmux display-message -p -t "$ref" '#{pane_current_path}' 2>/dev/null)
  [ -n "${session:-}" ] || { echo "no such pane: $ref" >&2; return 1; }
  [ -n "${cwd:-}" ] || cwd="$HOME"

  # -h so the two-pane case is literally side by side; the re-tile below owns
  # every case after that.
  pane=$(tmux split-window -t "$ref" -h -c "$cwd" -P -F '#{pane_id}') || return 1

  # A name is worth having even without per-pane names: it labels the whole
  # group in the status bar, and allow-rename is off so it sticks.
  [ -n "$name" ] && tmux rename-window -t "$win" "$name" >/dev/null 2>&1

  [ -n "$T_AUTOSTART" ] && tmux send-keys -t "$pane" "$T_AUTOSTART" Enter

  _t_window_tile "$win"
  _t_focus "$pane" >/dev/null 2>&1
  printf '%s\n' "$pane"
}

# _t_window_tile WIN — re-lay a window that holds several agents, and label them.
#
# Shared by every function that changes a window's pane count, so a window looks
# the same however it got there: split into, gathered into, or broken back out of.
#
#   - Re-lays the window, so N agents share it evenly instead of the newest one
#     getting half of whatever was last focused.
#   - Turns the per-pane header on above one pane and OFF again at one, so a
#     window that drops back to a single agent gets its row of height back.
#
# ⚠️  The layout is chosen, not fixed, and `tiled` is the wrong default despite
# being the obvious one: tmux lays TWO panes out as two ROWS under `tiled`, which
# is the opposite of the side-by-side this whole feature is for. So the same
# 80-column rule that drives the warning drives the layout —
#
#   even-horizontal  while every pane still gets 80 columns  (2-4 on this screen)
#   tiled            once they would not, because a grid buys back the width
#
# T_AGENT_LAYOUT overrides both; T_AGENT_LAYOUT=none keeps a hand-arranged one.
_t_window_tile() {
  local win="$1" layout panes width each

  panes=$(tmux list-panes -t "$win" -F x 2>/dev/null | wc -l | tr -d ' ')
  [ -n "${panes:-}" ] || return 0
  width=$(tmux display-message -p -t "$win" '#{window_width}' 2>/dev/null)

  layout="${T_AGENT_LAYOUT:-}"
  if [ -z "$layout" ]; then
    if [ -n "${width:-}" ] && [ "$panes" -gt 0 ] && [ $(( width / panes )) -ge 80 ]; then
      layout=even-horizontal
    else
      layout=tiled
    fi
  fi
  [ "$layout" = none ] || tmux select-layout -t "$win" "$layout" >/dev/null 2>&1

  if [ "$panes" -le 1 ]; then
    tmux set-window-option -t "$win" -u pane-border-status >/dev/null 2>&1
    tmux set-window-option -t "$win" -u pane-border-format >/dev/null 2>&1
    return 0
  fi

  # ⚠️  set-window-option, and the -t is the WINDOW. Setting pane-border-status
  # globally puts a border line on every single-pane window on the machine —
  # one row of height lost everywhere, to label something that needs no label.
  tmux set-window-option -t "$win" pane-border-status top >/dev/null 2>&1
  # Two details in one short string:
  #   #{=60:pane_title} is the portable trim. The nicer #{=/60/…:…} form is 3.4+
  #   and this has to keep working if tmux is ever downgraded.
  # ⚠️  #[fg=colour39]#[bold], NOT #[fg=colour39,bold]. tmux splits #{?a,b,c} on
  #   commas before it ever looks at the styles, so a comma inside #[…] cuts the
  #   conditional in half and the border renders as literal "bold]" text.
  tmux set-window-option -t "$win" pane-border-format \
    '#{?pane_active,#[fg=colour39]#[bold],#[fg=colour244]} #{=60:pane_title} #[default]' \
    >/dev/null 2>&1

  # Warn, don't refuse. The fix (Ctrl+b z to zoom, or send one home) is one
  # keystroke away, so blocking would cost more than it saves.
  #
  # Both dimensions, because the layout switch above trades one for the other:
  # falling back to `tiled` is what keeps panes 80 columns wide past four agents,
  # and it pays for that in rows. Checking only width would go quiet at exactly
  # the point the window gets hard to read for the other reason.
  #
  # Measured off a real pane rather than width/panes — under a grid the panes are
  # wider than that, and quoting the pessimistic number would be a lie.
  each=$(tmux display-message -p -t "$win" '#{pane_width}' 2>/dev/null)
  rows=$(tmux display-message -p -t "$win" '#{pane_height}' 2>/dev/null)
  if [ -n "${each:-}" ] && [ "$each" -lt 80 ]; then
    tmux display-message "${panes} panes, ${each} cols each — under 80, Claude Code will wrap (Ctrl+b z zooms)"
  elif [ -n "${rows:-}" ] && [ "$rows" -lt 20 ]; then
    tmux display-message "${panes} panes, ${rows} rows each — you'll see little more than the prompt (Ctrl+b z zooms)"
  fi
}

# _t_agent_gather DST SRC — move the ALREADY RUNNING agent in SRC into DST's window
#
# The other half of _t_agent_split. That one starts something new beside you;
# this one fetches an agent that is already working somewhere else, so you can
# watch two long-running sessions at once without switching between them.
#
# `join-pane` genuinely MOVES the pane — this is not a view onto it, and there is
# no tmux primitive that shows one pane in two places. Consequences worth knowing:
#
#   - The agent keeps running throughout. It is the same process, re-parented to
#     a new window; it gets a SIGWINCH and redraws.
#   - It leaves its old session. A `t NAME` session survives that, because it
#     still has the `shell` window beside the agent — but the agent no longer
#     shows under its own name in `ta`, it shows under wherever you put it. The
#     cwd column is what still identifies it.
#   - If the move empties the source session, tmux destroys the session.
#
# So the origin is recorded ON THE PANE before the move (pane options travel with
# the pane — verified), and _t_agent_send_home puts it back.
_t_agent_gather() {
  local dst="$1" src="$2" dwin swin sname wname

  [ -n "${dst:-}" ] && [ -n "${src:-}" ] || { echo "gather: need a source and a destination" >&2; return 2; }

  dwin=$(tmux display-message -p -t "$dst" '#{window_id}' 2>/dev/null)
  swin=$(tmux display-message -p -t "$src" '#{window_id}' 2>/dev/null)
  [ -n "${dwin:-}" ] || { echo "gather: no such pane: $dst" >&2; return 1; }
  [ -n "${swin:-}" ] || { echo "gather: no such pane: $src" >&2; return 1; }
  [ "$dwin" = "$swin" ] && { echo "gather: that agent is already in this window" >&2; return 1; }

  sname=$(tmux display-message -p -t "$src" '#{session_name}' 2>/dev/null)
  wname=$(tmux display-message -p -t "$src" '#{window_name}' 2>/dev/null)
  # -p is per-pane. Set BEFORE the move: after it, the values we want to record
  # have already been overwritten by the destination's.
  tmux set -p -t "$src" @agent-origin "$sname" >/dev/null 2>&1
  tmux set -p -t "$src" @agent-origin-window "$wname" >/dev/null 2>&1

  tmux join-pane -h -s "$src" -t "$dst" || return 1

  _t_window_tile "$dwin"
  # The window it came from may still hold agents — give it its layout back too,
  # and let it drop the header row if it is down to one.
  tmux list-panes -t "$swin" -F x >/dev/null 2>&1 && _t_window_tile "$swin"

  _t_focus "$src" >/dev/null 2>&1
  printf '%s\n' "$src"
}

# _t_agent_send_home PANE — undo a gather: break PANE back out into its own window
#
# Falls back rather than failing when the origin is gone, which is the common
# case after gathering the only agent out of a session: the session died with it,
# so there is nothing to go back to. A new window here beats an error, because
# the alternative leaves you with a pane you cannot get out of the way.
_t_agent_send_home() {
  local pane="$1" origin wname win

  win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  [ -n "${win:-}" ] || { echo "send home: no such pane: $pane" >&2; return 1; }

  origin=$(tmux show -pv -t "$pane" @agent-origin 2>/dev/null)
  wname=$(tmux show -pv -t "$pane" @agent-origin-window 2>/dev/null)
  # Without -n the new window is named for its shell ("bash"), losing the name
  # the picker and the status bar label it by.
  [ -n "${wname:-}" ] || wname="${T_AUTOSTART%% *}"
  wname="${wname##*/}"
  [ -n "$wname" ] || wname=agent

  # -d: stay where you are. You are pushing this away, not following it.
  if [ -n "${origin:-}" ] && tmux has-session -t "=$origin" 2>/dev/null; then
    tmux break-pane -d -s "$pane" -n "$wname" -t "=$origin:" || return 1
    tmux display-message "sent back to '$origin'"
  else
    tmux break-pane -d -s "$pane" -n "$wname" || return 1
    [ -n "${origin:-}" ] \
      && tmux display-message "'$origin' is gone — broke it out here instead" \
      || tmux display-message "moved to its own window"
  fi

  tmux set -p -t "$pane" -u @agent-origin >/dev/null 2>&1
  tmux set -p -t "$pane" -u @agent-origin-window >/dev/null 2>&1

  # The window it left may be back down to one pane, and should lose its header.
  _t_window_tile "$win"
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
  local pane="$1" session win sid agents panes
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)
  # ⚠️  The session ID ($7), not the name. tmux parses every target as
  # session:window.pane, so a name containing a dot is UNADDRESSABLE: killing
  # "release-2.0" by name reports "can't find pane: 0" and the session lives on.
  # The `=` exact-match prefix does not help — the split happens first. Names
  # like that can no longer be created (see _t_new_session), but this has to stay
  # able to remove the ones already out there, and an ID never needs escaping.
  sid=$(tmux display-message -p -t "$pane" '#{session_id}' 2>/dev/null)
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
    tmux kill-session -t "${sid:-=$session}"
  fi
}

# _t_agent_pid PANE — pid of the agent process running in PANE, or nothing.
#
# The pane pid is the shell; the agent is a descendant of it (send-keys through
# the interactive shell — see _t_new_session). Walked rather than `pgrep -P`
# because an alias or wrapper can put a process between the shell and the
# agent. When the tree holds MORE than one agent process — the agent itself ran
# `claude` inside its own Bash tool — the one nearest the pane wins: that is the
# agent, the deeper one is its work.
#
# Same name set as _t_tcc_stale: "claude" plus $TMUX_AGENT_EXTRA_PROCS.
_t_agent_pid() {
  local pane_pid="$1"
  [ -n "$pane_pid" ] || return 0
  ps -axo pid=,ppid=,comm= 2>/dev/null | awk \
      -v root="$pane_pid" -v extra="${TMUX_AGENT_EXTRA_PROCS:-}" '
    BEGIN {
      agent["claude"] = 1
      n = split(extra, E, /[ ,]+/)
      for (i = 1; i <= n; i++) if (E[i] != "") agent[E[i]] = 1
    }
    {
      parent[$1] = $2
      cmd = $3; sub(/.*\//, "", cmd)          # /usr/local/bin/claude -> claude
      if (cmd in agent) cand[$1] = 1
    }
    END {
      best = ""; bestd = 99
      for (p in cand) {
        c = p; d = 0
        while (c != "" && c != 1 && d < 40) {
          if (c == root) { if (d < bestd) { bestd = d; best = p }; break }
          c = parent[c]; d++
        }
      }
      if (best != "") print best
    }'
}

# _t_agent_sid PANE [CWD] — the Claude Code session id of the agent in
# PANE, or nothing if it can't be known.
#
# Why this exists rather than just using --continue: --continue resumes the most
# recent conversation IN A DIRECTORY, and directories hold more than one agent —
# ~/Projects/monorepo has four. Resuming any of them with --continue puts all
# four back on whichever spoke last, and the other three look lost. `claude -r
# <id>` is exact.
#
# Two sources, in order:
#   1. the @agent-session-id pane option — durable, survives the agent exiting,
#      and is what the snapshot carries across a reboot
#   2. the transcript path the status hook already records per pane, whose
#      basename IS the session id
#
# ⚠️  A marker must be validated against the pane's cwd before it is believed.
# Markers are keyed by pane id alone and tmux pane ids restart at %0 when the
# server does, so after a reboot a leftover marker sits on a live pane id and
# resolves to a stranger's conversation. Claude encodes a cwd by replacing "/"
# with "-", so the transcript's parent directory has to match.
_t_agent_sid() {
  local pane="$1" cwd="${2:-}" sid t enc dir
  sid=$(tmux show-options -pqv -t "$pane" @agent-session-id 2>/dev/null)
  [ -n "$sid" ] && { printf '%s\n' "$sid"; return 0; }

  [ -n "$cwd" ] || cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)
  t=$(cat "$HOME/.cache/tmux-agent-status/$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null | tr -d '%').transcript" 2>/dev/null) || return 1
  [ -n "$t" ] && [ -f "$t" ] || return 1

  enc="${cwd//\//-}"
  dir="${t%/*}"; dir="${dir##*/}"
  [ "$dir" = "$enc" ] || return 1

  sid="${t##*/}"
  printf '%s\n' "${sid%.jsonl}"
}

# _t_agent_touch PANE — record that this agent was just brought back.
#
# ⚠️  This is what stops the lifecycle sweep from undoing the thing you just did.
# "Inactive" is measured from the last turn in the CONVERSATION, and waking an
# agent adds no turn — so an agent you woke after three days still reads as three
# days idle, and the next hourly pass puts it straight back to sleep. That is not
# hypothetical: a session woken by hand was re-slept within the hour, and one that
# had already passed the 7-day mark was shut down again.
#
# The lifecycle treats an agent as active as of whichever is later: its last real
# turn, or this stamp.
_t_agent_touch() {
  tmux set-option -p -t "$1" @agent-woken "$(date +%s)" 2>/dev/null || true
}

# _t_agent_resume_cmd PANE — the command that brings PANE's agent back.
# $T_RESUME wins outright; otherwise an exact -r when the id is known, and
# --continue only as the fallback for an agent that never had one.
# _t_wake_pane PANE — if this pane holds a SLEEPING agent, bring it back on its
# own conversation. Silent no-op for a live agent, or a pane that never held one.
#
# A pane carrying @agent-session-id whose foreground process is a plain shell is
# exactly the sleeping case: the conversation exists, the process does not. That
# is what a restored session looks like after a reboot (restore rebuilds the
# shape and leaves the agents parked), and what `tsleep` leaves behind.
_t_wake_pane() {
  local pane="$1" sid cur
  sid=$(tmux show-options -pqv -t "$pane" @agent-session-id 2>/dev/null)
  [ -n "$sid" ] || return 1
  cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
  case "${cur##*/}" in
    bash|zsh|sh|dash|fish|ksh) ;;
    *) return 1 ;;                       # something is already running here
  esac
  _t_agent_restart "$pane" >/dev/null 2>&1
}

# _t_wake_session NAME — wake every sleeping agent in that session. Prints how
# many it woke, so callers can say so.
#
# ⚠️  Going to an agent means having the agent, not the shell its pane is parked
# at. `t NAME` used to attach and leave you looking at a bare prompt with a hint
# scrolled off the top — after a reboot, that was every session on the machine,
# and the fix was a command the person had to know and type per agent. The picker
# has done this on enter since 0.2; `t` doing something different was the bug.
_t_wake_session() {
  local session="$1" pane woke=0
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    _t_wake_pane "$pane" && woke=$((woke + 1))
  done <<< "$(tmux list-panes -s -t "=$session" -F '#{pane_id}' 2>/dev/null)"
  [ "$woke" -gt 0 ] && printf '%s' "$woke"
  return 0
}

_t_agent_resume_cmd() {
  local sid
  if [ -n "${T_RESUME:-}" ]; then printf '%s\n' "$T_RESUME"; return 0; fi
  sid=$(_t_agent_sid "$1" 2>/dev/null)
  if [ -n "$sid" ]; then printf '%s -r %s\n' "${T_AUTOSTART:-claude}" "$sid"
  else printf '%s --continue\n' "${T_AUTOSTART:-claude}"; fi
}

# _t_agent_restart PANE — exit the agent in PANE and resume the same
# conversation, in place. The "turn it off and on again" the TCC note above
# keeps prescribing, as one keystroke (Ctrl+b R) instead of a Ctrl+C Ctrl+C
# and retyping the resume flag.
#
# Exit is a signal to the agent process, not send-keys Ctrl+C: keystrokes land
# in whatever UI state the agent happens to be in (a dialog, a half-typed
# prompt that the first Ctrl+C merely clears), while SIGTERM means quit in
# every state. Claude Code writes its transcript continuously, so nothing is
# lost even on the SIGKILL escalation — the resume picks up the same
# conversation either way.
#
# Resume is send-keys through the pane's interactive shell, for the same two
# reasons _t_new_session gives: the `claude` alias (and its flags) applies,
# and an exit later drops to a live shell. The command comes from
# _t_agent_resume_cmd: $T_RESUME verbatim if set, else `$T_AUTOSTART -r <id>` on
# this pane's exact session id, and only `--continue` when no id can be found.
#
# An agent that has already exited restarts too: pane sitting at a plain shell
# prompt, no agent process — just send the resume command. Anything else in
# the foreground (an editor, a running build) is refused rather than typed at.
_t_agent_restart() {
  local pane="$1" pane_pid session pid cur resume waited sid title
  session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  [ -n "${session:-}" ] || { echo "no such pane: $pane" >&2; return 1; }

  # ⚠️  Resolve and stamp the session id BEFORE anything is killed. Once the
  # agent process is gone the pane title loses its glyph, and a later save can no
  # longer tell this pane was ever an agent — the id has to be on the pane by
  # then or it is gone.
  sid=$(_t_agent_sid "$pane" 2>/dev/null)
  if [ -n "$sid" ]; then
    tmux set-option -p -t "$pane" @agent-session-id "$sid" 2>/dev/null
    title=$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null)
    case "$title" in
      *" "*) tmux set-option -p -t "$pane" @agent-task "${title#* }" 2>/dev/null ;;
    esac
  fi

  pid=$(_t_agent_pid "$pane_pid")

  if [ -z "$pid" ]; then
    cur=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)
    case "${cur##*/}" in
      bash|zsh|sh|dash|fish|ksh) ;;  # dead agent at its shell — resume is the restart
      *)
        echo "no agent in this pane — it is running '${cur:-?}'" >&2
        return 1
        ;;
    esac
  else
    kill -TERM "$pid" 2>/dev/null
    # ⚠️  Poll for the pid to actually go, don't just sleep: send-keys while the
    # agent is still dying gets eaten by the agent, and the resume command is
    # simply lost. 8s of TERM grace, then KILL — the transcript is already on
    # disk, so KILL costs nothing but tidiness.
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge 40 ]; then kill -KILL "$pid" 2>/dev/null; fi
      [ "$waited" -ge 55 ] && { echo "agent (pid $pid) would not die" >&2; return 1; }
      sleep 0.2
      waited=$((waited + 1))
    done
  fi

  resume=$(_t_agent_resume_cmd "$pane")
  _t_agent_touch "$pane"
  tmux send-keys -t "$pane" "$resume" Enter
}

# ---------------------------------------------------------------------------
# tw — every pane across every session, and what's running in it
# ---------------------------------------------------------------------------
# The "where did I leave that agent?" command. Answers it without attaching to
# each session in turn and looking. The command column is the real process, so
# a wedged pane still shows what it's stuck on.
tw() {
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
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
  case "${1:-}" in -h|--help) _t_help; return 0 ;; esac
  local sid
  if [ -z "$1" ]; then
    echo "usage: tk SESSION   (list them with: tl)" >&2
    return 2
  fi
  # By id — `tk release-2.0` is exactly the case that used to answer
  # "can't find pane: 0" and leave the session running.
  sid=$(_t_session_id "$1")
  [ -n "$sid" ] || { echo "tk: no session named '$1'" >&2; return 1; }
  tmux kill-session -t "$sid"
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

  # A slash means they're typing a repo, not a session — `t ~/Projects/…`. Hand
  # it to directory completion, which is the only useful answer there. Without
  # this the `complete -F` below wins and offers session names to a path, which
  # is worse than no completion at all.
  case "$cur" in
    */*|'~'*)
      COMPREPLY=( $(compgen -d -- "$cur") )
      return 0
      ;;
  esac

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
