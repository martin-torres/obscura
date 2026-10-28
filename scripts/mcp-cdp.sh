#!/usr/bin/env bash
# stdio MCP wrapper: Playwright MCP attached to the always-on Obscura CDP server.
# The browser process is the systemd/launchd service, not a browser started by MCP.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash." >&2
  exit 1
fi
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

obscura_load_paths || true
if [[ -z "${OBSCURA_CONFIG_FILE:-}" ]]; then
  if [[ -f "${HOME}/.config/obscura/obscura.env" ]]; then
    OBSCURA_CONFIG_FILE="${HOME}/.config/obscura/obscura.env"
  elif [[ -f /etc/obscura/obscura.env ]]; then
    OBSCURA_CONFIG_FILE="/etc/obscura/obscura.env"
  fi
fi
obscura_load_config
: "${OBSCURA_HOST:=127.0.0.1}"
: "${OBSCURA_PORT:=9222}"

if ! command -v npx >/dev/null 2>&1; then
  obscura_die "npx was not found. Install Node.js to use Playwright MCP, or configure the built-in server instead: obscura mcp"
fi

probe=$(obscura_probe_host)
exec npx -y @playwright/mcp@latest \
  "--cdp-endpoint=http://${probe}:${OBSCURA_PORT}" \
  "$@"
