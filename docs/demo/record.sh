#!/usr/bin/env bash
# Record the README demos.
#
#   ./docs/demo/record.sh          all of them
#   ./docs/demo/record.sh tour     just one
#
# asciinema captures, agg renders. Not vhs: vhs 0.12 on this machine captures
# frames that are entirely blank — with its bundled Chromium, with system
# Chrome, and for a tape as simple as `echo hi` — while printing "Creating
# x.gif..." and exiting 0. Its ffmpeg step then fails silently too. agg renders
# from the cast with a font and no browser anywhere in the path.
#
# The cast files are committed alongside the GIFs. They are a tenth the size,
# they diff, and anyone can re-render at a different size or theme without
# re-recording.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export DEMO_HOME="${DEMO_HOME:-/tmp/tmux-agents-demo}"

command -v asciinema >/dev/null || { echo "need asciinema: brew install asciinema" >&2; exit 2; }
command -v agg       >/dev/null || { echo "need agg: brew install agg" >&2; exit 2; }

# Everything the recording runs must reach the demo server, never the real one.
SHIM=$(mktemp -d)
printf '#!/usr/bin/env bash\nexec %s -L ta-demo "$@"\n' "$(command -v tmux)" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
trap 'rm -rf "$SHIM"' EXIT

render() {              # render NAME COLS ROWS
  local name="$1" cols="$2" rows="$3"
  local cast="$HERE/$name.cast" gif="$HERE/$name.gif"

  printf '%s: staging…\n' "$name"
  "$HERE/stage.sh" setup >/dev/null

  printf '%s: recording…\n' "$name"
  env -u TMUX \
      HOME="$DEMO_HOME" \
      TMUX_AGENTS_STATE="$DEMO_HOME/.local/state/tmux-agents" \
      PATH="$SHIM:$PATH" \
      COLUMNS="$cols" LINES="$rows" TERM=xterm-256color \
    asciinema rec --overwrite --window-size "${cols}x${rows}" \
      -c "bash $HERE/$name.sh" \
      "$cast" >/dev/null 2>&1

  printf '%s: rendering…\n' "$name"
  agg --font-size 18 --line-height 1.35 --theme asciinema --idle-time-limit 2 \
      "$cast" "$gif" >/dev/null 2>&1

  printf '%s: %s (%s)\n' "$name" "$(du -h "$gif" | cut -f1 | tr -d ' ')" "$(du -h "$cast" | cut -f1 | tr -d ' ')"
}

if [ $# -gt 0 ]; then
  for n in "$@"; do render "$n" 120 30; done
else
  render tour 120 30
fi

"$HERE/stage.sh" teardown 2>/dev/null || true
