---
worth: later
where: agtermCore/Sources/agtermCore/LinkPolicy.swift
added: 2026-11-03
---
# upstream's markdown and text pages overlap the fork's agterm-open-path route

Upstream #866 (`fb614c93`) renders a ⌘-clicked `.md` file as a themed overlay page, and #874 (`9b8926a5`)
shows a ⌘-clicked source or log file read-only at a `path:line`, resolving relative paths against the pane's
cwd (`LinkPolicy.locations`). The fork already routes the same clicks through `.openPath` to the
`agterm-open-path` helper (plannotator for markdown, revdiff for code), with its own `:N` parsing and its
own cwd resolution in the script.

## What happened

Not reproduced; derived from reading `LinkPolicy.disposition(for:)` during the 2026-11-03 upstream merge.
A ⌘-click on `docs/plan.md` in a pane: `LinkPolicy.helperLink` claims it first, because `md` is in
`openPathExtensions`, so the click runs `agterm-open-path` and upstream's markdown page never sees it. The
same file as `file:///…/plan.md` skips the fork's schemeless branch and opens upstream's page. One file,
two viewers, chosen by how the program printed the link. With the helper not installed, the schemeless
click does nothing at all, while upstream's page would have shown the file.

## Why it is worth keeping

If upstream's pages are good enough for some of these extensions, the fork can drop them from
`openPathExtensions` and delete the matching helper branches, which is less merge surface on a flagged
file. If they are not, the fork could still fall back to upstream's page when the helper is missing. The
merge stopped on which route wins; this item is the longer adopt-or-not question.
