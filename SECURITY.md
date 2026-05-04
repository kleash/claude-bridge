# Security

## What this hook can and can't do

`claude-bridge` runs as a `Stop` hook for the Claude Code CLI in your user
context. It only:

- reads the JSON Claude Code passes on stdin,
- reads your Claude Code transcript file at `transcript_path`,
- writes / reads files under `$CLAUDE_BRIDGE_DIR`,
- writes a log line.

It does **not** open any network sockets, listen on any port, call any API,
or escalate privileges.

## Threat model

The contents of your `outbox/` and `inbox/` files transit through whichever
cloud-sync provider you point `CLAUDE_BRIDGE_DIR` at (OneDrive, Dropbox,
iCloud Drive, Google Drive, Syncthing, …). Treat that channel exactly as you
would treat manually saving the same text to that folder yourself. If your
employer or threat model considers any of those providers off-limits for the
content you're discussing with Claude, **don't enable the hook** for that
folder.

The hook does not exfiltrate Claude's full transcript — only the last
assistant turn's text is written to `outbox/`.

## Reporting a vulnerability

If you find a security issue, please open a private security advisory on
GitHub or email the maintainer rather than filing a public issue.

## Anything that touches `~/.claude/settings.json`

`install.sh` and `uninstall.sh` modify `~/.claude/settings.json` with `jq`
merges. Both write a backup first (`*.pre-claude-bridge.bak` /
`*.pre-uninstall.bak`). Inspect the diff after running if your settings are
precious.
