# tmux-agents

**A console for running several coding agents at once.**

Start an agent in its own session and folder with one word. See every agent's live
status and screen in one popup. Start, clone and kill them from there. Browse and
open the files any of them is touching, without leaving the keyboard.

Built for [Claude Code](https://claude.com/claude-code), works with anything that
runs in a terminal.

```
 agent> ‸                                    │ ⏺ Adding the retry backoff…
   4/4 ─────────────────────────────────     │
   enter jump  ctrl-n new  ctrl-s alongside  │   1  export async function retry<T>(
   ctrl-x kill  ctrl-f files  ctrl-r refresh │   2    fn: () => Promise<T>,
 ▌ ◆  api-gateway     Should I drop the …    │   3    attempts = 3,
 ▌ ●  billing-worker  Adding retry backoff   │   4  ) {
 ▌ ○  docs-site       Rewrote the install …  │   5    let lastError: unknown
 ▌ ○  web:claude2     Auditing the bundle    │   6    for (let i = 0; …
```

`◆` needs you · `●` working · `○` idle

---

## Why

Running one agent in a terminal is easy. Running five is a mess: which window was
the migration in, which one is blocked on a question, which one finished twenty
minutes ago, and what was that folder called?

tmux already solves the hard part — processes that survive a closed terminal.
`tmux-agents` adds the part tmux doesn't have: it knows what an *agent* is, so it
can show you their state, start them, and clean them up.

**Nothing to poll and no daemon.** Claude Code writes `<glyph> <task>` into its
pane title and keeps it current, so status comes free. An agent is told apart from
a shell by *shape*: a shell's pane title is one token (its directory), an agent's
is a single-character glyph followed by a task.

## Install

Needs **tmux 3.3+** and **bash**. [fzf](https://github.com/junegunn/fzf) strongly
recommended, [ripgrep](https://github.com/BurntSushi/ripgrep) optional.

```bash
brew install tmux fzf ripgrep          # or your package manager
git clone https://github.com/ryanjn/tmux-agents ~/.tmux-agents
cd ~/.tmux-agents && ./install.sh
```

That renders a tmux config with absolute paths into `~/.config/tmux-agents/`, adds
**one** `source-file` line to your `~/.tmux.conf`, and **one** `source` line to your
shell rc. Both are fenced in `# >>> tmux-agents >>>` markers, replaced rather than
stacked on re-run, and every file it edits is backed up first.

```bash
./install.sh --dry-run       # print every change, make none
./install.sh --with-status   # also put agent counts in your status line
./install.sh --with-extras   # also install optional tmux QoL settings
./install.sh --no-shell      # keybindings only, no shell functions
./install.sh --uninstall     # remove all of it
```

Then check it:

```bash
./bin/tmux-agents-doctor.sh
```

Two deliberate omissions: **your status line is left alone** unless you ask
(`--with-status`), and the installer won't edit `~/.claude/settings.json` for you —
see [hooks/README.md](hooks/README.md) for the one hook worth adding.

## Use

### Start an agent

```bash
t billing-worker
```

Creates the session, creates `~/agent-projects/billing-worker` to work in, starts
your agent in window 1, and leaves a plain shell in window 2. `Ctrl+b d` detaches
and the agent keeps running. `t billing-worker` from any terminal gets you back.

If a folder called `billing-worker` already exists on `$TMUX_SESSION_PATH`, that's
used instead — so `t my-real-project` lands in your actual checkout rather than
burying it under an empty folder of the same name.

### The agent picker — `prefix + a`

Every agent, with a live preview of its screen:

| Key | Does |
|---|---|
| `enter` | Jump to it |
| `ctrl-n` | **New agent**, named from whatever you've typed in the prompt |
| `ctrl-s` | **Second agent beside** the highlighted one, in the same folder |
| `ctrl-x` | **Kill** it — asks in a small dialog naming the agent, then returns to the list so you can clear several |
| `ctrl-f` | **Browse its files** |
| `ctrl-r` | Refresh |

Questions are asked in a 7-line box, not by blanking the list — `ctrl-x` shows
`Kill the agent in api-gateway?` and defaults to no. Cancel and you're back in the
list with your query still typed.

No fzf? The binding falls back to a dependency-free tmux menu with the same
actions on `n` / `s` / `x`.

### The file browser — `prefix + f`

Browse the folder the agent in this pane is working in — one directory at a time,
sorted, directories first, with a line-numbered preview.

| Key | Does |
|---|---|
| `enter` | Directory: go in. File: open in the system viewer |
| `..` / `ctrl-h` | Up a level |
| `ctrl-a` | Toggle **every file below here** — fuzzy-find by name. Your query carries over |
| `ctrl-l` | Quick Look (macOS). Stays open, so you can flip through images |
| `ctrl-f` | Reveal in Finder |
| `ctrl-y` | **Copy the absolute path** — for pasting into an agent's prompt |
| `ctrl-e` | Open in `$EDITOR`, in a new tmux window so it doesn't land on a working agent |

From the picker, `ctrl-f` browses **the highlighted agent's** folder — so
`prefix + a`, find the agent, `ctrl-f`, and you're in its files without jumping to it.

### From a shell

| Command | Does |
|---|---|
| `t [NAME]` | Attach to `NAME`, creating session and folder if needed. Bare `t` returns to the last one |
| `ta` | Every agent and what it's doing |
| `ts [NAME]` | A second agent beside this one, in the same folder |
| `tl` | Sessions — `●` attached, `·` detached |
| `tw` | Every pane everywhere, and what's running in it |
| `tk NAME` | Kill a session |
| `td` | Detach |

```
$ ta
◆  waiting  api-gateway       Should I drop the legacy column?
●  working  billing-worker     Adding retry backoff
○  idle     docs-site          Rewrote the install guide
```

`t` and `tk` complete from live sessions plus every folder on
`$TMUX_SESSION_PATH`, so tab-completion covers reattaching after a reboot.

### New folders explain themselves

When `t` creates a folder, it seeds a `CLAUDE.md` with the session name, when it
was started, what created it, and the window layout — plus a **What this session
is for** section for the agent working there to fill in. `CLAUDE.md` specifically,
because that's the filename Claude Code loads from the cwd at startup, so the
context arrives without anyone asking for it.

Only ever into an **empty** directory, and it never overwrites. Your real checkouts
are not touched.

## Configure

Set these before the helpers are sourced (i.e. above the marker block in your rc):

| Variable | Default | Does |
|---|---|---|
| `T_AUTOSTART` | `claude` | What a new session runs in window 1. Empty for a plain shell |
| `TMUX_SESSION_PATH` | `$HOME/agent-projects:$HOME/Projects` | Where session folders are looked for, and created (first entry) |
| `TMUX_AGENT_EXTRA_PROCS` | *(none)* | Agent CLIs to detect by process name, e.g. `"aider codex"` |

Running more than one kind of agent? Wrap `t` — bash's dynamic scoping means the
override applies and then disappears, and the window gets named after the tool:

```bash
tai() { local T_AUTOSTART='aider'; t "$@"; }
```

## How much a kill takes with it

Rows are keyed by **pane id** (`%12`), not session name, because `ctrl-s` can put
two agents in one session and `renumber-windows` means today's `session:2.1` is
tomorrow's `session:1.1`. `ctrl-x` escalates only as far as it has to:

| Situation | What dies |
|---|---|
| The agent's window holds other panes (a log you split off) | Just the agent's **pane** |
| Its session holds other agents | Just its **window** |
| It was the session's only agent | The whole **session**, leftover shell window included |

## Gotchas worth knowing

Four things that cost real debugging time, in case you're building on tmux popups
yourself:

- **A popup has no `$TMUX_PANE`.** So `switch-client` from inside one picks a client
  at random — press `enter` in one terminal window and a *different* one jumps to
  the agent. The keybindings pass `'#{client_tty}'`, which tmux expands against the
  client that pressed the key, and everything downstream uses `switch-client -c`.
- **One overlay per client, and a second one fails by returning success.** A
  `display-popup` from inside a popup does not error — it returns **0** and never
  runs your command. Built as a confirmation dialog, that reads as "the user said
  yes", so `ctrl-x` killed agents with no prompt at all. `display-menu` is dropped
  the same way. Dialogs are therefore driven from *outside* the popup: the picker
  reports what it wants and exits, `tmux-agent-pick.sh` asks and reopens it.
  `bin/tmux-dialog.sh` refuses to run inside a popup and exits **2**, so a caller
  doing `dialog confirm … || exit` can never mistake the failure for an answer.
- **A popup kills its own background children.** `qlmanage -p file &` never ran at
  all: tmux tears down the popup's process group the moment its command exits.
  Anything that must outlive the popup goes through `tmux run-shell -b`.
- **`base-index` defaults to 0.** `select-window -t "=$session:1"` looks like "the
  first window" and is actually the *second* one for anybody who hasn't set
  `base-index 1` — so `t NAME` dropped you on the shell instead of the agent.
  Window and pane ids don't care; `test/smoke.sh` now greps for the pattern.
- **`run-shell` executes under `sh`,** where process substitution is a syntax error.
  One `read x < <(cmd)` anywhere in the sourced helpers silently loses every
  function defined after that line. `test/smoke.sh` checks for it.
- **`run-shell` reports a non-zero exit as an error on your status line,** and the
  normal case *is* non-zero — switching clients tears the popup down mid-command,
  and `esc` out of fzf is exit 130. The dispatchers end with an explicit `exit 0`.

## Notes

- **macOS is the first-class target.** Quick Look and reveal-in-Finder are Mac
  concepts; elsewhere they fall back to `xdg-open` or say so. Everything else is
  portable.
- **The shell helpers are bash.** They load and work under zsh; only tab completion
  is skipped.
- **The function names are short and can collide** — `ts` is moreutils' timestamp
  command. `install.sh` warns you, and `--no-shell` gives you the keybindings only.
- **`prefix + f` replaces tmux's default `find-window`.** `prefix + w` covers that
  ground; comment the line out in `tmux/agents.conf.in` if you disagree.

## Where this is going

[ROADMAP.md](ROADMAP.md) — the plan, organised around the five taxes of running
several agents at once: routing, reconstruction, awareness, handoff and ceremony.
Short version of what's next: **one key that jumps to whichever agent is waiting on
you**, waiting times in the list, and a board view that shows every agent at once
so you stop opening the picker just to look.

## Contributing

```bash
./test/smoke.sh              # syntax, portability traps, install/uninstall round-trip
./bin/tmux-agents-doctor.sh  # check a live install
```

Both run without a tmux server. Issues and PRs welcome — especially Linux
polish and zsh completion. The `1.0` section of the roadmap is mostly
self-contained, well-defined work if you're looking for somewhere to start.

MIT © Ryan Norris
