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
Yes — drop a file starting with `/new <title>` in `inbox/` and the router
spawns a fresh `claude -p` session. See the v1.1 router section below.

**Can the phone approve *individual tool calls* (Bash, Write, Edit, …)?**
Yes, in v1.2. Set `CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash,Write,Edit"` and the
new `PreToolUse` hook serializes those tools' permission prompts to the
folder. Reply `approve`, `deny`, `deny: <reason>`, or just type a free-form
message and the hook routes the decision back to Claude. See the v1.2
section below.

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

Tests live under `tests/`. Run them all with `bash tests/run-all.sh`. The
suite covers the Stop hook, router (existing + new directives), PreToolUse
permission flow (8 cases including approve / deny / timeout / cancel), the
Notification hook, the dispatcher CLI, and `bridge-doctor`. The router test
stubs `claude` with a fake binary on PATH so no real API calls are made.

## v1.2: daily-driver ergonomics

v1.2 adds the four things you reach for every day:

1. **A real CLI** — one `claude-bridge` command with subcommands.
2. **Approve tool calls from your phone** — opt-in `PreToolUse` hook that
   serializes the tool call to outbox and gates it on your reply.
3. **A self-maintained index file** — `outbox/INDEX.md` is the phone's
   home screen.
4. **`claude-bridge doctor`** — one command tells you exactly what's wrong
   with your setup.

### `claude-bridge` CLI

After `./install.sh`, the dispatcher lives at `~/.claude-bridge/claude-bridge`
(symlinked into `~/.local/bin` if writable):

```text
claude-bridge enable                   # arm the hook (touch .enabled)
claude-bridge disable                  # disarm

claude-bridge status                   # bridge dir, sync provider, sessions, log
claude-bridge ls                       # markdown table of all known tasks
claude-bridge show <task> [--all|--json]
claude-bridge cancel <task>            # any waiting hook for that task releases
claude-bridge tail                     # follow log + outbox like tail -F

claude-bridge clean [--days N]         # prune archive (14d) + rotate log >10MB
claude-bridge router start|stop|status # manage the optional /new + /task daemon
claude-bridge doctor                   # PASS/FAIL setup health check
```

`status`, `show --json`, and `clean` are all scriptable. `tail` and `ls` are
where you spend most of your day.

### Approve tool calls from your phone (`PreToolUse` hook)

This is the headline feature. When opted in, Claude Code's `PreToolUse` event
is routed through the same OneDrive folder: a permission request lands in
`outbox/permission-<sid>-<ts>.md`, the laptop hook waits for your reply, and
your reply emits the `approve` / `block` JSON decision Claude needs.

Opt in by listing the tools you want to gate:

```sh
export CLAUDE_BRIDGE_PERMISSION_TOOLS="Bash,Write,Edit"
```

Anything not in that list passes through Claude Code's normal in-terminal
prompt unchanged. With the list above, asking Claude to run `rm -rf build/`
produces this in your phone's OneDrive:

```markdown
# Permission request — Bash on laptop-name

- session: `abc123`
- tool: `Bash`
- timestamp: `2026-05-05T14:32Z`

---

```bash
rm -rf build/
```

---

## Reply with one of:

- `approve` — let it run as-is
- `deny` — block and tell Claude why
- `deny: <reason>` — block with a custom reason
- _(any other text)_ — block; Claude reads your text as the reason
```

You drop a `.txt` or `.md` reply in `inbox/` (or `sessions/<sid>/inbox/`) with
one of those bodies. The hook decides:

| Phone reply             | Hook output                                            | Effect on Claude                |
| ----------------------- | ------------------------------------------------------ | ------------------------------- |
| `approve`               | `{"decision":"approve","reason":"approved by phone"}`  | Tool runs as-is.                |
| `deny`                  | `{"decision":"block","reason":"denied by phone"}`      | Tool blocked; Claude replans.   |
| `deny: <reason>`        | `{"decision":"block","reason":"<reason>"}`             | Same, with custom feedback.     |
| _free-form text_        | `{"decision":"block","reason":"<your full text>"}`     | Claude reads your message.      |
| _(timeout, default)_    | `{"decision":"block","reason":"timed out…"}`           | Default-deny, never silent.     |
| `.cancel` sentinel      | exit 0, no JSON                                        | Falls back to terminal prompt.  |

Configuration:

| Variable                                  | Default | Purpose                                       |
| ----------------------------------------- | ------- | --------------------------------------------- |
| `CLAUDE_BRIDGE_PERMISSION_TOOLS`          | _empty_ | CSV of tool names to gate (off by default).   |
| `CLAUDE_BRIDGE_PERMISSION_TIMEOUT`        | `1800`  | Seconds to wait before auto-blocking.         |
| `CLAUDE_BRIDGE_PERMISSION_DEFAULT`        | `block` | `block` (recommended) or `passthrough`.       |
| `CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS`| _empty_ | CSV of bash globs that auto-approve **without** ever pinging the phone. e.g. `"git status*,git diff*,git log*,ls*,pwd,cat *"`. |
| `CLAUDE_BRIDGE_AUTO_APPROVE_TTL`          | `1800`  | Seconds an `approve always` flag stays valid before re-prompting. |

### One tap covers a whole turn (`approve always`)

Claude often makes **multiple Bash sub-calls per turn** — a `git status` to
gather context, then the command you actually asked for, then maybe a
verification step. With OneDrive sync latency, replying `approve` 3-5 times
per turn is miserable. v1.3 fixes this in three independent ways:

