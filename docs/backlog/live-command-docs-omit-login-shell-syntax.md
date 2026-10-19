---
worth: yes
where: site/commands.html
added: 2026-10-18
---
# Live --command docs do not say the line uses the login shell's syntax

In Live sessions mode `session new --command` and `session restart --command` hand the line to the
persistent login shell as a zmx payload. `site/commands.html` and
`plugins/agterm/skills/agterm/reference.md` say "shell operators are interpreted" without naming which
shell parses the line.
Since #761 that shell can be fish, which parses the same line with fish rules: fish 4.9 rejects
`if ...; then ...; fi`, `[[ ... ]]` and heredocs. Both pages should say the line is parsed by the user's login shell,
in one clause.
