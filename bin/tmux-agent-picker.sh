#!/usr/bin/env bash
# tmux-agent-picker — fzf picker for Claude Code agents, with a live preview of
# each agent's actual screen.
#
# Runs inside `tmux display-popup -E`, launched by prefix + a via
# tmux-agent-pick.sh. Falls back to tmux-agent-menu.sh where fzf isn't present.
#
#   enter    jump to that agent
#   ctrl-n   start a new agent — named from whatever you've typed in the prompt,
#            or from a dialog if you've typed nothing. Type a repo rather than a
#            name (owner/repo, a git URL, or a path to a local checkout) and the
#            agent starts on it: cloned, or worktreed for a local path
#   ctrl-s   start a second agent alongside the highlighted one, same folder,
#            in a new window
#   ctrl-v   the same, but split into the highlighted agent's own window so the
#            two are on screen together
#   ctrl-g   grab the highlighted agent — MOVE the running one into your window,
#            beside whatever is already there. Ctrl+b B sends it back
#   ctrl-o   sleep the highlighted agent, or WAKE it if it is already asleep
#            (rows show ☾ asleep) — exit the process, keep the
#            conversation. Frees ~350-800MB per agent and no confirmation is
#            asked, because it is reversible: the row stays, and enter then
#            Ctrl+b R (or twake) wakes it on its exact conversation.
#   ctrl-x   kill the highlighted agent, after a confirmation dialog
#   ctrl-t   rename the highlighted agent
#   ctrl-f   browse the highlighted agent's files
#   ctrl-r   refresh the list and previews
#   esc      cancel
#
# ctrl-o rather than the obvious ctrl-z: fzf reads in raw mode so ctrl-z is not
# supposed to reach the terminal as SIGTSTP, but a harness driving fzf through a
# pty and sending 0x1a hung rather than returning the key. A picker that can
# suspend itself inside a tmux popup is not worth the mnemonic. "o" for off.
#
# ctrl-n costs you fzf's default "move down" binding. Arrows still work, and
# "new" is the one verb worth a mnemonic key.
#
# ctrl-x and ctrl-n do NOT act here. They write what they want to
# $TMUX_AGENT_REQUEST and exit; tmux-agent-pick.sh then asks the question in a
# small popup and reopens this picker. That indirection isn't architecture for its
# own sake: tmux allows one overlay per client, and a dialog opened from inside
# this popup is silently dropped while reporting success — see the warning in
# tmux-agent-pick.sh.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO="$DIR/tmux-agent-do.sh"

# Palette and the in-popup card. Sourced, not required: a missing file should
# cost you colour, not the picker.
# shellcheck disable=SC1091
[ -r "$DIR/tmux-ui.sh" ] && . "$DIR/tmux-ui.sh"

# The shell helpers hold the agent classifier and the session/kill logic, so this
# and the picker share one definition of what an agent is. Found relative to this
# script rather than at a fixed path: the repo has to work wherever it is cloned.
HELPERS="${TMUX_AGENTS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/shell/agents.sh"
if [ -r "$HELPERS" ]; then
  # shellcheck disable=SC1090
  . "$HELPERS"
  [ -r "${HELPERS%/*}/favorites.sh" ] && . "${HELPERS%/*}/favorites.sh"
fi

# Fields 1-3 (pane id, session, cwd) are what the actions target; everything
# from field 4 on is display, which is what --with-nth=4.. shows and searches.
#
# The age column sits between the glyph and the name, padded even when empty, so
# the name column stays put whether or not anything is waiting. Waiting-first
# ordering comes from _t_agent_display and fzf preserves it for an empty query.
# Group headings (field 11 — "Needs you", "Today", "Yesterday", …) are emitted as
# rows with an EMPTY pane id. Every action here already guards on that, because a
# selection with no pane is also what cancelling looks like; enter on one does
# nothing at all (see the transform bind below). fzf has no notion of an
# unselectable row, and a heading that filters away when you type is the right
# behaviour anyway: once you are searching, days are noise.
#
# Sessions still coming back from a reboot go on top, under their own heading and
# with no pane id, so they read as present-but-not-yet rather than missing, and
# enter on one is the same no-op as on a heading. See _t_restoring.
_list() {
  declare -F _t_restoring >/dev/null 2>&1 && _t_restoring |
    awk -F'\t' -v dim="$(printf '\033[2m')" -v off="$(printf '\033[0m')" '
      NR == 1 { printf "\t\t\t%s── Restoring ──────────────────────────────%s\n", dim, off }
      { printf "\t%s\t\t%s↻ %-4s %-5s %-30s %s%s\n", $1, dim, "", "", $1,
               ($2 == "pending" ? "waiting for the restore to start" : "coming back after the reboot"), off }'
  _t_agent_display |
    awk -F'\t' -v dim="$(printf '\033[2m')" -v off="$(printf '\033[0m')" '
      $11 != seen { seen = $11
                    rule = "────────────────────────────────────────"
                    printf "\t\t\t%s── %s %s%s\n", dim, $11, substr(rule, 1, 46 - length($11) * 2), off }
      { printf "%s\t%s\t%s\t%s %-4s %-5s %-30s %s%s\n",
               $1, $2, $3, $4, $8, $10, $6, ($9 != "" ? $9 "  " : ""), $7 }'
}

