#!/usr/bin/env bash
# Record the picker demo. One command, start to finish.
#
#   ./docs/demo/record-picker.sh
#
# Stages the demo server, drops you into it recording, renders the GIF when you
# detach, embeds it in the README if it isn't there yet, and cleans up.
#
# Why this one needs you at the keyboard: `prefix + a` opens a display-popup,
# and a popup takes keys from the CLIENT. `tmux send-keys` writes to a pane, so
# it can deliver neither the prefix key nor fzf navigation inside the overlay.
# Everything else in docs/demo records itself; this is the exception.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NAME="${1:-picker}"
CAST="$HERE/$NAME.cast"
GIF="$HERE/$NAME.gif"
# Recording size. NEVER larger than the terminal it has to render into: tmux
# paints its whole screen and the terminal clips, so a 120x30 recording in an
# 80x24 window is a scrolled mess with most of the display dead. Measured from
# /dev/tty at run time, since $COLUMNS here is this script's shell, not yours.
WANT_COLS=120
WANT_ROWS=30
MIN_COLS=90
MIN_ROWS=26

for t in asciinema agg tmux; do
  command -v "$t" >/dev/null || { echo "need $t: brew install $t" >&2; exit 2; }
done

cleanup() { "$HERE/stage.sh" teardown 2>/dev/null || true; }
trap cleanup EXIT

printf '\n\033[1mRecording the picker\033[0m\n\n'
printf '  You are about to land in a staged tmux session. Press, unhurried:\n\n'
printf '    \033[38;5;110mCtrl+b a\033[0m   the picker — let the previews render for a beat\n'
printf '    \033[38;5;110m↓  ↓\033[0m       move down a row at a time, pausing on each\n'
printf '    \033[38;5;110mEnter\033[0m      jump to that agent\n'
printf '    \033[38;5;110mCtrl+b j\033[0m   go to whoever has waited longest\n\n'
printf '    \033[38;5;110mCtrl+b d\033[0m   detach — this ENDS the recording\n\n'
printf '  Aim for under ~25 seconds. Nothing here can touch a real session.\n\n'
# This needs a real terminal twice over: for the prompt below, and because
# asciinema records an interactive tmux client that you type into. Run through
# anything that captures output instead of attaching a tty — a CI step, a pipe,
# Claude Code's `!` — and there is nowhere for the keystrokes to come from.
# Say so plainly rather than failing on /dev/tty.
if [ ! -t 0 ] || [ ! -r /dev/tty ]; then
  cat >&2 <<MSG

  This one needs an interactive terminal — it records you pressing keys.

  You are running it somewhere without a tty. From inside tmux, open a window:

      Ctrl+b c
      $HERE/record-picker.sh

MSG
  exit 2
fi

TTY_COLS=$(tput cols </dev/tty 2>/dev/null || echo 0)
TTY_ROWS=$(tput lines </dev/tty 2>/dev/null || echo 0)

if [ "$TTY_COLS" -lt "$MIN_COLS" ] || [ "$TTY_ROWS" -lt "$MIN_ROWS" ]; then
  cat >&2 <<MSG

  This terminal is ${TTY_COLS}x${TTY_ROWS}; the recording needs at least ${MIN_COLS}x${MIN_ROWS}.

  tmux renders its whole screen and the terminal clips what does not fit, so a
  window this size gives a scrolled, mostly-empty picture rather than a demo.

      Ctrl+b z        zoom this pane to the full window, then run it again
      or make the terminal window bigger

MSG
  exit 2
fi

COLS=$(( TTY_COLS < WANT_COLS ? TTY_COLS : WANT_COLS ))
ROWS=$(( TTY_ROWS < WANT_ROWS ? TTY_ROWS : WANT_ROWS ))
printf '  Recording at \033[1m%sx%s\033[0m (terminal is %sx%s).\n\n' \
  "$COLS" "$ROWS" "$TTY_COLS" "$TTY_ROWS"

read -r -p "  Enter when ready, Ctrl+C to bail. " _ </dev/tty

"$HERE/stage.sh" setup >/dev/null

# The recorded client must reach the demo server and nothing else.
SHIM=$(mktemp -d)
printf '#!/usr/bin/env bash\nexec %s -L ta-demo "$@"\n' "$(command -v tmux)" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

env -u TMUX \
    HOME=/tmp/tmux-agents-demo \
    PATH="$SHIM:$PATH" \
    TERM=xterm-256color \
  asciinema rec --overwrite --window-size "${COLS}x${ROWS}" \
    -c "tmux -L ta-demo attach -t api-gateway" "$CAST"

rm -rf "$SHIM"

printf '\n  rendering…\n'
agg --font-size 18 --line-height 1.35 --theme asciinema --idle-time-limit 2 "$CAST" "$GIF"

# Embed it once; leave any hand-tuned caption alone on re-runs.
if ! grep -q "docs/demo/$NAME.gif" "$ROOT/README.md"; then
  python3 - "$ROOT/README.md" "$NAME" <<'PY'
import sys, pathlib
readme, name = pathlib.Path(sys.argv[1]), sys.argv[2]
s = readme.read_text()
anchor = "![Every agent and what it is doing"
i = s.find(anchor)
if i == -1:
    print("  (no anchor in README — embed by hand)"); raise SystemExit
end = s.index("\n", s.index("\n", i) + 1)
block = (f"\n![The picker: every agent with a live preview of its screen]"
         f"(docs/demo/{name}.gif)\n\n"
         "*`prefix + a`. Enter jumps, `ctrl-n` starts one, `ctrl-s` clones it\n"
         "alongside, `ctrl-x` kills, `ctrl-f` browses its files.*\n")
readme.write_text(s[:end + 1] + block + s[end + 1:])
print("  embedded in README.md")
PY
fi

printf '  %s  (%s)\n\n' "$GIF" "$(du -h "$GIF" | cut -f1 | tr -d ' ')"
printf '  Not happy with it? Just run this again — it overwrites.\n'
printf '  Re-render only, no re-record:\n'
printf '    agg --font-size 18 --theme asciinema %s %s\n\n' "$CAST" "$GIF"
