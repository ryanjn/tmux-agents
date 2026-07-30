# Testing tmux UI without wrecking your own session

This project drives tmux, which you are also *using* while you work on it. Testing
it naively means killing your own agents, dragging your terminal to another
session, and popping dialogs over whatever you were reading.

Worse, the obvious shortcuts produce **tests that pass on bugs**. Every warning
below is here because it happened.

## Run against a separate server, not yours

```bash
env -u TMUX -u TMUX_PANE tmux -L test new-session -d -s driver -x 150 -y 42
env -u TMUX -u TMUX_PANE tmux -L test source-file /path/to/rendered/agents.conf
# ... drive it ...
tmux -L test kill-server
```

`-L test` is a completely separate tmux server: its own sessions, clients, options
and keybindings. Nothing you do to it can reach your real one.

⚠️ **`env -u TMUX -u TMUX_PANE` is not optional.** A tmux server inherits the
environment of whatever started it, and hands that environment to `run-shell`
children. Start a test server from inside a tmux pane and it inherits *that pane's*
`$TMUX_PANE` — so any code branching on "is `$TMUX_PANE` empty?" behaves
differently under test than in real life.

That exact hole shipped a bug: a guard meant to detect "am I inside a popup?" also
fired under `run-shell`, so no dialog ever opened. It passed every test, because
the test server had a stale `TMUX_PANE` and the guard never triggered. Reproducing
it required a server started with a clean environment.

## Fake agents

An agent is anything whose pane title is `<glyph> <task>` — one single-character
glyph, a space, then a label. So a fake agent is three lines:

```bash
#!/usr/bin/env bash
printf '\033]2;%s\007' "${1:-⠂ pretending to work}"
exec cat >/dev/null          # block forever, and never draw a prompt again
```

Glyphs: `⠂` (or any braille) working, `✳` idle, `◆` waiting on you.

⚠️ **Do not set the title with `tmux select-pane -T`.** It works for about a
second, then the shell's `PROMPT_COMMAND` rewrites the title to the working
directory and your fake agent silently stops being an agent. Half an hour went
into "the kill logic is broken" before it turned out the fixture had evaporated.
Emitting OSC 2 from a process that then blocks is race-free.

To fake a fan-out (for the `⚙N` process count), background some children *of the
pane process* before blocking — `sleep 120 &` in the same shell, not
`( sleep 120 & )`, which orphans them to launchd where they are correctly not
counted.

## Driving the interface

The pickers are popups, and popups belong to a *client*. So the test server needs
a client, which you get by attaching one nested inside a pane of the same server:

```bash
tmux -L test new-session -d -s host "TMUX= tmux -L test attach -t driver"
tmux -L test send-keys -t host C-b a      # prefix + a, into that client
tmux -L test capture-pane -p -t host      # renders the popup, overlays included
```

`capture-pane` on the host pane shows the nested client's whole screen — popups,
menus and all — because the client draws them into that pane's pty.

⚠️ **Keep the client attached to a plain shell session.** If it's attached to a
fake agent, your keystrokes go into that agent's `cat` instead of the popup, and
you will spend a while wondering why nothing responds.

⚠️ **Popups are centred.** A 7-line dialog on a 42-line screen is at rows 17-23.
Capturing the first ten lines and concluding "no dialog appeared" is a mistake
that looks exactly like a bug.

⚠️ **Sleep long enough for fzf to start** before sending keys, or the query lands
in the shell behind it. Poll instead of guessing:

```bash
for i in $(seq 10); do tmux -L test capture-pane -p -t host | grep -q 'agent>' && break; sleep 1; done
```

## Installing into a throwaway HOME

```bash
HOME=/tmp/fakehome XDG_CONFIG_HOME=/tmp/fakehome/.config \
  ./install.sh --rc /tmp/fakehome/.bashrc --tmux-conf /tmp/fakehome/.tmux.conf
```

⚠️ Passing `--tmux-conf` deliberately **suppresses the automatic reload**. Without
that, a throwaway install reloads whatever tmux server is running — which once
rebound a live session's keys and status line to a test config. `install.sh`
refuses to reload a config it wasn't pointed at by default.

## GUI verbs

`open`, `qlmanage` and friends are best stubbed:

```bash
printf '#!/bin/sh\nprintf "%%s %%s\\n" "$0" "$*" >> /tmp/log\n' > /tmp/stub/open
chmod +x /tmp/stub/open
tmux -L test display-popup -e "PATH=/tmp/stub:$PATH" -E ...
```

⚠️ `display-popup -e PATH=…` works, but `tmux new-session -e PATH=…` may not: the
pane's shell re-sources your profile and rebuilds `PATH`, silently dropping the
stub. Check with `command -v open` inside the pane before trusting a stub result.

⚠️ Anything reached via `tmux run-shell` runs in the **server's** environment, so
stubs set on a popup do not apply there. Quick Look goes through `run-shell -b` —
testing it with a stub will appear to do nothing while the real binary runs.

## The fast checks

```bash
./test/smoke.sh              # ~100 checks, no tmux server, no GUI, safe in CI
./bin/tmux-agents-doctor.sh  # checks a live install
```

`smoke.sh` stubs `_t_agent_rows` in a subshell to test sorting, ages and process
counts without needing real agents waiting — that pattern is worth reusing for
anything new that consumes rows.

## Things that are true and cost time to learn

- **One overlay per client.** A second `display-popup` returns **0** and silently
  does nothing. Built into a confirmation dialog, that reads as "the user said
  yes". Dialogs are driven from outside the popup for this reason.
- **A popup kills its background children** when its command exits. Anything that
  must outlive it goes through `tmux run-shell -b`.
- **`run-shell` executes under `sh`**, where process substitution is a syntax
  error. One `< <(…)` in a sourced file silently loses every function defined
  after it.
- **`base-index` defaults to 0.** `session:1` is the *second* window for anyone
  who hasn't set it. Use window and pane ids.
- **Looking at an agent must not resize it.** A board built from live mirrors
  (`tmux attach -r`) reflows the agents it displays — measured: 200x50 to 66x49,
  and it stays that way. Boards must use `capture-pane` snapshots.
- **`tail -c` cuts mid-character** and macOS awk aborts on the invalid UTF-8. Use
  `LC_ALL=C awk` when reading tails of files that may contain UTF-8.
- **A comment between backslash-continued lines** cuts the command in half.
  `bash -n` will not tell you.
