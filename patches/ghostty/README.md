# libghostty patches

Patches applied by `scripts/setup.sh` to the upstream tree at `GHOSTTY_REV` before `zig build`.
Every patch here is additive and upstreamable; none changes behavior for a caller that does not
opt in. When `GHOSTTY_REV` moves, `git apply` fails loudly rather than silently dropping one.

## 0001-surface-realize-api.patch

Exports `ghostty_surface_set_realized(surface, bool)` so an embedder can release a hidden
surface's GPU resources and rebuild them on return.

**Why.** Every libghostty surface holds a renderer with a swap chain of `swap_chain_count = 3`
frame states. Each frame state owns a full-pane IOSurface render target plus its own copy of the
grayscale and color font atlas textures. Nothing is released while the surface lives, so a
session kept alive but hidden costs the same GPU memory as the visible one. Measured on a real
workspace: 129 surfaces, 387 IOSurfaces (exactly 3 per surface), 6.9 GB of an 8.0 GB physical
footprint in graphics categories.

`ghostty_surface_set_occlusion` does not help. It stops the display link and lowers the render
thread's QoS, but leaves every allocation in place.

**What it does.** The renderer already has `displayRealized` / `displayUnrealized`, written for
the GTK apprt, which tear down and rebuild the swap chain and shaders. They are unreachable from
the C API, and in a macOS build nothing references them, so Zig never emits them at all. The
patch adds a `realized` renderer-thread message, a `Surface.realizedCallback`, and the C export,
following the existing `visible` / `occlusionCallback` / `ghostty_surface_set_occlusion` chain
line for line.

The shell and terminal state are untouched. An unrealized surface keeps reading its pty; the
first frame after realizing shows everything that arrived meanwhile.

**Pairing rule.** The embedder must alternate realize and unrealize. `displayRealized` opens with
`assert(self.swap_chain.defunct)`, so an unpaired realize would panic in a safe build. The
message handler drops a repeated call in either direction before it reaches that assert.

**Upstream status.** Not submitted. The underlying problem is ghostty-org/ghostty#12032, which a
bot auto-closed 16 seconds after it was opened because the reporter was not vouched; the
discussion repost (#12034) has no replies. This patch is the mechanism half only — it does not
make ghostty itself release resources for its own hidden tabs, which is what #12032 asked for.

## 0002-link-config.patch

Implements the `link` config option, which upstream declares but cannot parse, and adds an
`open:<template>` action so a match that is not itself a URL can resolve to one.

**Why.** `link` is documented, the `Link` type exists, and the renderer already searches for
regex links — but `RepeatableLink.parseCLI` is `return error.NotImplemented` and the option's own
doc comment says `TODO: This can't currently be set!`. So the whole feature is unreachable from
config. agterm wants it for cross-agent message ids and `path:line` pointers, which are not URLs
and so cannot be matched by the built-in URL link.

**What it does.**

- `RepeatableLink.parseCLI` parses `link = <action>,<regex>`, and `formatEntry` renders it back.
  The action comes FIRST and the split is on the first comma. That ordering is the point: a regex
  may contain a comma of its own (`\d{2,4}`), an action name never does, so everything after the
  first comma is the regex verbatim and no escaping rule is needed.
- Adds `Link.Action.open_template`, a `[]const u8` opened after `$0` is replaced by the full
  matched value. `Link.expandTemplate` does the substitution.
- Wires it into the two `switch (link.action)` sites in `Surface.zig`: the hover preview shows the
  expanded URL rather than the raw match, and `processLinks` opens it. `resolvePathForOpening` is
  deliberately NOT applied on this path — the template already states what the match means, so
  guessing at it as a path would fight the config.
- A configured link gets the same highlight as the built-in URL link,
  `hover_mods = ctrlOrSuper`, so it behaves like the link that is always there (cmd-click on
  macOS).

**Two things the union payload forced.** `Link.clone` copied the action by value, which would
leave a clone's template pointing into the original's memory, so it now dupes the slice.
`Link.equal` used `std.meta.eql`, which compares a slice payload by POINTER — two identical
templates would read as different and every config reload would look like a change. It now
compares by value.

**Not user-specifiable:** anything other than `open` and `open:<template>` is rejected, including
the internal `_`-prefixed actions.

**Tests.** Five, in `Config.zig` beside the existing parse tests. The one that matters is the
comma case: `open,ab\d{2,4}cd` must keep its quantifier, which is the whole reason the action
comes first. It has teeth -- swapping `indexOfScalar` for `lastIndexOfScalar` fails that test and
only that test. The rest cover both actions, `expandTemplate` (repeated `$0`, a literal `$1` left
alone, and a template with no placeholder at all), and the rejections.

⚠️ **The regex is the security boundary, and that is not new.** A template expands into a URL
handed to the system opener, with `$0` substituted verbatim — but a plain `open` already hands
the raw matched text to the same opener, so a template is that same exposure with a prefix, not a
new class. Nothing here executes a command. An action that ran one would be a different
proposition: any text on screen matching the regex would become a click-to-execute trigger.
