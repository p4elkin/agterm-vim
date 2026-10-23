---
worth: maybe
where: agterm/Ghostty/GhosttyCallbacks.swift:action
added: 2026-10-21
---
# agent status outlives its agent at the next prompt

A hook-driven agent that dies without its exit hook leaves the pane's `active`/`blocked` glyph lit
(`cookbook/truthful-agent-lights`, "the agent dies, the glyph lives"). The shell integration
(`agterm/Resources/agent-status/shell/integration.sh`) clears matched agents at the next prompt, but
its default set excludes Claude, Codex, Pi and OpenCode, so the hook agents keep the gap.

Candidate: handle `GHOSTTY_ACTION_COMMAND_FINISHED`, present at the current pin and dropped by the
`default:` arm of `action`, and clear only active/blocked status owned by the finishing pane, preserving
completed. Open before it is a fix:

- it comes from the shell's OSC 133 prompt marks, not process exit, so an agent run directly as the
  pane's command never produces it, and a reattach can miss the start mark that gates the finish;
- `applyControlStatus` protects another pane's `blocked` but not its `active`, so the clear must match
  the status owner's pane exactly or a finishing split erases a sibling agent still working;
- a future `error` state that should survive exit must not be cleared by it.

Surfaced investigating https://github.com/umputun/agterm/discussions/794.
