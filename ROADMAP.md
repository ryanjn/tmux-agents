# Roadmap

**Goal: make agent management seamless, and cut the cognitive cost of switching
between agents.**

Everything below is judged against that one sentence. A feature earns a place only
if it removes a decision, a lookup, or a context rebuild — not because it would be
neat to have.

## Where this is right now

**v0.3.0.** Routing is largely solved: `prefix + j`, waiting times, waiting-first
ordering, desktop notifications. Each agent's row also carries what it is doing to
the machine (`⚙N` processes) and how much context it is carrying (`736k`), and the
doctor catches a tmux server that has outlived the terminal which started it.

**Reconstruction is now solved too, and out of order** — it was meant to follow the
board. A reboot no longer costs anything: the server's shape is snapshotted on
every change and replayed at login, agents sleep and wake on their exact
conversations, and idle ones age out instead of accumulating. That pulled the
milestone numbering forward, so the board is **0.4** below, not 0.3.

**v0.3.1 shipped tax zero.** The doctor now checks detection against a second,
independent signal rather than reporting that it ran; CI runs both suites on
every push; and `test/integration.sh` drives a real server on its own socket.
Building it found what it was built to find — two implementations of "is this
pane an agent" that disagreed, and an rc file that returned non-zero whenever no
tmux server was running.

**Then the 0.4 board** — one popup, every agent, last few lines each, built from
`capture-pane` snapshots — with stuck-detection alongside it, since "who is
wedged" is the question the board exists to answer. Everything else below is
unstarted.

## The five taxes

Running one agent in a terminal is free. Running five costs you, in this order:

| # | Tax | What it feels like |
|---|---|---|
| 1 | **Routing** | Which one needs me *right now*? |
| 2 | **Reconstruction** | What was this one doing, and why did I start it? |
| 3 | **Awareness** | What's happening across all of them, without visiting each? |
| 4 | **Handoff** | Getting a file, path or finding from this agent to that one |
| 5 | **Ceremony** | The setup between deciding to start work and work starting |

Navigation — physically getting to an agent — used to be a sixth. `prefix + a`
solved it, and that's the model for the rest: the answer is usually *one keystroke
that removes a decision*, not a bigger interface.

**And beneath all five, tax zero: trust.** Not a cost of running many agents — a
precondition for the other five being worth anything. Every number above is read
from a heuristic, and a heuristic that quietly stops matching is worse than no
number at all: you keep making decisions, on stale readings, with no signal that
anything changed. A tool that says "3 agents idle" when it can no longer see any
agents has not degraded, it has started lying. Paying this tax means the tool
fails loudly or not at all.

## Where 0.3.0 lands

| Tax | Covered by | Gap |
|---|---|---|
| **0 · Trust** | Detection cross-checked against an independent signal, CI on every push, integration tests on a throwaway server | **Handled for the failures we can name.** Residual: a title like `~ /some/path` satisfies both detectors and still reads as an agent — that needs a glyph allowlist, not a shape test |
| Routing | `prefix + j`, waiting times, waiting-first order, opt-in notifications | Largely handled — but nothing tells you an agent is *stuck* rather than thinking, and that is the expensive half |
| Reconstruction | Snapshot/restore, sleep/wake on exact conversations, ageing, `tarchive` | **Largely handled** on one machine. It has no concept of a second one: the snapshot stamps its hostname and nothing ever reads it back |
| Awareness | The picker list | One agent at a time, only while the popup is open, and no way to search across agents at all |
| Handoff | `ctrl-y` copies a path | You paste it yourself, into an agent you navigate to yourself |
| Ceremony | `t NAME`, `ts`, `tq`, `tf`, folder + notes auto-created | **Improved** — favorites and throwaway agents removed most of it. No worktrees, no multi-window profiles |

---

## 0.2 — Never wonder who needs you — **shipped in 0.2.0**

*Routing should cost zero decisions.*

All five landed. One change from the plan: the list sorts **longest-waiting first**
within the waiting group rather than alphabetically, so the top row is always the
one `prefix + j` would take you to — two orderings that disagreed would be worse
than either alone. And the key is `prefix + j`, not `prefix + w`: `w` is
choose-tree, which this project's own docs point people at.

