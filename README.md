# claude-bridge

**Talk to your laptop's Claude Code session from your phone — using only a
synced cloud folder.**

`claude-bridge` is a tiny `Stop` hook for [Claude Code](https://claude.com/claude-code).
At the end of every model turn, it writes the assistant's reply to a file in a
folder of your choice and **blocks until you drop a reply file in the same
folder**. Then the same Claude session continues with your reply as the next
user turn.

Point that folder at OneDrive / Dropbox / iCloud Drive / Google Drive /
Syncthing and you can read the reply on your phone, type a message in any text
app, save it, and have Claude pick it up — without installing anything on the
laptop beyond this hook, and without granting any new cloud-app permissions.

```
   on the laptop                              on your phone
 ┌──────────────────┐                      ┌────────────────────┐
 │ claude (any cwd) │                      │ OneDrive / Dropbox │
 │                  │                      │ / iCloud / GDrive  │
 │  …turn ends…     │                      │   mobile app       │
 │       │          │                      │                    │
 │       ▼          │   ~/.../ClaudeBridge │  outbox/*.md  ─── you read
 │  Stop hook ──── writes outbox/, polls ─►│                    │
 │       │          │   inbox/             │  inbox/*.md   ◄── you write
 │       ▼          │                      │                    │
 │  decision:block  │◄── reply found ──────│                    │
 │  continue turn   │                      └────────────────────┘
 └──────────────────┘
```

## Why

Sometimes Claude Code is mid-task on your laptop, you walk away, and it ends
up needing input. Or it finishes a long job and you'd like to see the result
without unlocking the laptop. With `claude-bridge`, *any* synced folder
becomes a two-way conversation channel.

In the original use case the laptop was a low-rights corporate Mac and the
only mobile-accessible apps were the Microsoft 365 suite — so OneDrive sync
was the **only** path that needed zero new permissions, no Azure AD app
registration, no Graph API, no IT involvement. The same pattern works just as
well with any other sync provider.

## Features

- **Drop-in.** One hook script, no daemon, no service.
- **Cloud-agnostic.** Auto-detects OneDrive, Dropbox, iCloud Drive, Google
  Drive on macOS / Linux / WSL. Override with `CLAUDE_BRIDGE_DIR`.
- **Dormant by default.** Installs globally but does nothing until you
  `touch $BRIDGE_DIR/.enabled`. Removing that file is the kill-switch.
- **Loop-safe.** Honors Claude's `stop_hook_active` flag so sessions can
  actually end.
- **Timeout fallback.** If no reply arrives within `CLAUDE_BRIDGE_TIMEOUT`
  (default 30 min), the session exits normally.
- **Zero dependencies** beyond `bash` and `jq`.

## Install

```sh
git clone https://github.com/<you>/claude-bridge.git
cd claude-bridge
./install.sh
```

The installer copies the hook to `~/.claude-bridge/bridge-hook.sh` and
registers it in `~/.claude/settings.json` under `hooks.Stop` (an existing
`settings.json` is backed up to `settings.json.pre-claude-bridge.bak` and
hooks are merged, not overwritten).

## Activate

The hook is installed but inert. Activate it for a chosen folder:

```sh
# Pick any folder; ideally one synced by your phone's cloud client.
BRIDGE="$HOME/Library/CloudStorage/OneDrive-YourTenant/ClaudeBridge"
# BRIDGE="$HOME/Dropbox/ClaudeBridge"
# BRIDGE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBridge"

mkdir -p "$BRIDGE"/{inbox,outbox,archive}
touch "$BRIDGE/.enabled"

# Make it permanent (optional — without this, auto-detection picks the first
# synced folder it can find).
echo "export CLAUDE_BRIDGE_DIR=\"$BRIDGE\"" >> ~/.zshrc
```

Disable instantly: `rm "$BRIDGE/.enabled"`. Re-enable: `touch` it again.

## Use

1. Start any `claude` session as usual.
2. When the model finishes a turn, the hook writes
   `outbox/<session>-<utc>.md` and waits.
3. On your phone, open the cloud app, read the latest file in `outbox/`,
   then create any `.md` or `.txt` file in `inbox/` with your reply.
4. Within a couple of seconds the hook picks it up, archives it, and Claude
   continues with your reply as the next user turn.
5. If you don't reply within the timeout, the session exits normally.

## Configuration

All env vars are optional.

| Variable                | Default                                              | Meaning                                                      |
| ----------------------- | ---------------------------------------------------- | ------------------------------------------------------------ |
| `CLAUDE_BRIDGE_DIR`     | first detected sync folder, else `~/.claude-bridge/default` | Folder containing `inbox/`, `outbox/`, `archive/`, `.enabled` |
| `CLAUDE_BRIDGE_TIMEOUT` | `1800`                                               | Seconds to wait for a reply before letting Claude exit       |
| `CLAUDE_BRIDGE_POLL`    | `2`                                                  | Inbox poll interval in seconds                               |
| `CLAUDE_BRIDGE_LOG`     | `~/Library/Logs/claude-bridge.log` (macOS) / `~/.claude-bridge/claude-bridge.log` | Log file                                                     |

## How it works

Claude Code's `Stop` hook fires at end of turn and may print
`{"decision":"block","reason":"<text>"}` to tell the harness *don't stop —
continue with this content as the next user turn*. The hook script:

1. Reads `session_id`, `transcript_path`, `stop_hook_active` from stdin.
2. If `stop_hook_active=true` (we already injected once), exits — lets the
   session truly stop next time.
3. If `$BRIDGE_DIR/.enabled` is missing, exits (kill-switch).
4. Polls the transcript JSONL briefly for the flushed assistant text, then
   writes `outbox/<session>-<ts>.md`.
5. Polls `inbox/` for any new `.md` or `.txt`. On finding one, archives it
   and prints the `decision:block` JSON.
6. On timeout, exits silently and the session ends.

## Compatibility

- Tested on macOS (zsh + jq from Homebrew).
- Should work on Linux/WSL — the cloud-folder auto-detection covers
  `~/OneDrive*`, `~/Dropbox`, `~/Google Drive`. PRs welcome for more.
- Requires `bash`, `jq`, GNU/BSD `date` and `ls`.

## Roadmap

- v1.1: per-session inbox subfolders so multiple concurrent Claude sessions
  don't share an inbox.
- v1.1: a thin wrapper around `claude -p --resume` so a single inbox can
  start new sessions on `/new <title>` and route messages by `task_id`.
- v1.2: optional [Power Automate](https://make.powerautomate.com/) flow
  templates that turn `[Claude]` emails into inbox files and outbox files
  into emails / Teams self-chats — for users who want a chat UX instead of
  the OneDrive app.

## License

MIT. See [LICENSE](LICENSE).
