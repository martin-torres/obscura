# Personal setup

This fork of [h4ckf0r0day/obscura](https://github.com/h4ckf0r0day/obscura) is the copy to run on your own machines. GitHub `main` on [martin-torres/obscura](https://github.com/martin-torres/obscura) is the source of truth. The installer builds that tree, installs the `obscura` and `obscura-worker` binaries, and leaves a CDP server running on loopback.

## CDP endpoint

| | |
| --- | --- |
| Host | `127.0.0.1` |
| Port | `9222` |
| Discovery | `http://127.0.0.1:9222/json/version` |
| WebSocket | `webSocketDebuggerUrl` in that JSON |

The port is fixed so agent configs can stay the same on every machine. Change it in the config file below if 9222 is already taken, then restart the service and update the agent snippets to match.

The server binds loopback only. Do not publish 9222 on a public interface. A non-loopback bind is refused unless `OBSCURA_CDP_TOKEN` is at least 32 bytes.

## One-command install

The same command works on the Ubuntu agent box, the Linux VPS, and the MacBook. It installs build tools and Rust if they are missing, compiles the release binaries (rendering included), and starts the service.

User install (agent box and MacBook). The service is a systemd user unit on Linux, or a launchd agent on macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/martin-torres/obscura/main/scripts/install.sh | bash
```

System install (Linux VPS, starts at boot as user `obscura`):

```bash
curl -fsSL https://raw.githubusercontent.com/martin-torres/obscura/main/scripts/install.sh | sudo bash
```

From a checkout you already have:

```bash
./scripts/install.sh
```

Root runs a system install. Anyone else gets a user install. `OBSCURA_SERVICE=user` or `OBSCURA_SERVICE=system` overrides that.

On Linux, a user install asks systemd to linger the account so the service stays up after logout. On a machine whose PID 1 is not systemd (some containers), the installer still writes the unit files, starts the process in the background, and schedules `scripts/update.sh` with cron every 10 minutes.

Check it:

```bash
curl -fsS http://127.0.0.1:9222/json/version
```

Re-running the installer is safe. It will not overwrite `obscura.env`.

### Where files go

User install:

| Path | Role |
| --- | --- |
| `~/.local/bin/obscura` | CLI and CDP server |
| `~/.local/bin/obscura-worker` | `scrape` helper (keep it next to `obscura`) |
| `~/.local/bin/obscura-mcp-cdp` | Playwright MCP wrapper for the running CDP server |
| `~/.config/obscura/obscura.env` | Settings you edit |
| `~/.local/state/obscura/` | Storage, pid, installed commit |
| `~/.local/state/obscura/log/` | Serve and update logs |
| checkout you ran it from, or `~/.local/share/obscura/src` | Git tree the updater fast-forwards |

System install uses `/usr/local/bin`, `/usr/local/src/obscura`, `/etc/obscura/obscura.env`, `/var/lib/obscura`, and `/var/log/obscura`.

Open a new shell if `obscura` is not on `PATH`. The installer appends `~/.local/bin` to `~/.profile` (and `~/.zprofile` on macOS).

### Prebuilt binaries

Compiling V8 takes a few minutes and a few GB of disk. That is the default, because `main` can be ahead of any release tag.

This repo's release workflow publishes archives when you push a `v*` tag (`obscura-x86_64-linux.tar.gz`, `obscura-aarch64-linux.tar.gz`, `obscura-aarch64-macos.tar.gz`, `obscura-x86_64-macos.tar.gz`). To use those instead of compiling:

```bash
curl -fsSL https://raw.githubusercontent.com/martin-torres/obscura/main/scripts/install.sh | env OBSCURA_USE_PREBUILT=1 bash
```

If HEAD is not exactly that release, the installer says so and falls back to a source build. The updater, with `OBSCURA_USE_PREBUILT=1` in the config, only swaps the binary when a release asset exists. It does not compile, and it does not pretend a stale asset is `main`.

## Customize

Edit the env file, then restart.

```bash
# user
~/.config/obscura/obscura.env
systemctl --user restart obscura

# system
sudoedit /etc/obscura/obscura.env
sudo systemctl restart obscura

# macOS
launchctl kickstart -k "gui/$(id -u)/sh.obscura.serve"
```

Settings:

| Variable | Meaning |
| --- | --- |
| `OBSCURA_HOST`, `OBSCURA_PORT` | CDP bind. Default `127.0.0.1` and `9222`. |
| `OBSCURA_FEATURES` | `render` (default), `render,stealth`, `stealth`, or `none`. |
| `OBSCURA_STEALTH` | `1` passes `--stealth`. The binary has to be built with stealth in `OBSCURA_FEATURES`. |
| `OBSCURA_PROXY` | HTTP or SOCKS5 proxy URL. |
| `OBSCURA_ALLOW_PRIVATE_NETWORK` | `1` allows page fetches to loopback and private addresses. |
| `OBSCURA_SERVE_ARGS` | Extra `obscura serve` flags, split on spaces. Example: `--font-dir /usr/share/fonts`. |
| `OBSCURA_USE_PREBUILT` | `1` updates from GitHub release assets. `0` compiles. |
| `OBSCURA_BRANCH` | Branch the updater fast-forwards. Default `main`. |
| `OBSCURA_CDP_TOKEN` | Required for a non-loopback bind. At least 32 bytes. |

Feature and stealth changes need a rebuild:

```bash
OBSCURA_FORCE_REBUILD=1 ~/.local/share/obscura/src/scripts/update.sh
```

Use the checkout path the installer printed if it is not that default. From a repo you cloned yourself, that is `scripts/update.sh` in the repo.

Cookies and localStorage persist in the storage directory (`~/.local/state/obscura/storage` or `/var/lib/obscura/storage`).

## How updates propagate

`scripts/update.sh` runs every 10 minutes.

- Linux with systemd: `obscura-update.timer` (`OnUnitActiveSec=10min`).
- macOS: launchd `sh.obscura.update` with `StartInterval` 600.
- Linux without systemd: a crontab line, `*/10 * * * *`.

Each run:

1. If tracked files in the checkout have uncommitted changes, it logs a warning and stops. It does not stash, reset, or rebuild.
2. It fetches `origin/main`.
3. If `origin/main` is strictly ahead, it fast-forwards. If you have local commits and the histories have diverged, it logs a warning and does not merge.
4. If the installed commit and feature set already match, it leaves the service alone.
5. Otherwise it rebuilds (or downloads a matching release), restarts the service, and checks that port 9222 answers.

Push a commit to `origin/main` from one machine. The other two pick it up on their next run, as long as their checkouts are clean.

Logs:

```bash
# user
tail -f ~/.local/state/obscura/log/update.log
systemctl --user status obscura obscura-update.timer
journalctl --user -u obscura -u obscura-update -f

# system
sudo tail -f /var/log/obscura/update.log
sudo systemctl status obscura obscura-update.timer
sudo journalctl -u obscura -u obscura-update -f
```

The timer's git remote has to work with no prompt. Use an SSH key or a credential helper on each machine.

Run an update by hand with `scripts/update.sh` in the checkout.

## Sync with upstream

The installer adds `upstream` pointing at `https://github.com/h4ckf0r0day/obscura.git` when that remote is missing. It does not merge upstream on its own. Do that when you want their changes, then push `main` so the other machines follow.

```bash
cd ~/.local/share/obscura/src   # or your checkout
git fetch upstream
git merge upstream/main
# fix conflicts if a personal change overlaps
git push origin main
```

Personal work should be committed on this fork. Uncommitted edits are preserved, and they block the auto-updater on that machine until you commit or remove them.

## Agents

The always-on process is `obscura serve`. Agents share that browser by attaching to CDP. A separate `obscura mcp` process starts its own browser and does not attach to port 9222. Use it when an agent should not share tabs with the others.

`~/.local/bin/obscura-mcp-cdp` (or `/usr/local/bin/obscura-mcp-cdp`) runs Playwright's MCP server against the service. It reads the host and port from `obscura.env`. It needs Node.js (`npx`). The underlying server is [`@playwright/mcp`](https://github.com/microsoft/playwright-mcp) with `--cdp-endpoint=http://127.0.0.1:9222`.

### Cursor

`~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "obscura": {
      "command": "/home/YOU/.local/bin/obscura-mcp-cdp"
    }
  }
}
```

Built-in Obscura MCP, private session, no Node:

```json
{
  "mcpServers": {
    "obscura": {
      "command": "/home/YOU/.local/bin/obscura",
      "args": ["mcp"]
    }
  }
}
```

Replace `/home/YOU/.local/bin` with `/usr/local/bin` for a system install.

### Claude Code

Shared CDP service:

```bash
claude mcp add obscura-cdp -- ~/.local/bin/obscura-mcp-cdp
```

Private session:

```bash
claude mcp add obscura -- ~/.local/bin/obscura mcp
```

### Codex

`~/.codex/config.toml`:

```toml
[mcp_servers.obscura]
command = "/home/YOU/.local/bin/obscura-mcp-cdp"
```

Private session:

```toml
[mcp_servers.obscura]
command = "/home/YOU/.local/bin/obscura"
args = ["mcp"]
```

### OpenClaw

OpenClaw's browser tool attaches to an existing CDP server. In `~/.openclaw/openclaw.json`:

```json5
{
  browser: {
    enabled: true,
    defaultProfile: "obscura",
    profiles: {
      obscura: {
        cdpUrl: "http://127.0.0.1:9222",
        attachOnly: true
      }
    }
  }
}
```

Restart the OpenClaw gateway after editing. `attachOnly` keeps OpenClaw from launching Chrome.

### Hermes

[hermes-plugin-obscura](https://github.com/SGavrl/hermes-plugin-obscura) connects to a server that is already running when `OBSCURA_CDP_URL` is set. In `~/.hermes/.env`:

```bash
OBSCURA_CDP_URL=http://127.0.0.1:9222
```

```yaml
browser:
  cloud_provider: "obscura"
```

Install the plugin with `hermes plugins install SGavrl/hermes-plugin-obscura --enable`. Remote mode does not start or stop the service.

### Playwright and Puppeteer

```js
const { chromium } = require('playwright');
const browser = await chromium.connectOverCDP('http://127.0.0.1:9222');
```

```js
const browser = await puppeteer.connect({
  browserURL: 'http://127.0.0.1:9222',
});
```

Use `connectOverCDP` / `browserURL`. Obscura does not speak Playwright's own transport.

## Service commands

```bash
# user (Linux)
systemctl --user status obscura
systemctl --user restart obscura
systemctl --user status obscura-update.timer

# system (Linux)
sudo systemctl status obscura
sudo systemctl restart obscura

# macOS
launchctl print "gui/$(id -u)/sh.obscura.serve"
launchctl kickstart -k "gui/$(id -u)/sh.obscura.serve"
```

Without systemd, the pid is `~/.local/state/obscura/serve.pid` and the log is `~/.local/state/obscura/log/serve.log`.

## Uninstall

From the checkout:

```bash
./scripts/uninstall.sh
```

That stops the service, removes the timer or launchd jobs, and deletes the binaries and the PATH snippet. The checkout, `obscura.env`, and cookie storage stay.

```bash
OBSCURA_PURGE=1 ./scripts/uninstall.sh
```

Purge also deletes the config and state. It deletes the git checkout only when the installer cloned it (`~/.local/share/obscura/src` or `/usr/local/src/obscura`). A repo you cloned yourself is left alone.

Build packages and the Rust toolchain are not removed.