| Item | Why it cuts switching cost | Size |
|---|---|---|
| **`prefix + w` — jump to the next waiting agent** | Removes the choice entirely. Press it until nobody's waiting. This is the highest value-per-line item on the whole roadmap | S |
| **Waiting duration in the list** (`◆ 6m`) | Triage by staleness instead of by position. The hook already writes a marker file — its mtime is the timestamp, so this is nearly free | S |
| **Sort waiting-first, then working, then idle** | The list stops being alphabetical trivia and becomes a work queue | S |
| **Opt-in desktop notification when an agent starts waiting** | Lets you leave tmux entirely and still be pulled back at the right moment. `terminal-notifier`/`osascript`, `notify-send` on Linux, off by default | M |
| **Branch + dirty count in the preview header** | "Which agents have uncommitted work?" is currently unanswerable without visiting each one | M |

## 0.3 — Survive the machine going away — **shipped in 0.3.0**

*Reconstruction, tax #2. Shipped ahead of the board because the cost was daily and
the board is still large.*

A tmux server is a process; a reboot takes every session with it. The work itself
was never in tmux — Claude Code keys each conversation to a working directory — so
what had to be kept was the **shape** of the server, and a reliable way to put an
agent back on *its own* conversation rather than the most recent one in its folder.

| Item | What it removes |
|---|---|
| ~~**Snapshot and restore**~~ — `tsave`, `trestore`, `tsnaps`; ten tmux hooks autosave on every change, launchd every 5 min, restore at login | Rebuilding a day's worth of sessions by hand after a restart |
| ~~**Sleep and wake**~~ — `prefix + S` / `prefix + R`, `ctrl-o` in the picker, `tsleep` / `twake` | ~400MB per idle agent, held for an answer that isn't coming today |
| ~~**Exact-conversation resume**~~ — the session id is recorded *before* the process stops; wake is `claude -r <id>`, never `--continue` | Agents that share a folder silently coming back as each other |
| ~~**Ageing**~~ — `tlifecycle`, sleep at 48h, shut down at 7d, `tarchive` to find and restore | Deciding, repeatedly, whether an agent from last Tuesday is still needed |
| ~~**Battery guard**~~ — `tpower`, sleep idle agents below 10% on battery | Losing conversations because the laptop died |
| ~~**Favorites**~~ — `tf`, `prefix + F`; defaults for a name, so `t NAME` honours them too | Retyping the same folder and command for the agents you start weekly |
| ~~**Throwaway agents**~~ — `tq`, scratch dirs under `~/.cache`, `tq keep` to promote | A folder whose only content is the note explaining that the folder exists |

The one non-obvious constraint, worth keeping in mind for anything that restarts an
agent: **`claude --continue` resolves by directory, not by agent.** Every feature
above depends on recording the session id first. A future feature that restarts an
agent without doing so will silently merge conversations, and the failure looks
like an agent that has lost its memory rather than like a bug here.

## 0.3.1 — Trust the instrument — **shipped in 0.3.1**

*Tax zero. Small, and it gated everything after it.*

Every feature in this roadmap reads from one heuristic: an agent is a pane whose
title starts with a short non-alphanumeric glyph, because that is what Claude Code
writes there. Status, the picker, `prefix + j`, the status line, snapshots, sleep,
restore and ageing all stand on it. It is a good heuristic — it costs nothing and
needs no hook — and it is entirely outside our control.

The problem is not that it might break. It is that when it breaks, nothing says
so. `ta` prints nothing, the status line reads `0/0/0`, `prefix + j` says nobody
is waiting, and the doctor reports `✓ agent detection runs — sees 0 right now`.
Every one of those is indistinguishable from a quiet afternoon.

