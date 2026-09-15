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

![Every agent and what it is doing, favorites, and what a snapshot holds](docs/demo/tour.gif)

*The shell surface: `ta`, `tl`, `tf`, `tsnaps`. Recorded against this working
tree with staged agents — see [docs/demo](docs/demo/) for what is real and what
is staged, and how to regenerate it.*

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
./install.sh --with-launchd  # also load the snapshot and battery jobs (macOS)
./install.sh --no-cli        # skip the ~/.local/bin command symlinks
./install.sh --login-shell   # keep tmux's default login shell in panes
./install.sh --no-login-shell # force a non-login interactive shell
./install.sh --uninstall     # remove all of it
```

Then check it:

```bash
./bin/tmux-agents-doctor.sh
```

`--with-cli` is the default: `tsave`, `tdoctor`, `tf` and the rest are shell
functions, which `cron`, `launchd` and `ssh host tsave` cannot see, so the
installer also drops symlinks for them in `~/.local/bin`. One script backs all of
them — it dispatches on its own basename. A real file already sitting at one of
those names is never overwritten.

`--with-launchd` is **not** the default, because a background job that outlives
your terminal should be something you asked for. Without it you lose the
five-minute snapshot clock, the restore at login, and the battery guard;
everything still works by hand via `tsave` / `trestore` / `tpower`.

**If your agent is a shell alias, read this one.** tmux starts a **login** shell,
and a bash login reads `~/.bash_profile` and *never* `~/.bashrc` (zsh: `.zprofile`,
never `.zshrc`). So if `claude` is an alias in `~/.bashrc` — say
`claude --dangerously-skip-permissions` — a login shell silently resolves it to
the bare binary instead. Same word, different flags, and nothing anywhere tells
you. `t` then starts agents that behave unlike the ones you start by hand.

The installer looks rather than guesses: if it can see that your interactive file
exists and your login file does not source it, it renders
`set -g default-command "${SHELL}"` so panes get a non-login interactive shell.
Override with `--login-shell` / `--no-login-shell`.

Three deliberate omissions: **your status line is left alone** unless you ask
(`--with-status`), **no background jobs** unless you ask (`--with-launchd`), and
the installer won't edit `~/.claude/settings.json` for you — see
[hooks/README.md](hooks/README.md) for the one hook worth adding.

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

### `prefix + j` — go to whoever is waiting

The one-key answer to "who needs me?". Jumps to the agent that has been waiting
**longest**, tells you how many are still queued, and says so plainly when nobody
is. Press it until the queue is empty; there's no list to read and nothing to
choose.

It needs no state to advance: you land on the oldest, you answer it, its hook
clears the marker, and the next press goes to the new oldest.

### The agent picker — `prefix + a`

Every agent, with a live preview of its screen:

| Key | Does |
|---|---|
| `enter` | Jump to it |
| *(list order)* | **Waiting first, longest-waiting at the top**, then working, then idle — a work queue, not an alphabet. The top row is always where `prefix + j` would take you |
| `ctrl-n` | **New agent**, named from whatever you've typed in the prompt |
| `ctrl-s` | **Second agent beside** the highlighted one, in the same folder |
| `ctrl-t` | **Rename** it — the dialog is prefilled, so enter on its own changes nothing |
| `ctrl-x` | **Kill** it — asks in a small dialog naming the agent, then returns to the list so you can clear several |
| `ctrl-f` | **Browse its files** |
| `ctrl-r` | Refresh |

Each row also shows **how much context that agent is carrying** (`736k`), read
from Claude Code's transcript — so "which agent is about to compact?" and "which
one can take more work?" are answerable from the list. Tokens rather than a
percentage on purpose: the transcript records the model as `claude-opus-5`
whether it's the 200k or the 1M variant, so a percentage would be a confident
guess and wrong by 5x for anyone on 1M. Set `TMUX_AGENT_CTX_WINDOW` if your
agents share a window and you'd rather see `73%`.

Each row carries **how long it has been like that** — time waiting for an agent
that wants you, time since it last printed anything otherwise. `working 40m` is a
wedged agent; the spinner alone can't tell you that. Rows also show `⚙N` when an
agent has fanned out into N processes, and the preview is headed with that
folder's branch and uncommitted count — so "which agents have work I haven't
looked at?" is answerable without visiting any of them.

Questions are asked in a 7-line box, not by blanking the list — `ctrl-x` shows
`Kill the agent in api-gateway?` and defaults to no. Cancel and you're back in the
list with your query still typed.

No fzf? The binding falls back to a dependency-free tmux menu with the same
actions on `n` / `s` / `x`.

### More agents in this window — `prefix + A`, `prefix + B`

`prefix + A` splits the current window and starts an agent in the new pane, on the
same folder. Press it again for a third. The window re-tiles each time so they
share it evenly, and every pane border carries that agent's own status glyph and
task, so a window of four is still readable at a glance.

Claude Code wants about 80 columns, so this stops being useful past
`window_width / 80` panes — it says so rather than refusing, and `prefix + z`
zooms one pane full-screen when you actually want to read it.

`prefix + B` is the undo for pulling an agent in with the picker's `ctrl-g`: it
breaks the pane back out into the session it came from, or into its own window
here if that session has since died.

Capitals because `prefix + a` is the picker and these belong with it: `a` finds an
agent that exists, `A` makes one here, `B` sends one home.

### Sleep and wake — `prefix + S`, `prefix + R`

An idle agent still holds roughly 400MB. A few dozen of them is real memory spent
on conversations that are waiting for an answer which isn't coming today.

**Sleeping exits the process and keeps the conversation.** `prefix + S` sleeps the
agent in this pane; `prefix + R` wakes it in place; `ctrl-o` in the picker does
either, and rows for sleeping agents show `☾`. Pressing enter on a sleeping agent
wakes it — you rarely have to think about which state it was in.

```bash
tsleep -n             # what would be slept, and how much it would free
tsleep                # everything idle over 24h  (--idle H to change)
tsleep NAME...        # these, whatever their idle time  (%PANE works too)
twake NAME...         # back, each on its own exact conversation
```

> [!IMPORTANT]
> Waking uses `claude -r <session-id>`, never `claude --continue`. `--continue`
> resumes the most recent conversation **in that directory** — so four agents
> sharing one folder would quietly all come back as whichever spoke last. The
> session id is recorded *before* the process is stopped, which is the only reason
> sleeping is safe at all.

`prefix + R` is also the cure for the Claude Code failure where macOS says a
permission is granted and the agent disagrees: restarting the process in place
picks up the current TCC state, and MCP or config changes, without losing the
conversation.

### Ageing agents out

`tlifecycle` runs hourly and is the passive version of the same idea: sleep at 48h
idle, shut down at 7 days. `tlifecycle -n` shows what the next sweep would do.
Nothing is destroyed — a shut-down agent's conversation is still on disk, and
`tarchive` lists everything that aged out, with `tarchive restore NAME` to bring
one back on its exact conversation.

`tpower` is the same mechanism on a different trigger: on battery, below 10%,
idle agents are slept rather than left to die with the machine. `tpower` shows the
battery, the threshold and who is awake; `tpower -n` shows what it would sleep now.

### Surviving a restart

A tmux server is a process, and a reboot kills it along with every session. What
can be kept is the **shape** of the server — written to disk while it runs and
replayed afterwards. The agents' actual work was never in tmux to begin with:
Claude Code stores each conversation under `~/.claude/projects`, keyed by working
directory, so an agent restored into the same folder resumes with its history.

```bash
tsnaps                # snapshots on disk
tsnaps -l             # what the newest holds — every agent and its task
tsave                 # snapshot now
trestore              # rebuild every session in the newest snapshot not running
trestore --resume     # ...and start each agent, not just its shell
trestore -n           # dry run        trestore NAME...   only these
```

Snapshots are taken on **every change** — ten tmux hooks fire a coalescing
autosave — and, with `--with-launchd`, every five minutes as well, with a restore
at login. A power cut costs you seconds of arrangement rather than minutes.

### Favorites — `tf`, `prefix + F`

The agents you start often, in `~/.config/tmux-agents/favorites.tsv`.

```bash
tf                    # pick one and start it (or switch to it if running)
tf NAME               # start that one
tf add [NAME]         # add one — no NAME means this session, as it stands
tf ls / rm / edit     # the list / drop one / edit the file
```

A favorite is **defaults for a name**, not a separate launcher: its folder or repo
and what window 1 runs. So `t NAME` and the picker honour it too, and a favorite
you start by habit and one you start by hand land in the same place.

### Throwaway agents — `tq`

`t NAME` is built to be permanent: it resolves or creates a folder and seeds a
`CLAUDE.md` so the next agent there knows what the place is. That's right for work
you come back to and wrong for the one-question-one-answer asks, which otherwise
leave behind a folder whose only content is the note explaining that it exists.

`tq` inverts it — disposal is the default, keeping is what you ask for:

```bash
tq [NAME]             # start one in a scratch dir, nothing in ~/agent-projects
tq done [NAME]        # end it — removes the scratch dir, or offers to keep the work
tq keep [NEWNAME]     # promote it into a real folder
tq ls                 # quick agents, live and orphaned
tq gc [-n] [-y]       # sweep orphaned scratch dirs
```

Scratch dirs live under `~/.cache`, deliberately not `$TMPDIR`: macOS purges
`$TMPDIR` on its own schedule, which would delete a running agent's working files
out from under it. `~/.cache` survives until something here removes it, which also
leaves `tq gc` something to find after a crash.

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
| `tmv NEW` | Rename this agent. The session name is the label everywhere, so an agent that outgrew its name is one you can't find |
| `tl` | Sessions — `●` attached, `·` detached |
| `tw` | Every pane everywhere, and what's running in it |
| `tk NAME` | Kill a session |
| `td` | Detach |
| `tf` | Favorites — pick one and start it |
| `tq` | A throwaway agent in a scratch dir |
| `tsleep` / `twake` | Sleep idle agents, keeping their conversations / bring them back |
| `tsave` / `trestore` / `tsnaps` | Snapshot the server's shape, replay it, list snapshots |
| `tarchive` | Agents that aged out or stopped, and `tarchive restore NAME` |
| `tpower` / `tlifecycle` | The battery guard / the hourly sleep-and-shutdown sweep |
| `tdoctor` | Is all of this actually wired up? |

`t --help` prints the whole surface — every command above, every keybinding, and
every knob — on one screen.

```
$ ta
◆  waiting 32m 189k      api-gateway      Should I drop the legacy column?
◆  waiting 4m 22k        payments-api     Which currency should the fallback use?
●  working 2s ⚙41 88k    vault-tagger     Tagging every item in the vault
●  working 40m 512k      billing-worker   Adding retry backoff
○  idle 3h 61k           docs-site        Rewrote the install guide
```

`t` and `tk` complete from live sessions plus every folder on
`$TMUX_SESSION_PATH`, so tab-completion covers reattaching after a reboot.

### Renaming

`tmv pricing-api`, or `ctrl-t` in the picker. The session name is what the picker,
`ta`, the status line and the jump queue all show, so a session that started life
as `scratch` and became something real is genuinely hard to find.

The **folder is deliberately left where it is**. Moving it out from under a
running agent would leave its cwd pointing at an inode with a different name —
every absolute path it has already written down (its own notes, a scratch dir, a
git remote) would rot, with no way for it to notice. A stale folder name is a much
smaller problem than a silently wrong one. The folder's `CLAUDE.md` is updated to
say what happened, so the provenance stays honest.

`tmv`, not `tr` — `tr(1)` is a command people actually use.

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
| `TMUX_AGENT_NOTIFY` | *(off)* | `1` sends a desktop notification the moment an agent starts waiting. Prefer `tmux set -g @agent-notify 1`, which applies to agents already running |
| `TMUX_AGENT_NOTIFY_CMD` | *(auto)* | Your own notifier, called as `CMD TITLE MESSAGE`. Otherwise terminal-notifier, osascript, or notify-send |
| `TMUX_AGENT_BUSY_PROCS` | `8` | How many processes an agent must have spawned before it's flagged `⚙N` |
| `TMUX_AGENT_CTX_WINDOW` | *(off)* | Your context window in tokens. Set it and context shows as `73%` instead of `736k` |
| `T_AGENT_LAYOUT` | `tiled` | Layout for windows holding several agents (`even-horizontal`, `tiled`, …, or `none` to leave it alone) |
| `TMUX_AGENT_SLEEP_HOURS` | `48` | Idle hours before the hourly sweep sleeps an agent |
| `TMUX_AGENT_SHUTDOWN_HOURS` | `168` | Idle hours before it shuts one down (it stays in `tarchive`) |
| `TMUX_AGENT_BATTERY_SLEEP_PCT` | `10` | Battery percentage below which `tpower` sleeps idle agents |
| `TMUX_AGENTS_STATE` | `~/.local/state/tmux-agents` | Snapshots, the archive, and the lifecycle log |

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
Routing and reconstruction are largely done. Short version of what's next: **a
board view** that shows every agent at once so you stop opening the picker just to
look, filter keys to narrow it, and then moving a file or a finding from one agent
to another without copying it through your own hands.

## Platform support

The *agent* can be anything that runs in a terminal. The *host* is more opinionated
than that, and it is worth being straight about which parts:

| | macOS | Linux |
|---|---|---|
| Sessions, `prefix + a`, `prefix + j`, status line, file browser | ✅ | ✅ |
| Save / restore / sleep / wake / ageing | ✅ | ✅ |
| Favorites, throwaway agents, the doctor | ✅ | ✅ |
| Copy to clipboard | `pbcopy` | OSC 52, needs a terminal that supports it |
| Desktop notifications | `terminal-notifier` / `osascript` | `notify-send` |
| Open / reveal a file | `open`, Finder | `xdg-open`, no reveal |
| Quick Look preview (`ctrl-l`) | ✅ | ✗ no equivalent |
| Battery guard (`tpower`) | `pmset` | ✗ not implemented |
| Background jobs (`--with-launchd`) | launchd | ✗ use systemd timers or cron |

The core is portable. What is macOS-bound is notifications, Quick Look,
reveal-in-Finder, the battery guard and the launchd jobs. Nobody has yet run the
full suite on Linux — see the 1.0 section of [ROADMAP.md](ROADMAP.md).

## Contributing

```bash
./test/smoke.sh              # syntax, portability traps, install/uninstall round-trip
./test/integration.sh        # a real tmux server on its own socket: restore, sleep, kills
./bin/tmux-agents-doctor.sh  # check a live install
```

Both run without a tmux server. **[TESTING.md](TESTING.md) is worth reading before
you change anything** — testing tmux UI while using tmux has a set of traps that
produce tests which pass on real bugs, and they're all written down there. Issues and PRs welcome — especially Linux
polish and zsh completion. The `1.0` section of the roadmap is mostly
self-contained, well-defined work if you're looking for somewhere to start.

MIT © Ryan Norris