# ---------------------------------------------------------------------------
# Preview: what it's saying, and what it has done to the repo
# ---------------------------------------------------------------------------
# The screen alone tells you what the agent is talking about. The header tells you
# whether it has left uncommitted work behind — the thing you'd otherwise have to
# visit every agent to find out.
#
# ⚠️  --no-optional-locks matters. A plain `git status` can take the index lock,
# and these repos have live agents writing to them; this runs on every cursor
# move. Read-only or not at all.
_preview() {
  local pane="${1:-}" cwd="${2:-}" branch dirty ppid

  # One line, for the highlighted agent only. macOS caches a process's privacy
  # decision for its lifetime, so an agent older than the last permission change
  # sees the old answer no matter what System Settings shows — which is how
  # computer-use ends up insisting it has no Accessibility grant when it plainly
  # does. Scoped to this one pane rather than shown as a column in every row:
  # most agents are older than the last TCC change most of the time. The full
  # accounting is in `tmux-agents-doctor.sh`.
  #
  # ⚠️  Read from $TMUX_AGENT_STALE, computed ONCE below before fzf starts.
  # Calling _t_tcc_stale here instead costs a full `ps -ax` over ~1200 processes
  # — measured at 120ms — on every cursor movement, which is plainly laggy in a
  # list you hold a key down to scroll. `${VAR+x}` distinguishes "computed, and
  # nothing is stale" from "not computed", so a direct `--preview` call still works.
  if [ -n "$pane" ]; then
    ppid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
    if [ -z "${TMUX_AGENT_STALE+x}" ]; then
      TMUX_AGENT_STALE=$(_t_tcc_stale 2>/dev/null)
    fi
    if [ -n "$ppid" ] && case " ${TMUX_AGENT_STALE} " in *" $ppid "*) true ;; *) false ;; esac; then
      printf '⚠ started before the last macOS permission change — Ctrl+b R restarts it in place\n'
      printf '  before using computer-use (System Settings will not help)\n\n'
    fi
  fi

  if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
    # Detached HEAD reads as the literal word "HEAD", which tells you nothing.
    [ "$branch" = HEAD ] &&
      branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | grep -c .)
    if [ "${dirty:-0}" -gt 0 ]; then
      printf '%s · %s +%s uncommitted\n\n' "${cwd##*/}" "$branch" "$dirty"
    else
      printf '%s · %s clean\n\n' "${cwd##*/}" "$branch"
    fi
  fi
  [ -n "$pane" ] && tmux capture-pane -pe -t "$pane" 2>/dev/null | tail -n 60
  return 0
}

# ---------------------------------------------------------------------------
# Naming a new agent, with the folders you already have as completions
# ---------------------------------------------------------------------------
# Typing a name blind is how you end up with `display-traffic` beside the
# `display-traffic-analysis` you meant to resume — two folders, one of them
# empty, and the work in the other. Every folder on $TMUX_SESSION_PATH with no
# session running is offered here, newest first, so resuming is a selection
# rather than a spelling test.
#
# Runs in THIS popup, like the kill card: it is another fzf, not another overlay.
#
#   enter    the highlighted folder — or exactly what you typed, if nothing matched
#   ctrl-g   exactly what you typed, even when something did match
#   esc      cancel
#
# ⚠️  ctrl-g is not a nicety. With ~250 folders your new name is very often a
# PREFIX of an existing one, and plain enter would hand you the old folder while
# you were trying to make a new one. Enter favours resuming, ctrl-g insists on new.
_name_candidates_list() {
  # Favorites first, starred; then every folder that could host an agent. A
  # favorite that is already running is left out, same as a running folder.
  local running
  running=$'\n'$(tmux list-sessions -F '#{session_name}' 2>/dev/null)$'\n'
  if declare -F _tf_candidates >/dev/null 2>&1; then
    _tf_candidates 2>/dev/null | while IFS=$'\t' read -r n note; do
      case "$running" in *$'\n'"$n"$'\n'*) continue ;; esac
      printf '%s\t★ %-38s %s\n' "$n" "$n" "$note"
    done
  fi
  _t_name_candidates 2>/dev/null |
    awk -F'\t' '{ printf "%s\t  %-38s %s %s\n", $1, $1, $2, ($3 == "git" ? "·git" : "") }'
}

