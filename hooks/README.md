# Telling "finished" from "waiting on you"

Claude Code publishes its state into the pane title for free — `⠂ Refactoring the
parser` while it works, `✳ Refactoring the parser` when it stops. `tmux-agents`
reads that and needs no hook to show you `● working` and `○ idle`.

The catch: **`✳` means both "done" and "waiting for your answer".** Those are the
two states you most need to tell apart when four agents are running, and they
render identically.

This hook fixes that. Wire it up and you get a third state:

```
◆  waiting  api-gateway      Should I drop the legacy column?
●  working  billing-worker    Adding retry backoff
○  idle     docs-site         Rewrote the install guide
```

The `◆` count also leads the status line, in orange, because it's the one that
needs you.

## How it works

Claude Code rewrites its pane title continuously, so state can't be published
there from outside — it would be overwritten within a frame. Instead the hook
drops a marker file per pane:

```
~/.cache/tmux-agent-status/<pane-id>.waiting
```

The classifier treats **title says idle (`✳`) + marker present** as waiting. No
daemon, no polling. `$TMUX_PANE` is inherited because hooks are children of the
Claude Code process, which runs in the pane.

## Wiring it up

Add this to `~/.claude/settings.json`, replacing `/path/to/tmux-agents` with
wherever you cloned this:

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [ { "type": "command",
                     "command": "/path/to/tmux-agents/hooks/claude-status-hook.sh set" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "/path/to/tmux-agents/hooks/claude-status-hook.sh clear" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
                     "command": "/path/to/tmux-agents/hooks/claude-status-hook.sh clear" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command",
                     "command": "/path/to/tmux-agents/hooks/claude-status-hook.sh clear" } ] }
    ]
  }
}
```

`set` on the events that mean "I need you", `clear` on the events that mean "we're
moving again". If you already have hooks on those events, add this as another entry
in the same array rather than replacing them.

Then restart your agents — hooks are read at session start — and check with:

```
./bin/tmux-agents-doctor.sh
```

The installer deliberately doesn't do this edit for you: `settings.json` is yours,
it's JSON (so a bad merge is a broken config, not a warning), and you may already
have hooks on these events.

## Other agent CLIs

If your agent doesn't set a pane title at all, you have two options.

**Detect it by process name** — one line in your shell rc, no hook needed:

```bash
export TMUX_AGENT_EXTRA_PROCS="aider codex"
```

Those show up as `◇ running`: present and alive, but with no state to report.

**Or publish a title yourself**, if your tool has hooks. Anything that writes a
single-character glyph, a space, then a label will be picked up as a first-class
agent, with no special case anywhere downstream:

```bash
tmux select-pane -t "$TMUX_PANE" -T "⠂ my-agent · $(basename "$PWD")"
```

Use `⠂` (or any braille character) for working, `✳` for idle, `◆` for waiting on
you. That's the entire contract.
