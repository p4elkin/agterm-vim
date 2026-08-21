# Turn marks depend on the agent complying, and that is not the fix we want

Conversation bookmarks originally had agterm write the turn mark into the pane's pty. Measured
2026-08-21 in a live pane: that never works where bookmarks are actually used. A write to agterm's
surface pty and a write to the inner pty of the zmx wrapper were both invisible. Every layer that
owns a screen repaints it from its own buffer — the zmx client, then Claude Code's own TUI — so the
injected bytes are wiped before the next frame and never enter scrollback. `session.search` only
ever finds scrollback.

The shipped workaround is the `context-canary` trick: `session mark` counts, the `UserPromptSubmit`
hook prints the new number as an instruction, and the AGENT echoes `── ⟦N⟧ ──` into its own reply.
The agent's reply is real scrollback, so the mark survives and the jump works.

## What is still wrong

- The mark only exists if the agent complies that turn. A skipped one silently costs that turn its
  jump target. Instruction adherence decays over a long session, which is the exact thing the
  `context-canary` skill exists to measure.
- Every reply carries a marker line, and every turn spends a little context on the instruction.
- Only Claude Code is wired. Codex and the other wrappers under
  `agterm/Resources/agent-status/` have no mark path at all.

## The deterministic fix

Capture and restore a scrollback offset in the app instead of searching for text. Today
`session.search` is the only thing that moves a pane's viewport, and nothing reads where the
viewport sits — the whole `ghostty_surface_*` C surface was checked when bookmarks were designed.
So this needs new libghostty surface work first, plus a check that an offset means anything in a
zmx-wrapped pane, where zmx and not the shell owns the screen.

Until then the pty write in `ControlServer+Mark.swift` stays: it is dead for an agent pane but
correct for a pane with no full-screen TUI in it.
