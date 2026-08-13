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
