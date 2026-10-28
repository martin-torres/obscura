#!/usr/bin/env bash
# Remove the personal Obscura service and installed binaries.
# The git checkout, config, and storage stay unless OBSCURA_PURGE=1.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash." >&2
  exit 1
fi
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

if ! obscura_load_paths; then
  obscura_warn "no install.paths found. Nothing to remove."
  exit 0
fi

obscura_log "stopping Obscura"
supervisor=$(cat "${OBSCURA_STATE_DIR}/supervisor" 2>/dev/null || true)
case "$supervisor" in
  systemd-user)
    systemctl --user disable --now obscura.service >/dev/null 2>&1 || true
    systemctl --user disable --now obscura-update.timer >/dev/null 2>&1 || true
    rm -f "${HOME}/.config/systemd/user/obscura.service" \
      "${HOME}/.config/systemd/user/obscura-update.service" \
      "${HOME}/.config/systemd/user/obscura-update.timer"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ;;
  systemd-system)
    obscura_priv systemctl disable --now obscura.service >/dev/null 2>&1 || true
    obscura_priv systemctl disable --now obscura-update.timer >/dev/null 2>&1 || true
    obscura_priv rm -f /etc/systemd/system/obscura.service \
      /etc/systemd/system/obscura-update.service \
      /etc/systemd/system/obscura-update.timer
    obscura_priv systemctl daemon-reload >/dev/null 2>&1 || true
    ;;
  launchd-user)
    launchctl bootout "gui/$(id -u)/sh.obscura.serve" >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)/sh.obscura.update" >/dev/null 2>&1 || true
    rm -f "${HOME}/Library/LaunchAgents/sh.obscura.serve.plist" \
      "${HOME}/Library/LaunchAgents/sh.obscura.update.plist"
    ;;
  launchd-system)
    obscura_priv launchctl bootout system/sh.obscura.serve >/dev/null 2>&1 || true
    obscura_priv launchctl bootout system/sh.obscura.update >/dev/null 2>&1 || true
    obscura_priv rm -f /Library/LaunchDaemons/sh.obscura.serve.plist \
      /Library/LaunchDaemons/sh.obscura.update.plist
    ;;
  process)
    obscura_stop_fallback
    obscura_remove_cron
    ;;
esac

# Catch a unit that was written but not recorded, and a leftover pid.
obscura_stop_fallback
obscura_remove_cron
rm -f "${HOME}/.config/systemd/user/obscura.service" \
  "${HOME}/.config/systemd/user/obscura-update.service" \
  "${HOME}/.config/systemd/user/obscura-update.timer" \
  "${HOME}/Library/LaunchAgents/sh.obscura.serve.plist" \
  "${HOME}/Library/LaunchAgents/sh.obscura.update.plist" 2>/dev/null || true

rm -f "${OBSCURA_BIN_DIR}/obscura" \
  "${OBSCURA_BIN_DIR}/obscura-worker" \
  "${OBSCURA_BIN_DIR}/obscura-mcp-cdp"
rm -rf "$OBSCURA_LIB_DIR"
obscura_remove_path_marker

if [[ "${OBSCURA_PURGE:-0}" == "1" ]]; then
  obscura_log "purging config and state"
  rm -rf "$OBSCURA_CONFIG_DIR" "$OBSCURA_STATE_DIR" "$OBSCURA_LOG_DIR"
  if [[ "${OBSCURA_MANAGED_CLONE:-0}" == "1" && -n "${OBSCURA_SRC:-}" ]]; then
    obscura_log "removing managed clone ${OBSCURA_SRC}"
    rm -rf "$OBSCURA_SRC"
  else
    obscura_log "leaving checkout ${OBSCURA_SRC:-unknown} in place (not a clone created by install.sh)"
  fi
else
  obscura_log "left checkout, config, and storage in place. OBSCURA_PURGE=1 removes config and state."
fi

obscura_log "uninstalled"
