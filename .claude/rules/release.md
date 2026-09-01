---
paths:
  - "scripts/release.sh"
---

## Release (`scripts/release.sh`)

- **Releases are local; there is no `release.yml`.** Run `scripts/release.sh <version> --publish`. The
  script builds Release, signs/notarizes/staples the app and DMG when a signing identity exists, creates
  the tag and GitHub release, and uploads the DMG. The cask bump runs only with a tap configured. The DMG
  container must be codesigned before notarization or `spctl` rejects `hdiutil`'s unsigned image.
  Without `--publish`, the dry run stops before upload. Upstream signs as
  `Developer ID Application: Brave Elk LLC` with the `agterm-notary` profile and taps
  `umputun/homebrew-apps`; this fork has none of the three — see below.
- Developer ID signing is inside-out: `agtermctl` and zmx are signed first with no entitlements, then the
  app is sealed with its TCC entitlements. The script rejects either helper if app entitlements leak into it.
- Before writing or committing a release section, put the exact `CHANGELOG-fork.md` text in a temp file and
  pass it through the `draft-approval` skill's `draft-review.sh`; address annotations and get explicit
  chat approval. `release_notes()` publishes that section as the GitHub release body.
- **Commit and push the changelog and website version to the trunk before `release.sh --publish`.**
  `gh release create "$TAG"` has no `--target` (`release.sh:209`), so it tags whatever the resolved repo's
  default branch points at, not local `HEAD`. The script pushes no repository; the maintainer must push
  the main repo.

### Cutting a release from this fork

The script was written for the upstream clone. Four of the five things that blocked it here are now fixed
in the script itself; the fifth is a standing condition, not a bug:

- `gh` resolution is SETTLED, not automatic: `upstream` is a GitHub remote too, so without
  `remote.origin.gh-resolved` this clone resolves to `umputun/agterm` and `gh release create`
  (`release.sh:209`) would publish onto UPSTREAM's repo. `gh repo set-default p4elkin/agterm-vim` wrote
  that config on 2026-08-16. Re-check with `gh repo view --json nameWithOwner` in a fresh clone, which
  starts without it. Reading upstream still works with an explicit `-R umputun/agterm`.
- the manifest gate reads the fork's trunk: `git fetch -q origin main` and `origin/main:<manifest>`.
  See [[fork-merge]] for the remotes.
- the Homebrew cask bump is OFF. `TAP_REPO` defaults to empty and the whole step is skipped; set
  `AGTERM_TAP_REPO=<owner>/homebrew-<name>` to turn it back on, which also restores the Homebrew line in
  the release body.
- **releases are UNSIGNED here**, because there is no active Apple developer account. Every
  sign/notarize/staple block already keys off `SIGNED`, which auto-detects the keychain, so they skip on
  their own — nothing was removed. Publishing still needs `AGTERM_ALLOW_UNSIGNED=1`, deliberately, so an
  unsigned upload is always a typed choice:

      AGTERM_ALLOW_UNSIGNED=1 scripts/release.sh <x.y.z> --publish

  ⚠️ The release body says so too, and must keep saying so: macOS quarantines an unsigned DMG and reports
  the app as damaged, so the note carries the `xattr -dr com.apple.quarantine` line users need. Restoring
  the signed wording without a real certificate sends every downloader into that error.

Fork release notes live in `CHANGELOG-fork.md`, never `CHANGELOG.md`: [[fork-merge]] takes upstream's
copy whole on every rebase, so a note written there is erased by the next daily run. Upstream has no such
file, so it never conflicts. `release.sh` publishes a section from it as the release body via
`--notes-file`; the `draft-approval` review above applies to that text.

### The two fork docs, and why a feature touches both

`CHANGELOG-fork.md` and `FORK-NOTES.md` describe the same fork and are not substitutes for each other.
The changelog is ordered by release and records deltas, which is what `release.sh` publishes.
`FORK-NOTES.md` is ordered by feature and records the current state, which is what someone reads to find
out what this build is.
A delta list answers "what changed in v0.23"; it cannot answer "does this fork wrap panes in zmx".

⚠️ So a landing feature writes to both, in the commit that lands it, and neither entry is a copy of the
other.
The catalog line is one or two lines naming the feature and pointing at the `.claude/rules` file, patch
README or cookbook preset with the real detail — it must not grow into a second changelog.
The changelog entry is user-facing prose about what you now get, including any trap a user would
otherwise read as a bug.

⚠️ The same commit also answers one merge question: does this feature add a file to `flagged` in
[[fork-merge]]'s frontmatter? Landing is the only moment anyone knows, and a feature that touches key
routing while adding no test under `agtermTests/` is the case that needs it — `make test-app` is the
only gate compiling that target, so behaviour with no test there is invisible to every gate. Say no
explicitly rather than skipping the question; the merge job asks again later either way.

Nothing checks this.
`ci.yml` triggers on `master` and the fork lives on `main`, so no CI job runs on the fork at all, and
adding one means editing a workflow file that already collides on every upstream merge ([[fork-merge]]).
The rule has failed in both directions already: `FORK-NOTES.md` said "two separable features" until nine
had shipped, and the recency dwell reached users with no changelog entry.
Both were found by writing the catalog, not by any tooling.
- Manually set `site/index.html`'s `SoftwareApplication.softwareVersion` in that same pre-release push;
  `release.sh` does not edit it. Cloudflare Pages deploys `site/` on push, and the DMG links already use
  GitHub's latest release.
