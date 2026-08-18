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
- Before writing or committing a release section, put the exact `CHANGELOG-vim.md` text in a temp file and
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
  See [[fork-rebase]] for the remotes.
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

Fork release notes live in `CHANGELOG-vim.md`, never `CHANGELOG.md`: [[fork-rebase]] takes upstream's
copy whole on every rebase, so a note written there is erased by the next daily run. Upstream has no such
file, so it never conflicts. `release.sh` publishes a section from it as the release body via
`--notes-file`; the `draft-approval` review above applies to that text.
- Manually set `site/index.html`'s `SoftwareApplication.softwareVersion` in that same pre-release push;
  `release.sh` does not edit it. Cloudflare Pages deploys `site/` on push, and the DMG links already use
  GitHub's latest release.