1. **Static allowlist** — set `CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS` once
   in your shell rc and the listed commands **never round-trip through the
   cloud folder at all**. The hook short-circuits in-process. Use this for
   read-only commands that you're always going to approve anyway:
   ```sh
   export CLAUDE_BRIDGE_AUTO_APPROVE_BASH_PATTERNS="git status*,git diff*,git log*,ls*,pwd,cat *,which *"
   ```

2. **Session-persistent `approve always`** — reply `approve always` (or
   `approve session`) to a permission request and **all subsequent calls for
   that tool in that session** auto-approve silently. State lives in
   `sessions/<sid>/auto-approve-<Tool>` with a TTL (default 30 min) so a
   forgotten flag can't auto-approve `rm -rf` four hours later. Per-tool, so
   approving Bash doesn't auto-approve Edit.

3. **Counted `approve N`** — reply `approve 5` to auto-approve the next 5
   calls for that tool, then prompt again. Lower commitment than `always`.

The phone reply tokens, in full:

| Reply                       | Effect                                                 |
| --------------------------- | ------------------------------------------------------ |
| `approve`                   | this one call only.                                    |
| `approve always`            | this call + all subsequent ones for this tool/session. |
| `approve N`                 | this call + the next N for this tool/session.          |
| `deny` / `deny: <reason>`   | block this call (one-shot).                            |
| `revoke`                    | clear all auto-approve state for this tool **and** block the current call. |
| _(any other text)_          | block; Claude reads your text as the reason.           |

Revoke from the laptop too: `claude-bridge revoke <task> [--tool TOOL]`.

The currently-active autopilot is shown in the `Note` column of `INDEX.md`,
e.g. `auto-approve(Bash:always (1432s left))`, so the phone user always
knows what's on autopilot.

**Race-safe under parallel Bash.** Claude often fires multiple `Bash` calls
in one turn (concurrent context-gathering plus the actual command). When you
reply `approve always` to one of them, the **other in-flight hooks notice
the new flag during their poll loop and short-circuit immediately**, moving
their now-stale permission files to `archive/raced-*.md` so the phone
doesn't see ghost prompts. A single tap really is a single tap.

> ⚠️ **Router-spawned `/new` and `/task` sessions skip this gate by default.**
> The router invokes `claude -p` with `--dangerously-skip-permissions`
> (`CLAUDE_BRIDGE_FLAGS` default), which short-circuits Claude Code's whole
> permission system *including* the `PreToolUse` hook. If you want phone-side
> approval to apply to phone-spawned sessions too, override the flag:
>
> ```sh
> export CLAUDE_BRIDGE_FLAGS=""
> ```
>
> …and the router's `claude -p` calls will go through `PreToolUse` like any
> interactive session. Tradeoff: the router will then block on every gated
> tool call until *you* reply — fine for human-in-the-loop, miserable for
> overnight automation.

### `outbox/INDEX.md` — the phone's home screen

Every hook now rewrites `outbox/INDEX.md` atomically when a session changes
state. Open one file in OneDrive and see every task at a glance:

```markdown
# claude-bridge — task index

_Updated: 2026-05-05T14:43:11Z_

| Status            | Task           | Session  | Last update          | Note     |
|-------------------|----------------|----------|----------------------|----------|
| awaiting-approval | refactor-auth  | `abc123` | 2026-05-05T14:43:09Z | Bash     |
| waiting           | triage-flake   | `def456` | 2026-05-05T14:42:51Z | Stop hook|
| idle              | build-pipeline | `ghi789` | 2026-05-05T14:38:00Z | —        |
```

### Phone-side directives (router)

The router (`bin/bridge-router.sh`, or `claude-bridge router start`) now
understands these phone-initiated directives in addition to the existing
`/new <title>` and `/task <id>`:

| First line              | Effect                                                    |
| ----------------------- | --------------------------------------------------------- |
| `/list`                 | Write a fresh task table to outbox.                       |
| `/status [task]`        | Status of one task, or all if omitted.                    |
| `/cancel <task>`        | Drop a `.cancel` sentinel; the waiting hook releases.     |
| `/clean [--days N]`     | Archive cleanup + log rotation.                           |
| `/help`                 | Cheatsheet of all directives.                             |

### `claude-bridge doctor`

```text
$ claude-bridge doctor
Dependencies
  PASS  jq: jq-1.7
  PASS  claude CLI: /usr/local/bin/claude
  PASS  bash: 5.2.15(1)-release

Hook installation (~/.claude-bridge)
  PASS  ~/.claude-bridge exists
  PASS  bridge-hook.sh installed and executable
  PASS  bridge-pretool-hook.sh installed and executable
  PASS  bridge-notify-hook.sh installed and executable

Claude Code settings (~/.claude/settings.json)
  PASS  hooks.Stop registered
  PASS  hooks.PreToolUse registered
  PASS  hooks.Notification registered
…
claude-bridge doctor: all checks PASS
```

Exits non-zero on any FAIL — CI- and shell-conditional-friendly.

## Roadmap

- **v1.3** — push-notification fan-out (ntfy / Pushover / Telegram) for
  setups where outbound HTTP is allowed.
- **v1.4** — optional encryption-at-rest of inbox/outbox via `age`.
- **v1.5** — Windows / PowerShell port for corporate Windows laptops.

## Contributing

PRs welcome — especially for new sync-provider auto-detection (Box, Nextcloud,
Syncthing, Resilio), Linux/WSL polish, or Windows native (`pwsh`) support.
Open an issue first for anything bigger than a paragraph of changes.

## License

MIT. See [LICENSE](LICENSE).

---

If `claude-bridge` saves you a walk back to your laptop, ⭐ the repo and tell
someone whose corp laptop is also held together with prayer and OneDrive.
