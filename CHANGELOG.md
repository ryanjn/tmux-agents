# Changelog

Notable changes per release. Dates are the release date, newest first.

## 0.4.4 — 2026-09-21

### Added

- **Follow-ups on quick jobs.** After reading an answer in `prefix + Q` you land
  on a `reply>` prompt; what you type runs as another quick job on the *same*
  conversation (`claude -p --resume`), so a clarifying question keeps its
  context. `ctrl-f` in the list replies to the highlighted job without opening
  it, and `tj reply [ID] TEXT` does it from a shell.
- **Threads.** Follow-ups are marked `↳`, and reading one shows every question
  and answer above it, oldest first.
- A job may now end with **one** question when it genuinely cannot proceed —
  the user can answer it. The default is still to pick a reading and say so.

### Notes

- A follow-up always runs in the original job's folder. Claude Code files a
  conversation under the directory it ran in and only finds it from there, so
  replying from anywhere else would otherwise answer "No conversation found".

## 0.4.3 — 2026-09-19

**Stuck, not thinking** — the other half of routing, and the expensive half.

### Added

- **`⊘` for an agent that claims to be working while nothing moves.** Flagged
  only when the pane has printed nothing *and* its transcript has not grown for
  `TMUX_AGENT_STUCK_MINS` (10; `0` disables). Requiring both signals is the
  design: either alone fires on healthy agents, and a badge that cries wolf costs
  more than the badge is worth.
- Stuck agents sort under waiting, in the same **Needs you** group, and get their
  own red count in the status line.
- **`prefix + j` stops reporting a false all-clear.** With nobody waiting but
  something wedged, it says so rather than "no agent is waiting on you".

### Changed

- The transcript lookup that context tokens use is now shared with stuck
  detection, so the two can never disagree about which conversation they describe.

## 0.4.2 — 2026-09-19

### Added

- **The agent list groups by when you last saw each agent** — Needs you, Today,
  Yesterday, This week, Older, Asleep — in both `prefix + a` and `ta`. Waiting
  agents stay pinned at the top whatever their age, because burying a `◆` under
  a day heading would cost exactly what the list exists to give. Sleepers have no
  last-output time at all, so they are a group rather than a day.
- Group headings are inert in the picker: enter on one does nothing.

## 0.4.1 — 2026-09-19

### Fixed

- **Every quick job failed with `claude: command not found`.** The worker runs
  with the tmux *server's* PATH, which is frozen from whenever the server started,
  and can predate `~/.local/bin` (where Claude Code installs) being on PATH. The
  worker now adds the standard install locations itself, and when `claude` really
  is missing it says how to point at it.
- **Results were pinned to the bottom of the popup.** `less` scrolls a short file
  up from the bottom; it now paints from the top.

## 0.4.0 — 2026-09-17

**Quick jobs.** Ceremony tax: for the ask that is one question and one answer,
even `tq` is too much — you still sit with an agent.

### Added

- **`prefix + Q` — a quick job.** Type a task, press enter, walk away. `claude
  -p` runs it detached in that pane's folder; a tmux message (and a desktop
  notification, under the same `@agent-notify` switch) delivers the first line
  of the answer. `prefix + Q` again lists recent jobs, and enter reads one.
