# Contributing to claude-bridge

Thanks for your interest. This is a small project on purpose — every PR is
weighed against the goal of keeping the hook short enough to audit in five
minutes.

## Easy wins

- **More sync providers.** `detect_cloud_dir()` in `bin/bridge-hook.sh` is a
  short list of glob patterns. Adding Box, Nextcloud, Syncthing, Resilio,
  pCloud, etc. is mostly one line each plus a manual test.
- **Linux/WSL polish.** Tested on macOS; reports and fixes from Linux/WSL
  users are very welcome.
- **Windows native.** A PowerShell port (`bin/bridge-hook.ps1`) and a
  `install.ps1` would be a great addition.
- **Docs.** Animated demo gif, screenshots from the OneDrive mobile app,
  worked examples for Dropbox / iCloud users.

## Harder, please open an issue first

- Per-session inbox subfolders (v1.1).
- `/new <title>` / `/task <id>` wrapper around `claude -p --resume`.
- Power Automate flow templates.
- Encryption-at-rest.

## Running the test loop

There is no test harness yet — manually:

1. `./install.sh` into a throwaway env (or pass `--settings` to `claude` when
   testing changes, so your global config is untouched).
2. `mkdir -p /tmp/cb-test/{inbox,outbox,archive} && touch /tmp/cb-test/.enabled`
3. `CLAUDE_BRIDGE_DIR=/tmp/cb-test CLAUDE_BRIDGE_TIMEOUT=30 claude -p --settings /path/to/test-settings.json "say HELLO"` in one terminal.
4. From another terminal, drop a reply file: `echo "now say BYE" > /tmp/cb-test/inbox/r.md`.
5. Verify the same session continues and finally exits, archive folder
   populates, and `~/Library/Logs/claude-bridge.log` looks sensible.

## Style

- POSIX-ish bash where possible. `set -u` is on; keep it on.
- Run `shellcheck bin/bridge-hook.sh` — no new warnings.
- No new runtime deps without discussion. `bash` and `jq` are it.

## License of contributions

By submitting a PR you agree your contribution is licensed under the same MIT
license as the rest of the project.