# _pick_new_name QUERY — prints the chosen name, or nothing if cancelled.
_pick_new_name() {
  local q="${1:-}" rows out key sel line
  rows=$(_name_candidates_list)

  # Nothing to complete against: no list is better than an empty box.
  if [ -z "$rows" ]; then
    printf '%s' "$q"
    return 0
  fi


  out=$(
    printf '%s\n' "$rows" | fzf \
      --delimiter=$'\t' \
      --with-nth=2.. \
      --print-query \
      --expect=ctrl-g \
      --header='enter start on the highlighted folder   ctrl-g use exactly what you typed   esc cancel' \
      --prompt='new agent> ' \
      --query "$q" \
      --color "$(ui_fzf_colors 2>/dev/null)" \
      --reverse --height=100%
  )

  line=$(printf '%s\n' "$out" | sed -n 1p)   # the query
  key=$(printf '%s\n' "$out" | sed -n 2p)
  sel=$(printf '%s\n' "$out" | sed -n 3p)

  # ctrl-g, or enter with nothing matching: the typed text is the answer.
  if [ "$key" = "ctrl-g" ] || [ -z "$sel" ]; then
    printf '%s' "$line"
    return 0
  fi
  printf '%s' "${sel%%$'\t'*}"
}

# --watch-restore SOCKET: keep the open picker current while a restore runs.
# fzf has no timer, so this polls from outside and pushes a reload through fzf's
# --listen socket each time a session lands, then one last reload once the
# restore is finished so the Restoring heading goes away. It exits by itself
# when the picker closes: the post fails once nothing is listening.
_watch_restore() {
  local sock="$1" was now
  was=$(_t_restoring 2>/dev/null)
  while [ -n "$was" ]; do
    sleep 2
    now=$(_t_restoring 2>/dev/null)
    [ "$now" = "$was" ] && continue
    was="$now"
    curl -fs --unix-socket "$sock" -XPOST http://localhost -d "reload($0 --list)" || return 0
  done
}

case "${1:-}" in
  --list)    _list; exit 0 ;;
  --watch-restore) shift; _watch_restore "${1:-}"; exit 0 ;;
  --preview) shift; _preview "${1:-}" "${2:-}"; exit 0 ;;
esac

# One tab-separated line for tmux-agent-pick.sh to act on once this popup is out
# of the way. Field 4 is the query, so the reopened picker lands where you left it.
_request() {
  [ -n "${TMUX_AGENT_REQUEST:-}" ] || return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" "${4:-}" > "$TMUX_AGENT_REQUEST"
}

# Once, here, and inherited by every preview subprocess fzf spawns — see the note
# in _preview. Exported even when empty: that is what tells the preview the answer
# is already known and it must not go and compute one per keystroke.
export TMUX_AGENT_STALE
TMUX_AGENT_STALE=$(_t_tcc_stale 2>/dev/null)

# ---------------------------------------------------------------------------
# Why this is a loop
# ---------------------------------------------------------------------------
# ctrl-x used to leave here the same way ctrl-n and ctrl-t still do: write a
# request, exit, let tmux-agent-pick.sh ask in a fresh popup and reopen us. It is
# correct, but you watch a 90%-of-the-screen overlay vanish, a small box appear
# somewhere else, and the whole list rebuild — for a y/N. Killing four finished
# agents meant four rounds of that.
#
# Confirming *inside* this popup avoids all of it. That does NOT break the
# one-overlay rule the dialogs are built around: `ui_confirm_card` draws into the
# terminal we are already in and opens nothing. Only the verbs that need a text
# field still bounce out, because a real input needs line editing.
QUERY="${TMUX_AGENT_QUERY:-}"
acted=0

