#!/usr/bin/env bash
# tmux-agent-save — write the shape of the running tmux server to disk.
#
# A macOS restart kills the tmux server, and with it every session. What it does
# NOT kill is the agents' actual work: Claude Code keeps each conversation in
# ~/.claude/projects, so `claude -r <session-id>` picks the conversation back up.
# (Not --continue: a directory can hold several agents, and --continue would give
# them all whichever one spoke last. The session id is saved per pane below.) The only thing lost in a reboot is
# the *shape* — which sessions existed, what they were named, which folders they
# sat in. That is what this saves, and it is all that has to be saved.
#
#   tmux-agent-save.sh [-L SOCKET]
#
# Runs from launchd every 5 minutes (see macos/com.tmux-agents.tmux-save.plist)
# and costs one tmux query. Restore with tmux-agent-restore.sh.
#
# ⚠️  Deliberately does NOT save scrollback. 30 sessions x 100k lines of history
# is gigabytes, it goes stale the moment anything runs, and the agent transcript
# — the part you actually want back — is already on disk in ~/.claude/projects.
set -u

# ⚠️  LOAD-BEARING, and it fails silently without it. With no locale set — which
# is exactly what launchd hands a job — tmux replaces the TAB in a format string
# with "_", so every row in this file becomes one unsplittable field, and BSD awk
# counts bytes rather than characters so the multi-byte status glyphs stop
# classifying. Verified: LANG unset and LANG=C both corrupt, UTF-8 is clean.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

case "${1:-}" in
  -h|--help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

SOCKET="default"
[ "${1:-}" = "-L" ] && { SOCKET="${2:?-L needs a socket name}"; shift 2; }

STATE_DIR="${TMUX_AGENTS_STATE:-$HOME/.local/state/tmux-agents}"
SNAP_DIR="$STATE_DIR/snapshots"
LATEST="$STATE_DIR/last.tsv"
KEEP=100

TAB=$'\t'

# Same definition of "this pane is an agent" the picker uses (_t_agent_rows):
# the status glyph in the PANE TITLE, not the process name.
#
# ⚠️  pane_current_command is useless here and the reason is worth writing down:
# Claude Code sets its own process title, so tmux reports the pane's command as
# "2.1.238" — its version string — and never "claude". Matching on the process
# name silently classifies every agent on this machine as "not an agent".
# The title is "<glyph> <what it is doing>", so a single-character first word is
# the signal, and the rest is a free label of what that agent was working on.

rows=$(tmux -L "$SOCKET" list-panes -a -F \
  "P${TAB}#{session_name}${TAB}#{window_index}${TAB}#{window_name}${TAB}#{window_active}${TAB}#{window_layout}${TAB}#{pane_index}${TAB}#{pane_active}${TAB}#{pane_current_path}${TAB}#{pane_current_command}${TAB}#{pane_title}${TAB}#{pane_id}${TAB}#{@agent-session-id}${TAB}#{@agent-task}" \
  2>/dev/null) || exit 0

# ⚠️  Never overwrite a good snapshot with an empty one. Without this, the first
# save that fires after a reboot — server up, nothing restored into it yet —
# would erase the very snapshot you are about to need.
[ -n "$rows" ] || exit 0

# Prove the rows actually split before writing them. The locale trap above turns
# every row into one unsplittable field, and a snapshot corrupted that way looks
# perfectly fine until the reboot when you need it. Cheap to check, so check.
fields=$(printf '%s\n' "$rows" | head -1 | awk -F"$TAB" '{print NF}')
if [ "${fields:-0}" -ne 14 ]; then
  echo "save: refusing to write a corrupt snapshot — got $fields fields, expected 14 (locale?)" >&2
  exit 1
fi

mkdir -p "$SNAP_DIR" || exit 1

stamp=$(date +%Y%m%dT%H%M%S)
tmp="$SNAP_DIR/.$stamp.$$.tmp"

