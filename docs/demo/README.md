# Demo recordings

The GIFs in the main README. `tour.gif` is the shell surface; the picker is
recorded by hand (see below).

```bash
./docs/demo/stage.sh setup      # a believable server on the `ta-demo` socket
./docs/demo/record.sh tour      # record + render docs/demo/tour.gif
./docs/demo/stage.sh teardown
```

## What is real and what is staged

The **interface is real** — these recordings drive this working tree, not a
mockup. What is staged is everything behind it:

- The agents are shells that set their pane title to `<glyph> <task>` and print
  a scripted screen. That title is the entire contract tmux-agents reads, so
  detection, the picker, the status line and the snapshot all behave exactly as
  they do with Claude Code behind the pane.
- The sample tasks and code are written in `stage.sh`. Real agents would be
  slow, non-deterministic, and would put whatever they happened to be working on
  into a public GIF.
- The snapshot's hostname is rewritten to `workstation`.

Everything runs on the `ta-demo` socket under `/tmp/tmux-agents-demo`, so a
recording can never show — or touch — a real session.

## Tooling

`asciinema` records, `agg` renders. `brew install asciinema agg`.

**Not vhs.** vhs 0.12 on macOS 26 captures frames that are entirely blank —
with its bundled Chromium, with system Chrome, and for a tape as simple as
`echo hi` — while printing `Creating x.gif...` and exiting 0. Its ffmpeg step
then fails silently as well, so there is no file and no error. If a future
version works, the tape format is nicer than a shell script; it is not a
disagreement about tools.

The `.cast` files are committed next to the GIFs. They are a tenth the size,
they diff as text, and anyone can re-render at a different size, font or theme
without re-recording:

```bash
agg --font-size 18 --theme asciinema docs/demo/tour.cast docs/demo/tour.gif
```

## Recording the picker

```bash
./docs/demo/record-picker.sh
```

Stages the server, tells you which keys to press, drops you in recording,
renders the GIF when you detach, embeds it in the README, and tears down. Run it
again to redo it — it overwrites.

It is the one recording that needs a person. `prefix + a` opens a
`display-popup`, and a popup takes keys from the client's keyboard;
`tmux send-keys` writes to a *pane*, so it can deliver neither the prefix key
nor fzf navigation inside the overlay.

Keep it under ~25 seconds. One idea per recording beats a tour of everything.
