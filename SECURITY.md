# Security

Lumen reads your files to index them, stores your clipboard history and runs
programs on your behalf, so security reports are taken seriously.

## Reporting a vulnerability

Please report it privately through
[GitHub's private vulnerability reporting](https://github.com/Osmait/lumen/security/advisories/new)
rather than in a public issue. Include what an attacker could do, how to
reproduce it and the version or commit you tested.

You should get an answer within a week. Once a fix is ready it is released,
and the advisory published, crediting you unless you prefer otherwise.

## What counts

For example:

- a file name, file contents, document or clipboard entry that makes Lumen
  run something, crash, hang or read files it should not;
- Lumen's data (clipboard history, indexes, extracted text) readable by
  other users;
- settings or script headers that inject arguments into the programs Lumen
  starts.

Lumen makes no network connections; anything that makes it do so is a bug
too.

Only the latest release and the `main` branch get fixes.
