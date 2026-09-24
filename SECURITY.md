# Security

Please report a vulnerability privately through GitHub's
[Report a vulnerability](https://github.com/kjg8619/PackTrace-app/security/advisories/new)
(Security advisories) rather than in a public issue.

## What PackTrace touches

- **Reads** (read-only) the usage records of AI tools you connect, under your
  home folder (for example `~/.claude/projects`, `~/.codex/sessions`), and
  keeps only identifiers, model/provider names, times and token counts.
- **Writes** its own SQLite databases, image cache and backups under
  `~/Library/Application Support/PackTrace`.
- **Network**: the TCGdex API and asset host (card data and images). The
  optional artwork tool downloads only the URLs you register. Nothing is
  uploaded; there is no account or telemetry.

Reports about any of these paths — reading more than it should, storing
content it should not, following a path outside the connected folder, or
parsing a crafted log into a crash — are especially welcome.
