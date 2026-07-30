# Roadmap

**Goal: make agent management seamless, and cut the cognitive cost of switching
between agents.**

Everything below is judged against that one sentence. A feature earns a place only
if it removes a decision, a lookup, or a context rebuild — not because it would be
neat to have.

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

## Where 0.2.0 lands

| Tax | Covered by | Gap |
|---|---|---|
| Routing | `prefix + j`, waiting times, waiting-first order, opt-in notifications | **Largely handled.** Next gap: nothing tells you an agent is *stuck* rather than thinking |
| Reconstruction | Screen preview, branch + uncommitted count, seeded `CLAUDE.md` | No diff — you can see that work exists, not what it is |
| Awareness | The picker list | One agent at a time, and only while the popup is open |
| Handoff | `ctrl-y` copies a path | You paste it yourself, into an agent you navigate to yourself |
| Ceremony | `t NAME`, `ts`, folder + notes auto-created | One shape of session only; no worktrees, no multi-window profiles |

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

## 0.3 — See everything at once

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
| **Filter keys in the picker** (waiting only / this folder only) | Narrows five agents to the two that matter | S |
| **"What is this agent doing to my machine?"** — ~~child processes spawned~~ (**`⚙N` shipped 0.2.1**), and whether it's writing outside its own folder | Added 2026-07-30 after an agent fanned out hundreds of `op item edit` processes across a password vault. The screen preview said "Running 1 shell command"; the only real signal was a storm of macOS permission dialogs. Status tells you an agent is *busy*, never that it's busy doing something with a blast radius | M |
| ~~**Doctor: warn when the tmux server outlives the app that launched it**~~ — **shipped 0.2.1** | Same day: a server started from iTerm 22 hours earlier meant every macOS permission prompt named a dead app, and no amount of clicking Allow could stick. Nothing surfaced that. `#{pid}` + start time + the stale `TERM_PROGRAM` in the global env is all it takes | S |

⚠️ The board is where shell scripting starts to strain — it wants live refresh and
layout. If it turns into a fight, that's the moment to consider a small compiled
TUI for *that view only*, keeping everything else as shell. Deciding that early is
cheaper than discovering it late.

## 0.4 — Move work between agents

*The handoff is the switch. Make it one key.*

| Item | Why it cuts switching cost | Size |
|---|---|---|
| **Send a path to another agent** — from the file browser, pick a target agent, and it lands in that agent's prompt | Today: copy, navigate, paste, return. This is the single most common cross-agent action and it currently costs four context switches | M |
| **Send the current selection** (copy-mode text) to an agent | Same shape, for error messages and log lines rather than paths | M |
| **Leave a note for an agent** — append to its `CLAUDE.md` from the picker | Discovered by using it: the seeded `CLAUDE.md` turned out to be the natural channel for telling *another* agent something, because Claude Code loads it at session start. Cheaper than the send-to-prompt version and it survives the agent restarting | S |
| **Changed-files view in the browser** — files touched since the agent started, `ctrl-d` for a diff | Turns "what did it do?" into a keystroke instead of a review session | M |

## 0.5 — Start work without ceremony

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
| **CI** — `smoke.sh` + shellcheck on push | The bug classes here are subtle enough that a green tick matters (see the notes below) | S |
| **Verified on Linux** | The file browser already degrades to `xdg-open`; nobody has run the suite there | M |
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
  it. The board view in 0.3 is the one place that assumption gets tested.

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

## How we'll know it's working

No telemetry — it's a local tool and it should stay one. Three observable proxies,
from dogfooding:

1. **Keystrokes from "an agent needs me" to "I'm typing at it."** Today: notice
   the count, `prefix + a`, find it, `enter`. Target: one key.
2. **How often you open the picker just to *look*.** Every one of those is an
   awareness failure the board should absorb.
3. **Whether you ever lose an agent** — forget it exists, or find it wedged an hour
   later. That's the routing tax billing you late.

If a proposed feature can't be argued against at least one of those three, it
probably belongs in the non-goals.