{
  echo "# tmux-agents snapshot"
  echo "# saved${TAB}$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "# socket${TAB}$SOCKET"
  echo "# host${TAB}$(hostname -s)"
  echo "# columns${TAB}P session window_index window_name window_active window_layout pane_index pane_active cwd command title pane_id opt_sid opt_task is_agent task session_id"
  printf '%s\n' "$rows" | awk -F"$TAB" -v OFS="$TAB" -v cache="$HOME/.cache/tmux-agent-status/" '
    {
      title = $11
      n = split(title, w, " ")
      # The first word is the status glyph Claude Code publishes.
      # ⚠️  Do NOT test length(w[1]) == 1. The glyphs are multi-byte UTF-8 and
      # BSD awk counts BYTES unless the locale says otherwise — under launchd,
      # which sets no locale at all, every agent would classify as a shell.
      # "no alphanumerics, and short" is locale-independent.
      isagent = (n > 1 && w[1] !~ /[[:alnum:]]/ && length(w[1]) <= 4) ? 1 : 0
      task = ""
      if (isagent) { task = title; sub(/^[^ ]+ /, "", task) }

      # A SLEEPING agent is still an agent. Its pane sits at a shell, so it
      # publishes no status glyph and the title rule above cannot see it — which
      # meant a machine rebooted twice before anyone woke an agent dropped the
      # session id on the second pass and silently fell back to --continue. The
      # pane option is the durable marker of "an agent lives here", so it counts
      # too, and carries the task it was working on.
      if (!isagent && $13 != "" && $13 != "-") { isagent = 1; task = ($14 == "-" ? "" : $14) }

      # THE SESSION ID, and why it matters more than anything else here:
      # `claude --continue` resumes the most recent conversation IN A DIRECTORY.
      # Four agents share ~/Projects/monorepo, so --continue would collapse
      # all four onto whichever spoke last. `claude -r <session-id>` is exact.
      #
      # Source 1 is the pane option, set when an agent is deliberately put to
      # sleep. Source 2 is the transcript path the status hook already records
      # per pane — the session id is simply its basename.
      sid = $13
      if (isagent && sid == "") {
        pane = $12; sub(/^%/, "", pane)
        f = cache pane ".transcript"
        t = ""
        if ((getline t < f) > 0 && t != "") {
          # ⚠️  Validate the marker against this pane cwd before believing it.
          # tmux pane ids restart at %0 when the server does, and there are 113
          # markers on disk from panes that no longer exist — so after a reboot a
          # stale marker WILL sit on a live pane id and hand back another agent
          # entire conversation. Claude encodes a cwd by replacing / with -, so
          # the transcript directory has to match this pane cwd or we ignore it.
          enc = $9; gsub(/\//, "-", enc)
          dir = t; sub(/\/[^\/]*$/, "", dir); sub(/^.*\//, "", dir)
          if (dir == enc) { sid = t; sub(/^.*\//, "", sid); sub(/\.jsonl$/, "", sid) }
        }
        close(f)
      }
      $15 = isagent; $16 = task; $17 = sid
      # WARNING: never emit an empty field. TAB counts as IFS *whitespace* in
      # the shell, so a read loop splitting on tabs COLLAPSES a run of them
      # instead of yielding an empty field between — a row whose optional column
      # is blank silently shifts every later column one place left. That is how
      # agents came back as plain shells: is_agent was read out of the empty
      # session-id column sitting next to it. A dash placeholder removes the
      # possibility; the restore side maps it back.
      for (i = 1; i <= 17; i++) if ($i == "") $i = "-"
      print
    }
  '
} > "$tmp" || exit 1

mv -f "$tmp" "$SNAP_DIR/$stamp.tsv" || exit 1
ln -sfn "$SNAP_DIR/$stamp.tsv" "$LATEST"

# Keep a short history rather than one file: a snapshot taken mid-teardown (you
# killed six agents, then the machine rebooted) is worth being able to step back
# from. Hooks snapshot on every change as well as the 5-min tick, so 100 files
# (~3KB each) is a few hours of history on a busy day, more on a quiet one.
ls -1t "$SNAP_DIR"/*.tsv 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  rm -f "$old"
done

live=$(printf '%s\n' "$rows" | cut -d"$TAB" -f12 | tr -d '%' | grep -c '^[0-9]\+$' || true)

# Promote every session id we just resolved onto its pane as a pane option.
#
# This is what makes the mapping durable. The status hook transcript marker is
# only a bootstrap: it is keyed by pane id alone, and pane ids restart at %0 with
# the server. The pane option outlives the agent process exiting (which is what
# sleeping an agent does), is carried into the snapshot directly, and is stamped
# back onto restored panes — so the chain survives any number of reboots without
# depending on a cache directory at all.
while IFS="$TAB" read -r pane sid; do
  [ -n "$pane" ] && [ -n "$sid" ] || continue
  tmux -L "$SOCKET" set-option -p -t "$pane" @agent-session-id "$sid" 2>/dev/null || true
done < <(awk -F"$TAB" -v OFS="$TAB" '$1=="P" && $15==1 && $13=="-" && $17!="-" {print $12, $17}' "$SNAP_DIR/$stamp.tsv")

# Reap markers whose pane is gone. Not just clutter: pane ids restart at %0 with
# the server, so a marker left from before a reboot lands on somebody else pane
# and hands back the wrong conversation entirely.
#
# WARNING: this deletes live agent state, so it asks tmux about each pane rather
# than trusting a parsed column, and refuses to run at all if the pane list came
# back empty. An earlier version inferred "live" from a cut field; one run where
# that field was not what it expected and it erased the mapping for all 30
# running agents in a single pass. Nothing here is worth that: a stale marker is
# a small risk, and the pane option above already outranks it.
if [ -n "$live" ]; then
  for mk in "$HOME/.cache/tmux-agent-status"/*.transcript; do
    [ -e "$mk" ] || continue
    id=$(basename "$mk" .transcript)
    tmux -L "$SOCKET" display-message -p -t "%$id" '#{pane_id}' >/dev/null 2>&1 && continue
    rm -f "$mk" "$HOME/.cache/tmux-agent-status/$id.waiting"
  done
fi

sessions=$(printf '%s\n' "$rows" | cut -d"$TAB" -f2 | sort -u | wc -l | tr -d ' ')
panes=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
echo "saved $sessions sessions / $panes panes -> $SNAP_DIR/$stamp.tsv"