- **`tj`** — the same from any shell: `tj TASK`, `tj`, `tj show`, `tj wait`,
  `tj resume` (carry on as an interactive agent on the job's own session).
- **`⚡N` / `✉N` in the status line** for running jobs and unread answers.

### Fixed before it shipped

- **A job dispatched from the popup died instantly.** Closing a popup HUPs its
  process group, and a backgrounded detach could lose the race to `setsid()`.
  Dispatch now waits on a close-on-exec pipe, so it returns only once the worker
  is in its own session.

## 0.3.1 — 2026-09-14

**Trust the instrument.** Tax zero: everything else in this tool assumes its
readings are true, and a total blackout of agent detection used to report as a
green tick.

### Added

- **The doctor verifies detection instead of merely running it.** Claude Code
  renames the pane's *command* to its version string — a different tmux field,
  set by a different mechanism, from the pane title everything keys on. Any pane
  that looks like an agent by command but is missing from the rows now turns the
  doctor red and names it. Both signals would have to break in the same release
  to go quiet together.
- **CI** — shellcheck (`-S error`) plus both suites on every push and PR.
- **`test/integration.sh`** — drives a real tmux server on its own socket:
  detection, save, the restore round-trip, and the glyph-less failure mode.
  Isolation is structural: a PATH shim makes `tmux` mean the test socket for the
  helpers and everything they shell out to, and the run fails if the default
  server's session list changed.
- **A platform table in the README.** The core is portable; notifications, Quick
  Look, reveal-in-Finder, the battery guard and the launchd jobs are macOS.

### Fixed

- **Detection disagreed with itself.** "Is this pane an agent?" was answered in
  two places under two different rules: `shell/agents.sh` accepted any title
  whose first token was a single character, `tmux-agent-save.sh` required a
  non-alphanumeric one. So a pane titled `a real fix for the parser` was a
  working agent to `ta`, the picker and the status line, and a plain shell to the
  snapshot. `I think so` did it too. Both now apply the stricter rule, pinned
  together by a test. Byte length rather than character length is deliberate:
  awk counts bytes and so does bash outside a UTF-8 locale, which is what launchd
  hands these scripts.
- **Sourcing `quick-agents.sh` returned non-zero with no tmux server running.**
  It ended with `tmux set-hook -g`, which needs a running server rather than just
  the binary, so every first shell after a reboot sourced an rc file that
  returned 1 — enough to abort the rest of startup under `set -e`. Guarded on
  `tmux info`, and all four shell files are now tested for this.

### Notes for anyone extending this

- **`sh` never parses anything in `shell/`, and a test claimed otherwise for
  years.** `sh -n shell/agents.sh` was there on the belief that `run-shell`
  sources it under `sh`. It does not — every `run-shell` invokes a script *file*
  with a bash shebang. The file has 17 array constructs and 8 here-strings and
  has always been openly bash; the check passed only because macOS `/bin/sh` is
  bash in sh-mode, so it was asking bash whether bash could parse bash. The first
  Linux CI run rejected it in 25 seconds. What is load-bearing is the shebang
  contract, now checked instead. `run-shell` itself still runs `sh -c`, so the
  command *string* in the tmux config must stay sh-safe — a different rule, and
  the one that survives.
- **`command tmux` does not reach past a PATH shim.** `command` bypasses
  functions and aliases, not PATH.

### Tests

162 → 180 in `smoke.sh`, plus 15 in the new `integration.sh`.

## 0.3.0 — 2026-09-14

**Survive the machine going away.** A reboot no longer costs anything, idle agents
stop accumulating, and the agents you start often start themselves.

This release reconciles six weeks of work that had been landing in a private
dotfiles repo rather than here — the published tree had stopped at 0.2.4 while the
version in daily use moved well past it. Everything below was already in service
before it was published; what is new is that it is here, generalised, and tested.

### Added

- **Snapshot and restore.** `tsave`, `trestore`, `tsnaps`. The shape of the tmux
  server is written to disk on every change — ten tmux hooks fire a coalescing
  autosave — and replayed afterwards. `trestore --resume` starts the agents too,
  rather than leaving each pane at a shell.
- **Sleep and wake.** `prefix + S` / `prefix + R`, `ctrl-o` in the picker,
  `tsleep` / `twake`. Sleeping exits the process and keeps the conversation; an
  idle agent holds roughly 400MB, and most are waiting on an answer that is not
  coming today. Sleeping agents show `☾`, and enter in the picker wakes one.
- **Ageing.** `tlifecycle` sleeps at 48h idle and shuts down at 7 days. Nothing is
  destroyed: `tarchive` lists what went and `tarchive restore NAME` brings it back
  on its exact conversation.
- **Battery guard.** `tpower` sleeps idle agents below 10% on battery.
- **Favorites.** `tf`, `prefix + F`. A favorite is *defaults for a name* — its
  folder or repo and what window 1 runs — so `t NAME` and the picker honour it
  too, rather than it being a separate launcher.
- **Throwaway agents.** `tq` starts one in a scratch dir under `~/.cache`, with
  `tq done` to discard, `tq keep` to promote and `tq gc` to sweep. For the asks
  that would otherwise leave a folder whose only content is the note explaining
  that the folder exists.
- **`prefix + A` / `prefix + B`** — add an agent to this window on the same
  folder, re-tiling as they accumulate; send one back to where it came from.
- **Desktop notifications** through OSC 777, gated on `@agent-notify`, which is
  read at fire time so `tmux set -g @agent-notify 0` silences it with no reload.
- **Commands outside an interactive shell.** `install.sh` symlinks `tsave`,
  `tdoctor`, `tf` and the rest into `~/.local/bin`, because shell functions are
  invisible to `cron`, `launchd` and `ssh host tsave`. `--no-cli` opts out; a real
  file already at one of those names is never overwritten.
- **`--with-launchd`** installs the 5-minute snapshot job and the battery guard as
  launchd agents. Opt-in: everything works without them, by hand.
- **Login-shell detection.** tmux starts a login shell, which on bash reads
  `~/.bash_profile` and never `~/.bashrc`. If `claude` is an alias in `~/.bashrc`,
  a login shell silently resolves it to the bare binary — the same word with
  different flags, reported nowhere. The installer now checks whether your
  interactive file is reachable from your login file and renders
  `default-command` only when it is not. `--login-shell` / `--no-login-shell`
  override.

### Changed

- `TMUX_AGENT_EXTRA_PROCS` now defaults to empty. Agent CLIs that set no pane
  title are still detected by process name, but only ones you name.
- The `☾` glyph joins `●` `○` `◆` in `ta`, the picker and the status line.
- The doctor checks the rendered `~/.config/tmux-agents/agents.conf` and that
  something sources it, rather than expecting a symlinked `~/.tmux.conf`. It also
  reports the optional launchd jobs as absent-by-choice rather than as faults.
- The roadmap renumbered: reconstruction shipped ahead of the board, so the board
  is now 0.4, handoff 0.5 and ceremony 0.6.

### Fixed

- `tsnaps -l` reported **0 agents** for every session. Columns had been inserted
  into the snapshot ahead of `is_agent` and the listing kept reading the old
  positions. Display only — the snapshots themselves were correct and `trestore`
  reads them by name, so nothing was ever lost. The column order is now pinned by
  a test.
- `trestore` and every wake path record the agent's session id *before* stopping
  the process and resume with `claude -r <id>`. `claude --continue` resolves by
  **directory**, not by agent, so agents sharing a folder would otherwise all come
  back as whichever spoke last.

### Notes for anyone extending this

- **`claude --continue` resolves by directory.** Anything new that restarts an
  agent must record the session id first, or it will silently merge conversations
  — and the failure looks like an agent that lost its memory, not like a bug.
- **`> symlink` writes through the link.** A test that dropped a decoy file over
  an installed command symlink overwrote the real script in `bin/`.
- **The no-process-substitution rule is `shell/agents.sh` only.** `run-shell`
  sources that file under `sh`. The other three are sourced only by bash.

### Tests

107 → 158 checks, and the suite now asserts it leaves the working tree untouched.

## 0.2.4

Context each agent is carrying, shown in `ta` and the picker, read from Claude
Code's transcript and attributed via a hook-recorded path.

## 0.2.1

Last-activity time per agent, the `⚙N` fan-out flag, and a doctor warning when the
tmux server has outlived the terminal that started it.

## 0.2.0

Never wonder who needs you: `prefix + j`, waiting times, waiting-first ordering in
the picker, and opt-in desktop notifications.