| Item | Why | Size |
|---|---|---|
| **Doctor: verify detection, don't just run it** — cross-check `_t_agent_rows` against panes whose `pane_current_command` looks like an agent CLI, and go red when an obvious agent does not classify | Converts a silent total blackout into a loud failure. The single highest-value change on this page relative to its cost | S |
| **Doctor: assert the title contract** — name the format being relied on, and report the version of the tool that is writing it | When it does break, the message should say *what* changed, not just that nothing was found | S |
| **CI** — `smoke.sh` + shellcheck on push (pulled forward from 1.0) | 162 checks that only run when someone remembers is most of the cost of a test suite for a fraction of the benefit. The bug classes here are exactly the kind a green tick catches: `sh` vs bash, a locale that mangles a TAB, an awk column that shifted | S |
| **Integration tests against a throwaway server** — `tmux -L test`, fake agents, exercise restore, kill-escalation and sleep | The three code paths that can destroy work are the three with no automated coverage. `smoke.sh` never starts a server by design; this is its sibling, not its replacement | M |
| **Say what platform this actually is** — the README claims "anything that runs in a terminal"; there are 8 `terminal-notifier`, 6 `qlmanage`, 6 `osascript`, 3 `pmset` and 2 `launchctl` call sites | Honesty is cheaper than the support burden, and it scopes the Linux work at 1.0 rather than pretending it is done | S |

Deliberately *not* here: making detection more robust. Adding a second signal is a
fix for a failure that has not happened yet. Knowing when it happens is the thing
worth buying now, and it is a tenth of the work.

## 0.4 — See everything at once

*Awareness without navigation.*

Three of these shipped early in **0.2.1**, because the 1Password incident on
2026-07-30 showed the cheap signals were worth more than waiting for the board:
last-activity, the `⚙N` fan-out flag, and the doctor's stale-server warning. What
remains is the board itself and the filter keys.

| Item | Why it cuts switching cost | Size |
|---|---|---|
| **The board** — one popup, every agent, last few lines each | Replaces "open picker, arrow down, read, arrow down, read" with one glance. The headline feature of this release | L |
| ~~**Context each agent is carrying**~~ — **shipped 0.2.4**, from Claude Code's transcript, attributed exactly via a hook-recorded path | "Which agent is about to compact, and which can take more work?" Unanswerable before without opening each one | M |
| ~~**Last-activity time per agent**~~ — **shipped 0.2.1**, from `#{window_activity}`, folded into the same column as waiting time | Distinguishes "thinking" from "wedged 40 minutes ago", which the spinner cannot | S |
| **Stuck, not thinking** — a distinct glyph for an agent whose context has not grown and whose pane has not changed for N minutes while it still claims to be working | The other half of routing, and the expensive half. `●` today means both "productively grinding" and "wedged since breakfast", and only one of those wants you. The inputs already exist: last-activity from `#{window_activity}`, context tokens from the transcript, both already sampled for every row. This is arithmetic on data we collect, not a new source | M |
| **Filter keys in the picker** (waiting only / this folder only / stuck only) | Narrows five agents to the two that matter | S |
| **"What is this agent doing to my machine?"** — ~~child processes spawned~~ (**`⚙N` shipped 0.2.1**), and whether it's writing outside its own folder | Added 2026-07-30 after an agent fanned out hundreds of `op item edit` processes across a password vault. The screen preview said "Running 1 shell command"; the only real signal was a storm of macOS permission dialogs. Status tells you an agent is *busy*, never that it's busy doing something with a blast radius | M |
| ~~**Doctor: warn when the tmux server outlives the app that launched it**~~ — **shipped 0.2.1** | Same day: a server started from iTerm 22 hours earlier meant every macOS permission prompt named a dead app, and no amount of clicking Allow could stick. Nothing surfaced that. `#{pid}` + start time + the stale `TERM_PROGRAM` in the global env is all it takes | S |

⚠️ The board is where shell scripting starts to strain — it wants live refresh and
layout. If it turns into a fight, that's the moment to consider a small compiled
TUI for *that view only*, keeping everything else as shell. Deciding that early is
cheaper than discovering it late.

## 0.5 — Work isn't trapped where it started

*The handoff is the switch. Make it one key — and stop the machine boundary being
a handoff you cannot make at all.*

Widened from "move work between agents" after 2026-09-14, when six weeks of work
on this very repo turned out to be sitting on the other laptop, invisible from
this one. The tool that manages your agents had no concept of the second machine
they might be on — `tmux-agent-save.sh` has stamped `# host <name>` into every
snapshot since the beginning, and nothing has ever read it back.

