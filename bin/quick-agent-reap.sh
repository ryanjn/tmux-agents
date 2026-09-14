#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# quick-agent-reap.sh — decide whether a folder holds work, and remove it if not
# ---------------------------------------------------------------------------
# The single source of truth for "is there anything in here worth keeping?".
# Both callers depend on it being conservative:
#
#   - the tmux `session-closed` hook, which reaps a quick agent's scratch dir
#     the moment its session dies. That path is fully unattended — there is
#     nobody to answer a prompt and nothing to undo it, so a false "no work
#     here" silently destroys the thing you just asked for.
#   - `tq gc`, which sweeps orphaned scratch dirs and the artifact-only folders
#     `t` leaves in ~/agent-projects.
#
# ⚠️  The rule that matters is in _qa_authored_count: a folder is disposable
# only when EVERY entry in it is machine-generated. It is deliberately not
# "the CLAUDE.md looks untouched" — ~/agent-projects is full of folders with
# real work under a provenance note nobody ever edited (lilly-email-response
# has 46 files under one). Judging by the note alone deletes those.
#
# Usage:
#   quick-agent-reap.sh check DIR      exit 0 if disposable, 1 if it holds work
#   quick-agent-reap.sh count DIR      print the number of authored entries
#   quick-agent-reap.sh reap DIR       remove DIR, but only if disposable
#   quick-agent-reap.sh session NAME   reap the scratch dir behind a q- session
set -uo pipefail

QA_ROOT="${QA_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/quick-agents}"
QA_PROJECTS="${QA_PROJECTS:-$HOME/agent-projects}"

# ---------------------------------------------------------------------------
# _qa_canon DIR — DIR with every symlink and .. resolved away, or nothing
# ---------------------------------------------------------------------------
# ⚠️  The roots have to go through this too, not just the target. _qa_safe_target
# compares a `pwd -P`-resolved path against them, and on macOS a root can easily
# be spelled differently from how it resolves — /var is a symlink to /private/var,
# so a root under mktemp -d never matches its own children. That mismatch fails
# safe (nothing is ever deleted) which is exactly why it would go unnoticed
# until the day a real ~/.cache sits behind a symlink and reaping silently stops.
_qa_canon() {
  [ -n "$1" ] && [ -d "$1" ] && (cd "$1" 2>/dev/null && pwd -P)
}

QA_ROOT_C=$(_qa_canon "$QA_ROOT")
QA_PROJECTS_C=$(_qa_canon "$QA_PROJECTS")
QA_HOME_C=$(_qa_canon "$HOME")

# ---------------------------------------------------------------------------
# _qa_safe_target DIR — refuse to touch anything that isn't ours to delete
# ---------------------------------------------------------------------------
# Everything downstream ends in `rm -rf`, so this is the blast radius limiter.
# A path only passes if it is a real directory exactly one level below the
# scratch root or ~/agent-projects. That single-level rule is what stops a
# name like "../.." or "foo/../.." from walking out of the sandbox: the parent
# of the RESOLVED path has to be the root itself.
_qa_safe_target() {
  local dir="$1" resolved parent

  [ -n "$dir" ] || return 1
  [ -d "$dir" ] || return 1

  # Resolve symlinks and .. before comparing. Comparing the string you were
  # handed would let "$QA_ROOT/../../Documents" pass a prefix test.
  resolved=$(_qa_canon "$dir") || return 1
  [ -n "$resolved" ] || return 1

  # Never a root itself, however it was spelled.
  case "$resolved" in
    /) return 1 ;;
  esac
  [ -n "$QA_HOME_C" ] && [ "$resolved" = "$QA_HOME_C" ] && return 1
  [ "$resolved" = "$QA_ROOT_C" ] && return 1
  [ "$resolved" = "$QA_PROJECTS_C" ] && return 1

  # Exactly one level below a root. The single-level rule is what stops a name
  # like "foo/../.." from walking out: the parent of the RESOLVED path must be
  # the root itself, not merely start with it.
  parent=$(dirname "$resolved")
  { [ -n "$QA_ROOT_C" ] && [ "$parent" = "$QA_ROOT_C" ]; } \
    || { [ -n "$QA_PROJECTS_C" ] && [ "$parent" = "$QA_PROJECTS_C" ]; }
}

# ---------------------------------------------------------------------------
# _qa_generated_note FILE — true when a CLAUDE.md is machine-written boilerplate
# ---------------------------------------------------------------------------
# Two shapes count as generated:
#
#   - the provenance note `t` writes into a fresh ~/agent-projects folder, but
#     ONLY while it still carries "_Not recorded yet._". Once you have replaced
#     that section with what the session is for, the file is something you
#     wrote and the folder is no longer disposable — even if it is the only
#     file there (add-music-to-elevenlabs-cli is exactly that).
#   - the ephemeral note `tq` writes into a scratch dir, identified by a marker
#     line rather than by its prose so rewording it later can't break this.
_qa_generated_note() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -qF 'quick-agent-scratch' "$f" && return 0
  grep -qF 'This folder was created **empty** by' "$f" \
    && grep -qF '_Not recorded yet._' "$f"
}

# ---------------------------------------------------------------------------
# _qa_authored_count DIR — how many entries in DIR are yours rather than ours
# ---------------------------------------------------------------------------
# Ignored as machine-generated:
#   .quick-agent   the scratch marker `tq` drops
#   CLAUDE.md      only when _qa_generated_note says it is still boilerplate
#   .claude        Claude Code's own per-directory state, not your work
#   .DS_Store      Finder
#
# Anything else — a file, a directory, a checkout — counts, and one is enough
# to make the folder worth keeping. Note that a NON-empty .claude still doesn't
# count: it holds settings and local session state, which is reconstructible.
_qa_authored_count() {
  local dir="$1" n=0 entry base

  [ -d "$dir" ] || { printf '0\n'; return 0; }

  # A glob loop, not `ls | wc -l`: filenames with spaces or newlines are
  # exactly the case where an undercount turns into a deletion.
  shopt -s nullglob dotglob
  for entry in "$dir"/*; do
    base="${entry##*/}"
    case "$base" in
      .quick-agent|.claude|.DS_Store) continue ;;
      CLAUDE.md) _qa_generated_note "$entry" && continue ;;
    esac
    n=$((n + 1))
  done
  shopt -u nullglob dotglob

  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------
# _qa_reap DIR — remove DIR if it is both safe to touch and holds nothing
# ---------------------------------------------------------------------------
_qa_reap() {
  local dir="$1" count

  _qa_safe_target "$dir" || return 1
  count=$(_qa_authored_count "$dir")
  [ "$count" = "0" ] || return 1

  rm -rf -- "$dir" 2>/dev/null || return 1
  return 0
}

cmd="${1:-}"
target="${2:-}"

case "$cmd" in
  check)
    _qa_safe_target "$target" || exit 1
    [ "$(_qa_authored_count "$target")" = "0" ]
    ;;
  count)
    _qa_authored_count "$target"
    ;;
  reap)
    _qa_reap "$target"
    ;;
  session)
    # Called from the tmux session-closed hook, where the only thing we know is
    # the session name. Anything that isn't a quick agent is none of our
    # business, and silence is the correct output either way — a hook that
    # prints lands in whatever pane happens to be focused.
    case "$target" in
      q-*) ;;
      *) exit 0 ;;
    esac
    _qa_reap "$QA_ROOT/${target#q-}" >/dev/null 2>&1
    exit 0
    ;;
  *)
    echo "usage: quick-agent-reap.sh {check|count|reap|session} TARGET" >&2
    exit 2
    ;;
esac
