# claude-bridge

> **Talk to your laptop's [Claude Code](https://claude.com/claude-code) session from your phone — using nothing but a synced folder. No API keys, no servers, no IT permissions, no inbound network access.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20WSL-lightgrey)
![Dependencies](https://img.shields.io/badge/deps-bash%20%2B%20jq-blue)
![Status](https://img.shields.io/badge/status-works%20today-brightgreen)

If you've ever:

- left Claude Code running on your **corporate laptop** and walked away,
- realized it's stuck waiting for input you can't give it from your phone,
- or wished you could just **send Claude a message from Outlook / OneDrive / iMessage / Telegram** and have it pick up the work,

`claude-bridge` is a 200-line `Stop` hook that fixes exactly that. No Anthropic
API key, no Azure AD app registration, no Microsoft Graph, no daemon, no
inbound port. Just a folder.

---

## TL;DR

```sh
git clone https://github.com/kleash/claude-bridge.git
cd claude-bridge && ./install.sh

# pick any folder your phone can reach (OneDrive, Dropbox, iCloud, GDrive…)
BRIDGE="$HOME/Library/CloudStorage/OneDrive-YourTenant/ClaudeBridge"
mkdir -p "$BRIDGE"/{inbox,outbox,archive} && touch "$BRIDGE/.enabled"
export CLAUDE_BRIDGE_DIR="$BRIDGE"

# now run claude as you always do
claude
```

When Claude finishes a turn:

- A markdown file lands in `outbox/` — read it on your phone.
- Drop a `.md` or `.txt` reply into `inbox/` — Claude continues with it as the
  next user turn, in the **same session**.

That's the whole product.

---

## The "behind the corporate firewall" trick

Most "let Claude phone home" solutions die immediately on a locked-down
corporate laptop:

| Approach                              | Needs IT?                          | Works?                          |
| ------------------------------------- | ---------------------------------- | ------------------------------- |
| Microsoft Graph API + Teams/Outlook   | App registration / admin consent   | Often blocked by tenant policy  |
| Inbound webhook (ngrok, Cloudflare)   | Inbound firewall rule              | Almost always blocked           |
| SSH back to your laptop               | VPN + key auth + open port         | Usually blocked, IT will notice |
| Self-hosted message queue             | Server, auth, opens new attack surface | Shadow IT — risky          |
| **OneDrive sync folder**              | **Nothing — you already have it**  | **Just works**                  |

OneDrive (or Dropbox, iCloud, Google Drive) is already signed in on the
laptop, syncs both ways automatically, and your phone has the app installed.
The laptop never opens an inbound port. Microsoft Graph never enters the
picture. `claude-bridge` simply uses that already-authorized sync as a tiny
two-way message bus. **That's why this works on the strictest enterprise
laptops where every other approach fails.**

---

## Demo

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

A real round-trip from the test suite (Claude resumed from a phone-side
reply, in the same session):

```
[15:13:46] wrote outbox/1e73f2e1-…20260504T151346Z.md          # Claude said its piece
[15:15:32] consumed inbox/input.md → archive/…-input.md        # you replied via OneDrive
[15:15:34] stop_hook_active=true; releasing                    # Claude continued, then exited
```

---

## Features

- 🛜 **Works behind any firewall.** No inbound traffic, no new auth scope.
- ☁️ **Cloud-agnostic.** Auto-detects OneDrive, Dropbox, iCloud Drive, Google
  Drive on macOS / Linux / WSL. Override with `CLAUDE_BRIDGE_DIR`.
- 💤 **Dormant by default.** Globally installed but does nothing until you
  `touch $BRIDGE_DIR/.enabled`. Removing that file is the kill-switch — no
  config edits, no restart.
- 🔁 **Loop-safe.** Honors Claude Code's `stop_hook_active` flag so sessions
  can actually end.
- ⏱ **Timeout fallback.** If no reply within `CLAUDE_BRIDGE_TIMEOUT`
  (default 30 min), the session exits normally.
- 🪶 **No deps** beyond `bash` and `jq`. ~200 LOC. Easy to audit.
- 🔒 **No third-party servers.** Every byte stays inside your existing cloud
  account.

---

## Install

```sh
git clone https://github.com/kleash/claude-bridge.git
cd claude-bridge
./install.sh
```

The installer:

- copies the hook to `~/.claude-bridge/bridge-hook.sh`
- registers it in `~/.claude/settings.json` under `hooks.Stop` (existing
  settings are backed up to `settings.json.pre-claude-bridge.bak`; hooks are
  **merged**, not overwritten)
- prints the activation instructions

Uninstall: `./uninstall.sh`. Disable temporarily: `rm "$BRIDGE/.enabled"`.

## Activate

The hook is installed but **inert** until you opt-in for a folder:

```sh
# pick any folder your phone can reach
BRIDGE="$HOME/Library/CloudStorage/OneDrive-YourTenant/ClaudeBridge"
# BRIDGE="$HOME/Dropbox/ClaudeBridge"
# BRIDGE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/ClaudeBridge"

mkdir -p "$BRIDGE"/{inbox,outbox,archive}
touch "$BRIDGE/.enabled"

# Make it permanent so every shell sees it (optional — auto-detection picks
# the first synced folder it finds otherwise)
echo "export CLAUDE_BRIDGE_DIR=\"$BRIDGE\"" >> ~/.zshrc
```

## Use

1. Start any `claude` session as usual.
2. When the model finishes a turn, the hook writes
   `outbox/<session>-<utc>.md` and blocks.
3. On your phone, open the OneDrive (or other) app:
   - **read** the latest file in `outbox/`
   - **create** any `.md` or `.txt` file in `inbox/` with your reply
4. Within a couple of seconds the hook picks it up, archives it, and Claude
   continues with your reply as the next turn.
5. If you never reply, the session exits cleanly after the timeout.

## Configuration

| Variable                | Default                                                           | Meaning                                                  |
| ----------------------- | ----------------------------------------------------------------- | -------------------------------------------------------- |
| `CLAUDE_BRIDGE_DIR`     | first detected sync folder, else `~/.claude-bridge/default`       | Folder containing `inbox/`, `outbox/`, `archive/`, `.enabled` |
| `CLAUDE_BRIDGE_TIMEOUT` | `1800`                                                            | Seconds to wait for a reply before letting Claude exit   |
| `CLAUDE_BRIDGE_POLL`    | `2`                                                               | Inbox poll interval, seconds                             |
| `CLAUDE_BRIDGE_LOG`     | `~/Library/Logs/claude-bridge.log` (macOS) / `~/.claude-bridge/claude-bridge.log` | Log file                                                 |

## How it works

Claude Code's `Stop` hook fires at end of turn and may print
`{"decision":"block","reason":"<text>"}` to tell the harness *don't stop —
continue with this content as the next user turn.* The hook script:

1. Reads `session_id`, `transcript_path`, `stop_hook_active` from stdin.
2. If `stop_hook_active=true` (we already injected once), exits — letting the
   session truly stop next time.
3. If `$BRIDGE_DIR/.enabled` is missing, exits (kill-switch).
4. Polls the transcript JSONL briefly for the flushed assistant text, then
   writes `outbox/<session>-<ts>.md`.
5. Polls `inbox/` for any new `.md` or `.txt`. On finding one, archives it
   and prints the `decision:block` JSON.
6. On timeout, exits silently and the session ends normally.

## FAQ

**Is this safe to run on a corporate laptop?**
The hook runs entirely in your user context, opens no ports, and only
touches files under `$CLAUDE_BRIDGE_DIR` (which you choose). It's about
the same risk profile as a shell alias. Read the script — it's ~200 lines.

**Does it leak my code to OneDrive / Dropbox / etc.?**
Only the assistant's last message and your reply transit through the folder
you pick. Claude's full transcript stays under `~/.claude/projects/`. If
your sync provider is itself a compliance concern for your employer, this
isn't the right tool for you.

**Can it start *new* sessions from the phone, not just continue them?**
Not in v1. See the roadmap below — `/new <title>` and `/task <id>` routing
is planned.

**Does it work with Claude Desktop / claude.ai?**
No, this is for the [Claude Code CLI](https://claude.com/claude-code) and
the [Agent SDK](https://docs.claude.com/en/docs/claude-code/sdk). Both share
the `Stop` hook mechanism.

**Why not a Power Automate flow / Teams bot / Graph integration?**
Most of those need admin consent on a corporate tenant, an Azure AD app
registration, or an inbound webhook. `claude-bridge` deliberately needs
none of that — that's the whole point. (A Power Automate companion that
*emails* you the outbox files is on the roadmap as an opt-in nicety.)

## Compatibility

- Tested on macOS (zsh + jq from Homebrew).
- Works on Linux/WSL — the cloud-folder auto-detection covers
  `~/OneDrive*`, `~/Dropbox`, `~/Google Drive`. PRs welcome for more.
- Requires `bash`, `jq`, `date`, `ls`. That's it.

## v1.1: per-session inboxes + `/new` and `/task` routing

Two extras land together:

**Per-session inbox subfolders.** The Stop hook now polls
`$BRIDGE/sessions/<session_id>/inbox/` first, then falls back to the shared
top-level `inbox/`. Multiple concurrent `claude` sessions no longer fight
over the same drop folder — each phone reply only resumes the session it was
addressed to. Single-session users see no behavior change.

**Phone-initiated sessions via `bin/bridge-router.sh`.** A small long-running
companion that watches the top-level `inbox/` for files starting with a
directive on the first line:

| First line       | Effect                                                        |
| ---------------- | ------------------------------------------------------------- |
| `/new <title>`   | Spawns `claude -p "<rest of file>" --output-format json` and records `tasks/<title> → session_id`. Result lands in `outbox/`. |
| `/task <title>`  | Resumes the recorded session via `claude -p "..." --resume <session_id>` and writes the new turn to `outbox/`. |
| (no directive)   | Left alone — the regular Stop hook on a live interactive session will pick it up. |

So from your phone you can now both **start** brand-new sessions and route
follow-ups to a specific task, all by writing one file in OneDrive:

```
/new triage-flaky-test
The CI job api/integration is flaky on main. Look at the last 5 runs and
tell me whether to retry, quarantine, or revert.
```

…and the response shows up in `outbox/<session_id>-<ts>.md`.

Run the router with `nohup bin/bridge-router.sh &` (or wire it into launchd).
It honors the same `.enabled` kill-switch and `CLAUDE_BRIDGE_*` env vars as
the hook, plus:

| Variable                  | Default                              | Meaning                                       |
| ------------------------- | ------------------------------------ | --------------------------------------------- |
| `CLAUDE_BRIDGE_WORKDIR`   | `$HOME`                              | cwd for spawned `claude -p` calls             |
| `CLAUDE_BRIDGE_CLAUDE`    | `claude`                             | Path to the Claude CLI binary                 |
| `CLAUDE_BRIDGE_FLAGS`     | `--dangerously-skip-permissions`     | Extra flags appended to every `claude -p` call|

Tests live under `tests/`: `bash tests/test-hook-per-session.sh` and
`bash tests/test-router.sh` (the router test stubs `claude` with a fake
binary on PATH so no real API calls are made).

## Roadmap

- **v1.2** — opt-in [Power Automate](https://make.powerautomate.com/) flow
  templates: `[Claude]` emails → inbox files; outbox files → email / Teams
  self-chat. Pure UX sugar; the core stays folder-based.
- **v1.3** — optional encryption-at-rest of inbox/outbox via `age`.

## Contributing

PRs welcome — especially for new sync-provider auto-detection (Box, Nextcloud,
Syncthing, Resilio), Linux/WSL polish, or Windows native (`pwsh`) support.
Open an issue first for anything bigger than a paragraph of changes.

## License

MIT. See [LICENSE](LICENSE).

---

If `claude-bridge` saves you a walk back to your laptop, ⭐ the repo and tell
someone whose corp laptop is also held together with prayer and OneDrive.