Everything here stays inside the "not an orchestrator" non-goal: work lands *in an
agent's prompt for you to press enter on*, or in a file an agent reads. Nothing
here sends an agent instructions on your behalf.

| Item | Why it cuts switching cost | Size |
|---|---|---|
| **See agents on your other machines** — `ta --all`, reading each host's `last.tsv` over whatever transport you already have (SSH, Tailscale, a synced directory) | The failure this is named after. Read-only and additive: the snapshot format already carries the hostname, and a remote row is just a row you cannot `enter` on. Start here | M |
| **Search across agents** — `tgrep PATTERN` over `~/.claude/projects` transcripts, answering "which agent was the one that touched the billing schema?" | At thirty agents this has no answer today but visiting each one. The data is already on disk, already per-directory, already greppable. Arguably a precondition for handoff: you cannot hand off what you cannot find | M |
| **Send a path to another agent** — from the file browser, pick a target agent, and it lands in that agent's prompt | Today: copy, navigate, paste, return. This is the single most common cross-agent action and it currently costs four context switches | M |
| **Send the current selection** (copy-mode text) to an agent | Same shape, for error messages and log lines rather than paths | M |
| **Leave a note for an agent** — append to its `CLAUDE.md` from the picker | Discovered by using it: the seeded `CLAUDE.md` turned out to be the natural channel for telling *another* agent something, because Claude Code loads it at session start. Cheaper than the send-to-prompt version and it survives the agent restarting | S |
| **Changed-files view in the browser** — files touched since the agent started, `ctrl-d` for a diff | Turns "what did it do?" into a keystroke instead of a review session | M |

## 0.6 — Start work without ceremony

*From "I should look at X" to an agent working on X, with nothing in between.*

| Item | Why it cuts switching cost | Size |
|---|---|---|
| **Worktree-backed sessions** — `t --worktree feature/x` creates the git worktree and the agent in it | The clean way to run several agents on one repo without them fighting over the index. Pairs naturally with `ts` | M |
| **Profiles** — a named session shape (agent + dev server + logs) | Removes the repeated manual setup for the projects you touch weekly | M |
| **Start an agent with a prompt** — `t NAME "fix the flaky retry test"` | Skips the "type the task in once you arrive" step | S |

## 1.0 — Something other people can rely on

*Adoption work. None of it changes the product; all of it decides whether the
product is usable by anyone but its author.*

| Item | Why | Size |
|---|---|---|
| **Verified on Linux** | Pulled into focus by 0.3.1 being honest about the macOS call sites. The file browser already degrades to `xdg-open`; the notifier and Quick Look paths do not, and nobody has run the suite there | M |
| **TPM support** (`set -g @plugin 'ryanjn/tmux-agents'`) | How the tmux world actually installs things | S |
| **Homebrew tap** | `brew install ryanjn/tap/tmux-agents` | S |
| **zsh completion** | The helpers work under zsh; completion doesn't | M |
| **A GIF in the README** | The value of this tool is visual and 20 seconds of screen recording explains it better than the README's 200 lines | S |

---

## Non-goals

Saying no is what keeps the tool small enough to trust.

- **Not a tmux config framework.** The load-bearing settings are two lines; the
  opinionated rest is `--with-extras` and always optional.
- **Not an agent orchestrator.** It manages *processes and attention*, never
  prompts, plans, or agent-to-agent protocols. The moment it starts deciding what
  agents should do, it stops being predictable.
- **Not Claude-Code-only, but Claude-first.** Any tool that writes
  `<glyph> <task>` into its pane title is a first-class citizen, and that contract
  is documented. No per-vendor special cases.
- **Not a rewrite.** Shell keeps it readable and hackable by the people who use
  it. The board view in 0.4 is the one place that assumption gets tested.

## Constraints that shape all of the above

Learned the hard way; each one has killed a design already:

- **One overlay per client.** A second `display-popup` returns 0 and silently does
  nothing. Dialogs must be sequential, not stacked — see `tmux-agent-pick.sh`.
- **A popup kills its own background children.** Anything that must outlive a
  popup goes through `tmux run-shell -b`.
- **`run-shell` runs `sh`**, and looks identical to a popup environmentally
  (`$TMUX` set, `$TMUX_PANE` empty). Never infer context from that pair.