while :; do
  rows=$(_list)

  if [ -z "$rows" ]; then
    # Nothing left because we just killed the last one — that's a finished job,
    # not a prompt to start something. Only an empty list on ARRIVAL means "you
    # pressed this to make an agent".
    [ "$acted" -eq 1 ] && exit 0
    # Straight to the name step, with completions. No agents running is the most
    # likely moment to be resuming an existing folder rather than inventing a name.
    name=$(_pick_new_name "")
    [ -n "$name" ] || exit 0
    _request new "$name" "" ""
    exit 0
  fi

  # --print-query puts the query on line 1 and --expect the key on line 2, so the
  # selected row is line 3. Verified against fzf 0.74: on esc you get the query
  # plus an empty key line and no third line; on a key with no matches you get the
  # key and no third line.
  # Enter on a group heading should do nothing at all. fzf has no unselectable
  # row, but `transform` can turn the keypress into "ignore" when the row carries
  # no pane id. It arrived in fzf 0.45; on anything older the bind is left off and
  # the guard after the loop catches it instead — one reopen of the list rather
  # than a silent no-op.
  #
  # ⚠️  `{1}` is UNQUOTED on purpose. fzf shell-quotes every placeholder, so an
  # empty field becomes '' — and inside double quotes that is two literal quote
  # characters, i.e. non-empty. `[ -n "{1}" ]` was therefore true for headings
  # and enter jumped into them anyway.
  heading_bind=()
  case "$(fzf --version 2>/dev/null | cut -d' ' -f1)" in
    0.[0-9]|0.[0-3][0-9]|0.4[0-4]|"") ;;
    *) heading_bind=(--bind 'enter:transform:[ -n {1} ] && echo accept || echo ignore') ;;
  esac

  # A restore in flight: let fzf take reloads on a socket and start the watcher
  # that sends them. Only then — an idle picker should not be polling anything.
  listen=(); watcher=""
  if declare -F _t_restoring >/dev/null 2>&1 && [ -n "$(_t_restoring 2>/dev/null)" ] &&
     command -v curl >/dev/null 2>&1; then
    sock="${TMPDIR:-/tmp}/tmux-agent-picker.$$.sock"
    rm -f "$sock"
    listen=(--listen="$sock")
    # Give fzf a moment to open the socket; the watcher's first post is 2s out.
    "$0" --watch-restore "$sock" >/dev/null 2>&1 &
    watcher=$!
  fi

  out=$(
    printf '%s\n' "$rows" | fzf \
      --delimiter=$'\t' \
      --with-nth=4.. \
      --ansi \
      "${heading_bind[@]}" \
      ${listen[@]+"${listen[@]}"} \
      --print-query \
      --expect=ctrl-n,ctrl-s,ctrl-v,ctrl-g,ctrl-x,ctrl-t,ctrl-f,ctrl-o \
      --preview "$0 --preview {1} {3}" \
      --preview-window='right,60%,border-left' \
      --header='enter jump   ctrl-g pull it in beside me   ctrl-n new (name or repo)   ctrl-s clone   ctrl-v clone in a split   ctrl-t rename   ctrl-o sleep/wake   ctrl-x kill   ctrl-f files   ctrl-r refresh' \
      --prompt='agent> ' \
      --query "$QUERY" \
      --color "$(ui_fzf_colors 2>/dev/null)" \
      --reverse --cycle --height=100% \
      --bind "ctrl-r:reload($0 --list)"
  )

  if [ -n "$watcher" ]; then
    kill "$watcher" 2>/dev/null
    rm -f "$sock"
  fi

  query=$(printf '%s\n' "$out" | sed -n 1p)
  key=$(printf '%s\n' "$out" | sed -n 2p)
  sel=$(printf '%s\n' "$out" | sed -n 3p)
  QUERY="$query"

  pane=""
  cwd=""
  if [ -n "$sel" ]; then
    IFS=$'\t' read -r pane _session cwd _rest <<< "$sel"
  fi

  case "$key" in

    ctrl-n)
      # A repo spec is a name for something that does not exist here yet, so
      # there is nothing to complete it against — straight through, as before.
      case "$query" in
        *://*|*@*:*|*.git|*/*) _request new "$query" "" "$query"; exit 0 ;;
      esac

      # Otherwise offer the folders you already have. Whatever fzf query you had
      # typed carries into the name step, so "type it, ctrl-n, enter" still works
      # and now shows you what it would collide with.
      name=$(_pick_new_name "$query")
      [ -n "$name" ] || continue      # cancelled — back to the list
      _request new "$name" "" "$query"
      exit 0
      ;;

    ctrl-o)
      [ -n "$pane" ] || continue
      # One key both ways. A sleeping agent is now listed (glyph ☾), so the same
      # key that put it there is the obvious way to bring it back, and you never
      # have to remember which state a row is in.
      st=$(_t_agent_display | awk -F'\t' -v p="$pane" '$1 == p { print $5; exit }')
      if [ "$st" = "asleep" ]; then
        "$DO" wake "$pane" || true
        acted=1
        continue
      fi
      # No confirmation card, deliberately — unlike ctrl-x this is reversible, and
      # the whole point is to make reclaiming memory cheap enough to do casually.
      # The agent's conversation is recorded before the process is signalled.
      #
      # Not exec: sleeping leaves the pane (and this popup) alive, and `acted=1`
      # plus the loop is what redraws the row as sleeping without a reopen.
      "$DO" sleep "$pane" || true
      acted=1
      continue
      ;;

    ctrl-x)
      [ -n "$pane" ] || continue
      # Ask _t_agent_display for the label rather than scraping it back out of the
      # display column: it's "api-gateway", or "api-gateway:claude2" when a session
      # holds two agents, and that's what the question needs to name.
      label=$(_t_agent_display | awk -F'\t' -v p="$pane" '$1 == p { print $6; exit }')

      # No tmux-ui.sh, no card. Hand back to the dispatcher's popup rather than
      # letting an undefined function return non-zero, which reads as "cancel"
      # and makes ctrl-x look like a key that does nothing.
      if ! declare -F ui_confirm_card >/dev/null 2>&1; then
        _request kill "$pane" "$label" "$query"
        exit 0
      fi

      if ui_confirm_card danger " kill agent " "Kill the agent in ${label:-this pane}?"; then
        # ⚠️  Not `exec`. When this is the client's own last agent, `kill` steps
        # the client elsewhere and tmux tears this popup down with it — but every
        # other kill leaves us running, and the loop is what brings the list back
        # without a reopen. Failures already report themselves via display-message.
        "$DO" kill "$pane" || true
        acted=1
      fi
      continue
      ;;

    ctrl-t)
      [ -n "$pane" ] || continue
      # The session name is what every label, the jump queue and the status line
      # show, so a session that has outgrown its name is genuinely hard to find.
      # Still bounces out: renaming needs a text field, not a keypress.
      label=$(_t_agent_display | awk -F'\t' -v p="$pane" '$1 == p { print $2; exit }')
      _request rename "$pane" "$label" "$query"
      exit 0
      ;;

    ctrl-s)
      [ -n "$pane" ] || continue
      exec "$DO" alongside "$pane"
      ;;

    # The same thing in a pane rather than a window, so the pair ends up on
    # screen together. Targets the HIGHLIGHTED agent's window, not the one you
    # opened the picker from — same contract as ctrl-s.
    ctrl-v)
      [ -n "$pane" ] || continue
      exec "$DO" split "$pane"
      ;;

    # ctrl-g moves the OTHER way to ctrl-v: it brings an agent that is already
    # running to you, rather than starting one where it is.
    #
    # ⚠️  The destination has to be asked for by client. $TMUX_PANE is empty
    # inside display-popup (see the header), so a bare #{pane_id} here resolves
    # against a pane tmux picks for itself and the agent lands in a window you
    # were not looking at. TMUX_AGENT_CLIENT is the tty prefix-a passed down.
    ctrl-g)
      [ -n "$pane" ] || continue
      here=$(tmux display-message -c "${TMUX_AGENT_CLIENT:-}" -p '#{pane_id}' 2>/dev/null)
      [ -n "$here" ] || continue
      exec "$DO" gather "$here" "$pane"
      ;;

    ctrl-f)
      # Hand this popup over to the file browser rather than opening a second one
      # on top of it — nested popups are a fight with tmux that buys nothing, and
      # exec'ing reuses the tty we already have. cwd comes from the row, so this
      # browses the HIGHLIGHTED agent's folder, not the one you pressed the key in.
      [ -n "$cwd" ] || continue
      export TMUX_FILE_ROOT="$cwd"
      export TMUX_FILE_PANE="$pane"
      exec "$DIR/tmux-file-picker.sh"
      ;;

  esac

  # Plain enter: jump to it. fzf exits non-zero on esc, so an empty selection here
  # means "cancelled" — unless something WAS selected, which then can only be a
  # group heading. That is a misclick, not a cancel, so go back to the list.
  if [ -z "$pane" ]; then
    [ -n "$sel" ] && continue
    exit 0
  fi
  exec "$DO" focus "$pane"
done
