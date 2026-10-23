---
worth: later
where: cookbook/
added: 2026-10-22
---
# port webrev as a cookbook recipe

webrev (`~/.dot-files/claude/skills/webrev`: `SKILL.md`, `scripts/webrev.py`, `assets/page.html` plus
vendored markdown-it 14.1.0 and highlight.js 11.11.1) reviews a non-diff document in a chromeless `--js`
HTML overlay and hands revdiff-format notes back through `session.overlay.submit`. It fits the cookbook,
following `cookbook/html-doc-overlay`'s layout (Claude Code skill with `scripts/` and `assets/`).
Eugene deferred the port and requested this reminder. Before porting, confirm the workflow has had
sustained real-session use, as `cookbook/CONTRIBUTING.md` requires.
The note-loss bug on Submit/Cancel found during the assessment is fixed in dot-files `7ad83b22`.

Port checklist:

- `webrev.py` calls `agtermctl` directly; use `os.environ.get("AGTERMCTL") or "agtermctl"`.
- `SKILL.md` names personal tooling: draft-approval's `draft-review.sh`, the planning plugin, revdiff as
  a router. Keep the annotation format as a neutral reference; revdiff is not a runtime dependency.
  Stay Claude Code-specific (`CLAUDE_SKILL_DIR`, the 600 s tool timeout).
- Move the embedded `--test` suite to `test_webrev.py`, which is what CI runs.
- ruff 0.16.10 (the CI pin) reports 2 SIM117 errors in `webrev.py`.
- Ship the full upstream license texts beside the vendored libs; the minified banners name the license
  only. Keep the ~251 KB vendored: a CDN would run remote code in a page with bridge access.
- Requirements: agterm 0.35.0 (file-page `--chromeless`, #678; submit/result came in 0.34.0, and the
  page closes via `session.overlay.close`, so 0.36.0's `window.close` is not needed), Python 3.10
  (`str | None` in dataclass fields).
- Limits: opening replaces a HUD in the session-wide slot and refuses an existing page or program;
  an interrupted waiter leaves the generated page file in `$TMPDIR/webrev`; `result <page-id>` recovery needs the same running app and
  only the last 32 finished outcomes are kept (`HtmlPageOutcomes.retainedLimit`), while a completed
  `--output` backup file survives independently; ⌘W or an external overlay close drops an open note,
  since it bypasses the page's JS.
- README with the six headings and an index row under "Agent status and workflows".