- **No image rendering in popups.** Quick Look is the answer on macOS; there is no
  good Linux equivalent yet.
- **The status line is someone else's.** Anything that wants space there stays
  opt-in.
- **Looking at an agent must not resize it.** Window size belongs to the window,
  shared by every client viewing it — so a "board" built from live mirrors
  (`tmux attach -r`, one pane per agent) *reflows the agents themselves*. Measured
  2026-07-30: three agents at 200x50 dropped to 66x49 the moment the board opened,
  and stayed there after it closed. Claude Code's boxes and diffs rewrap and are
  mangled. This rules out live mirroring entirely; any board must be built from
  `capture-pane` snapshots, which are read-only and touch nothing.

## Deferred decisions

Not roadmap items — questions with a recorded answer and a trigger for reopening
them. They live here so the analysis isn't redone from scratch each time.

### Should the board be a compiled TUI?

**Answer for now: no. Build it in shell.** A `capture-pane` snapshot board on a
1–2s redraw is sufficient for the actual job — glancing at half a dozen agents to
see who is stuck. Everything a compiled TUI adds (mouse, smooth scrolling,
per-cell scrollback, comfort at 20+ agents) is a want, and none of it appeared in
any real incident so far.

The cost isn't the code, it's the character of the project: a build step,
per-platform binaries, a CI matrix, macOS notarization (or users get Gatekeeper
warnings), and an install story that stops being "clone and run install.sh".
Contributors could no longer just edit a file. That's two of the four non-goals.

**Reopen it if any of these actually happen** — not if it merely feels appealing:

1. The shell board's redraw is visibly laggy at the agent count you really run
   (say >12 agents, or a repaint over ~200ms).
2. You want something shell genuinely cannot do: mouse, per-cell scrollback,
   smooth scroll.
3. The board becomes where you *live*, rather than something you glance at.
4. People avoid touching the board code because it has become unmaintainable awk.

**If it is ever reopened, two things hold.** It stays optional — tmux-agents must
work with no binary installed, because that install story is a feature. And it
consumes `_t_agent_display` unchanged: pane id, session, cwd, glyph, status,
label, task, age, procs, one row per agent, tab-separated. The data layer is
already front-end agnostic, which is what makes deferring this free.

### Should these be subcommands of `t` rather than top-level words?

**Answer for now: leave them.** The shell surface is eighteen words — `t ts tl tw
tk tmv td tf tq tsave trestore tsnaps tsleep twake tarchive tpower tlifecycle
tdoctor` — sitting in the most contested two-and-three-letter corner of the
namespace. `ts` is moreutils' timestamp, `t` is a popular alias, and every one of
them is a collision waiting for a machine that isn't this one. `t save`, `t sleep`
and `t doctor` would cost one namespace entry instead of eighteen.

It stays as-is because the words are *typed*, and the whole premise of the tool is
that the distance between deciding and doing should be short. `tsave` is one token
of muscle memory; `t save` is two and reads like a subcommand you have to remember
the spelling of. The doctor already checks for shadowed names, which converts the
real risk from silent breakage into a warning.

**Reopen it if:** someone reports a collision that the doctor's check did not
catch, a second tool in this space claims one of these names, or the list grows
past roughly twenty — at which point it is a vocabulary, not a set of aliases.

## How we'll know it's working

No telemetry — it's a local tool and it should stay one. Three observable proxies,
from dogfooding:

1. **Keystrokes from "an agent needs me" to "I'm typing at it."** Today: notice
   the count, `prefix + a`, find it, `enter`. Target: one key.
2. **How often you open the picker just to *look*.** Every one of those is an
   awareness failure the board should absorb.
3. **Whether you ever lose an agent** — forget it exists, or find it wedged an hour
   later. That's the routing tax billing you late.
4. **Whether the tool has ever been wrong without saying so.** Not "did it break"
   — things break. Did it report confidently while blind? Every instance is a tax
   zero failure, and the fix is never the feature that was wrong, it is the check
   that should have caught it. Count them; the target is zero, and it is the only
   one of these four where the target is not "fewer".

If a proposed feature can't be argued against at least one of those three, it
probably belongs in the non-goals.
