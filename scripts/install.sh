#!/usr/bin/env bash
# Idempotent installer for a personal Obscura fork.
# User service by default. Root installs a system service.
# CDP listens on 127.0.0.1:9222 unless obscura.env says otherwise.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash." >&2
  exit 1
fi
set -euo pipefail

OBSCURA_DEFAULT_REPO="${OBSCURA_DEFAULT_REPO:-https://github.com/martin-torres/obscura.git}"
OBSCURA_BRANCH="${OBSCURA_BRANCH:-main}"

usage() {
  cat <<EOF
Usage: scripts/install.sh

Installs Obscura from this checkout (or clones ${OBSCURA_DEFAULT_REPO}),
builds a release binary, and runs it as a background service.

CDP endpoint: http://127.0.0.1:9222
Override the port with OBSCURA_PORT before the first install, or edit
the config file afterwards and restart.

Environment:
  OBSCURA_SERVICE=user|system|auto   auto is user, or system when root
  OBSCURA_REPO=URL                   clone URL when not already in a checkout
  OBSCURA_SRC=DIR                    checkout to build
  OBSCURA_FEATURES=render            render | render,stealth | stealth | none
  OBSCURA_USE_PREBUILT=1             use a GitHub release asset when one exists
  OBSCURA_PORT=9222
  OBSCURA_HOST=127.0.0.1

One-line install:
  curl -fsSL https://raw.githubusercontent.com/martin-torres/obscura/main/scripts/install.sh | bash
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# Piped `curl | bash` has no script path. Clone, then re-exec the file.
if [[ -z "${BASH_SOURCE[0]:-}" || ! -f "${BASH_SOURCE[0]}" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    dest="${OBSCURA_SRC:-/usr/local/src/obscura}"
  else
    dest="${OBSCURA_SRC:-${XDG_DATA_HOME:-$HOME/.local/share}/obscura/src}"
  fi
  if [[ ! -d "${dest}/.git" ]]; then
    if [[ -e "$dest" ]]; then
      echo "source path exists and is not a git checkout: ${dest}" >&2
      exit 1
    fi
    if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        if [[ "$(id -u)" -eq 0 ]]; then
          apt-get update
          apt-get install -y git curl ca-certificates
        else
          sudo apt-get update
          sudo apt-get install -y git curl ca-certificates
        fi
      else
        echo "Install git and curl, then re-run." >&2
        exit 1
      fi
    fi
    mkdir -p "$(dirname "$dest")"
    git clone --branch "$OBSCURA_BRANCH" "${OBSCURA_REPO:-$OBSCURA_DEFAULT_REPO}" "$dest"
    export OBSCURA_MANAGED_CLONE=1
  fi
  export OBSCURA_SRC="$dest"
  exec bash "${dest}/scripts/install.sh"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

if [[ -z "${OBSCURA_SRC:-}" ]] && git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  OBSCURA_SRC="$REPO_ROOT"
  OBSCURA_MANAGED_CLONE="${OBSCURA_MANAGED_CLONE:-0}"
fi

obscura_layout
mkdir -p "$OBSCURA_CONFIG_DIR" "$OBSCURA_STATE_DIR" "$OBSCURA_LOG_DIR" "$OBSCURA_LIB_DIR" "$OBSCURA_BIN_DIR"
chmod 0700 "$OBSCURA_STATE_DIR" || true

if [[ -f "$OBSCURA_CONFIG_FILE" ]]; then
  obscura_load_config
fi
: "${OBSCURA_HOST:=127.0.0.1}"
: "${OBSCURA_PORT:=9222}"
: "${OBSCURA_FEATURES:=render}"
: "${OBSCURA_BRANCH:=main}"
obscura_validate_features
obscura_check_bind

install_packages() {
  local os
  os=$(uname -s)
  if [[ "$os" == "Linux" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      obscura_log "installing build packages (apt)"
      obscura_priv apt-get update
      obscura_priv apt-get install -y --no-install-recommends \
        build-essential ca-certificates clang cmake curl git \
        libclang-dev libssl-dev llvm-dev pkg-config python3
    elif command -v dnf >/dev/null 2>&1; then
      obscura_log "installing build packages (dnf)"
      obscura_priv dnf install -y \
        gcc gcc-c++ make pkgconf-pkg-config openssl-devel clang cmake \
        llvm-devel python3 git curl ca-certificates
    else
      obscura_warn "no apt or dnf found. Install a C compiler, pkg-config, git, curl, and python3 yourself."
    fi
  elif [[ "$os" == "Darwin" ]]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      xcode-select --install >/dev/null 2>&1 || true
      obscura_die "Xcode Command Line Tools are required. Finish that installer, then re-run scripts/install.sh."
    fi
    if [[ "$OBSCURA_FEATURES" == *stealth* ]]; then
      if ! command -v cmake >/dev/null 2>&1; then
        if command -v brew >/dev/null 2>&1; then
          brew install cmake
        else
          obscura_die "stealth builds need CMake. Install Homebrew and cmake, or build with OBSCURA_FEATURES=render."
        fi
      fi
    fi
  else
    obscura_die "unsupported OS ${os}. This installer supports Linux and macOS."
  fi
}

ensure_rust() {
  export PATH="${HOME}/.cargo/bin:/usr/local/cargo/bin:${PATH:-}"
  if ! command -v cargo >/dev/null 2>&1; then
    obscura_log "installing rustup stable"
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | \
      sh -s -- -y --default-toolchain stable --profile minimal
  fi
  if [[ -f "${HOME}/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.cargo/env"
  fi
  command -v cargo >/dev/null 2>&1 || obscura_die "cargo is not on PATH after rustup"
  obscura_log "using $(rustc --version)"
}

ensure_checkout() {
  local repo_url
  repo_url="${OBSCURA_REPO:-}"
  if [[ -d "${OBSCURA_SRC}/.git" ]]; then
    repo_url="${repo_url:-$(git -C "$OBSCURA_SRC" remote get-url origin 2>/dev/null || true)}"
  else
    if [[ -e "$OBSCURA_SRC" ]]; then
      obscura_die "source path exists and is not a git checkout: ${OBSCURA_SRC}"
    fi
    repo_url="${repo_url:-$OBSCURA_DEFAULT_REPO}"
    obscura_log "cloning ${repo_url} into ${OBSCURA_SRC}"
    mkdir -p "$(dirname "$OBSCURA_SRC")"
    git clone --branch "$OBSCURA_BRANCH" "$repo_url" "$OBSCURA_SRC"
    OBSCURA_MANAGED_CLONE=1
  fi
  if ! git -C "$OBSCURA_SRC" remote get-url upstream >/dev/null 2>&1; then
    git -C "$OBSCURA_SRC" remote add upstream "$OBSCURA_UPSTREAM_URL"
    obscura_log "added upstream remote ${OBSCURA_UPSTREAM_URL}"
  fi
  if obscura_worktree_dirty; then
    obscura_warn "checkout has uncommitted changes. Installing this tree as-is and not pulling."
    return 0
  fi
  if git -C "$OBSCURA_SRC" fetch --prune origin "$OBSCURA_BRANCH"; then
    if git -C "$OBSCURA_SRC" rev-parse --verify "origin/${OBSCURA_BRANCH}" >/dev/null 2>&1 \
      && git -C "$OBSCURA_SRC" merge-base --is-ancestor HEAD "origin/${OBSCURA_BRANCH}" \
      && [[ "$(git -C "$OBSCURA_SRC" rev-parse HEAD)" != "$(git -C "$OBSCURA_SRC" rev-parse "origin/${OBSCURA_BRANCH}")" ]]; then
      obscura_log "fast-forward to origin/${OBSCURA_BRANCH}"
      git -C "$OBSCURA_SRC" merge --ff-only "origin/${OBSCURA_BRANCH}"
    fi
  else
    obscura_warn "git fetch failed. Building the checkout as it is."
  fi
}

write_paths() {
  local file="${OBSCURA_LIB_DIR}/install.paths"
  if [[ -z "${OBSCURA_MANAGED_CLONE:-}" && -f "$file" ]]; then
    OBSCURA_MANAGED_CLONE=$(awk -F"'" '/^OBSCURA_MANAGED_CLONE=/{print $2; exit}' "$file")
  fi
  : "${OBSCURA_MANAGED_CLONE:=0}"
  cat > "$file" <<EOF
OBSCURA_SERVICE_MODE='${OBSCURA_SERVICE_MODE}'
OBSCURA_BIN_DIR='${OBSCURA_BIN_DIR}'
OBSCURA_LIB_DIR='${OBSCURA_LIB_DIR}'
OBSCURA_CONFIG_DIR='${OBSCURA_CONFIG_DIR}'
OBSCURA_CONFIG_FILE='${OBSCURA_CONFIG_FILE}'
OBSCURA_STATE_DIR='${OBSCURA_STATE_DIR}'
OBSCURA_LOG_DIR='${OBSCURA_LOG_DIR}'
OBSCURA_STORAGE_DIR='${OBSCURA_STORAGE_DIR}'
OBSCURA_SRC='${OBSCURA_SRC}'
OBSCURA_MANAGED_CLONE='${OBSCURA_MANAGED_CLONE}'
EOF
  chmod 0644 "$file"
  export OBSCURA_PATHS_FILE="$file"
}

write_config_if_missing() {
  [[ -f "$OBSCURA_CONFIG_FILE" ]] && return 0
  umask 077
  cat > "$OBSCURA_CONFIG_FILE" <<EOF
# Personal Obscura service configuration. Sourced by the service and updater.
# install.sh does not overwrite this file. Restart the service after edits.
# Stealth and feature changes need a rebuild: set the values, then run
# OBSCURA_FORCE_REBUILD=1 scripts/update.sh

OBSCURA_HOST=${OBSCURA_HOST}
OBSCURA_PORT=${OBSCURA_PORT}

# render | render,stealth | stealth | none
OBSCURA_FEATURES=${OBSCURA_FEATURES}

# 1 passes --stealth. The binary must be built with stealth in OBSCURA_FEATURES.
OBSCURA_STEALTH=${OBSCURA_STEALTH:-0}

# HTTP or SOCKS5 proxy, or empty.
OBSCURA_PROXY=${OBSCURA_PROXY:-}

# 1 allows loopback and private-network fetches from page code.
OBSCURA_ALLOW_PRIVATE_NETWORK=${OBSCURA_ALLOW_PRIVATE_NETWORK:-0}

# Extra arguments for \`obscura serve\`, split on spaces.
OBSCURA_SERVE_ARGS=${OBSCURA_SERVE_ARGS:-}

# 1 installs and updates from GitHub release assets when this repo has published them.
# origin/main is still the source of truth. Without a matching asset the updater
# keeps the current binary and says so. Leave at 0 to compile.
OBSCURA_USE_PREBUILT=${OBSCURA_USE_PREBUILT:-0}

OBSCURA_BRANCH=${OBSCURA_BRANCH}

# Required only when OBSCURA_HOST is not loopback. At least 32 bytes.
# OBSCURA_CDP_TOKEN=
EOF
  chmod 0600 "$OBSCURA_CONFIG_FILE"
  umask 022
}

install_mcp_shim() {
  cat > "${OBSCURA_BIN_DIR}/obscura-mcp-cdp" <<EOF
#!/usr/bin/env bash
exec '${OBSCURA_SRC}/scripts/mcp-cdp.sh' "\$@"
EOF
  chmod 0755 "${OBSCURA_BIN_DIR}/obscura-mcp-cdp"
}

write_systemd_units() {
  local unit_dir
  if [[ "$OBSCURA_SERVICE_MODE" == "system" ]]; then
    if ! id obscura >/dev/null 2>&1; then
      if command -v useradd >/dev/null 2>&1; then
        obscura_priv useradd --system --home-dir "$OBSCURA_STATE_DIR" --shell /usr/sbin/nologin obscura
      else
        obscura_die "system install needs a user named obscura"
      fi
    fi
    obscura_priv mkdir -p "$OBSCURA_STATE_DIR" "$OBSCURA_LOG_DIR" "$OBSCURA_STORAGE_DIR"
    obscura_priv chown -R obscura:obscura "$OBSCURA_STATE_DIR" "$OBSCURA_LOG_DIR"
    if [[ -f "$OBSCURA_CONFIG_FILE" ]]; then
      obscura_priv chgrp obscura "$OBSCURA_CONFIG_FILE"
      obscura_priv chmod 0640 "$OBSCURA_CONFIG_FILE"
    fi
    unit_dir="/etc/systemd/system"
    obscura_priv tee "${unit_dir}/obscura.service" >/dev/null <<EOF
[Unit]
Description=Obscura CDP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=obscura
Group=obscura
Environment=OBSCURA_PATHS_FILE=${OBSCURA_LIB_DIR}/install.paths
ExecStart=${OBSCURA_SRC}/scripts/serve.sh
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
WorkingDirectory=${OBSCURA_STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF
    obscura_priv tee "${unit_dir}/obscura-update.service" >/dev/null <<EOF
[Unit]
Description=Update Obscura from origin/main

[Service]
Type=oneshot
Environment=OBSCURA_PATHS_FILE=${OBSCURA_LIB_DIR}/install.paths
ExecStart=${OBSCURA_SRC}/scripts/update.sh
EOF
    obscura_priv tee "${unit_dir}/obscura-update.timer" >/dev/null <<EOF
[Unit]
Description=Update Obscura from origin/main every 10 days

[Timer]
OnUnitActiveSec=10d
AccuracySec=1h
Persistent=true
Unit=obscura-update.service

[Install]
WantedBy=timers.target
EOF
  else
    unit_dir="${HOME}/.config/systemd/user"
    mkdir -p "$unit_dir"
    cat > "${unit_dir}/obscura.service" <<EOF
[Unit]
Description=Obscura CDP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=OBSCURA_PATHS_FILE=${OBSCURA_LIB_DIR}/install.paths
ExecStart=${OBSCURA_SRC}/scripts/serve.sh
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
WorkingDirectory=${OBSCURA_STATE_DIR}

[Install]
WantedBy=default.target
EOF
    cat > "${unit_dir}/obscura-update.service" <<EOF
[Unit]
Description=Update Obscura from origin/main

[Service]
Type=oneshot
Environment=OBSCURA_PATHS_FILE=${OBSCURA_LIB_DIR}/install.paths
ExecStart=${OBSCURA_SRC}/scripts/update.sh
EOF
    cat > "${unit_dir}/obscura-update.timer" <<EOF
[Unit]
Description=Update Obscura from origin/main every 10 days

[Timer]
OnUnitActiveSec=10d
AccuracySec=1h
Persistent=true
Unit=obscura-update.service

[Install]
WantedBy=timers.target
EOF
  fi
}

enable_systemd() {
  if [[ "$OBSCURA_SERVICE_MODE" == "system" ]]; then
    obscura_system_systemd_ok || return 1
    obscura_priv systemctl daemon-reload
    obscura_priv systemctl enable --now obscura.service
    obscura_priv systemctl enable --now obscura-update.timer
    printf '%s\n' "systemd-system" > "${OBSCURA_STATE_DIR}/supervisor"
    obscura_remove_cron
    return 0
  fi
  obscura_user_systemd_ok || return 1
  systemctl --user daemon-reload
  systemctl --user enable --now obscura.service
  systemctl --user enable --now obscura-update.timer
  printf '%s\n' "systemd-user" > "${OBSCURA_STATE_DIR}/supervisor"
  obscura_remove_cron
  if command -v loginctl >/dev/null 2>&1; then
    if obscura_priv loginctl enable-linger "$(id -un)"; then
      obscura_log "enabled lingering so the user service stays up without a login"
    else
      obscura_warn "could not enable lingering. The user service stops when this login ends."
    fi
  fi
  return 0
}

write_plist() {
  local label="$1"
  local plist="$2"
  local program="$3"
  local interval="${4:-}"
  local stdout="${OBSCURA_LOG_DIR}/serve.log"
  local stderr="${OBSCURA_LOG_DIR}/serve.log"
  if [[ "$label" == "sh.obscura.update" ]]; then
    stdout="${OBSCURA_LOG_DIR}/update.log"
    stderr="${OBSCURA_LOG_DIR}/update.log"
  fi
  mkdir -p "$(dirname "$plist")" "$OBSCURA_LOG_DIR"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${program}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OBSCURA_PATHS_FILE</key>
    <string>${OBSCURA_LIB_DIR}/install.paths</string>
    <key>PATH</key>
    <string>${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>${OBSCURA_STATE_DIR}</string>
  <key>StandardOutPath</key>
  <string>${stdout}</string>
  <key>StandardErrorPath</key>
  <string>${stderr}</string>
EOF
  if [[ -n "$interval" ]]; then
    cat >> "$plist" <<EOF
  <key>StartInterval</key>
  <integer>${interval}</integer>
  <key>RunAtLoad</key>
  <false/>
EOF
  else
    cat >> "$plist" <<EOF
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
EOF
  fi
  cat >> "$plist" <<EOF
</dict>
</plist>
EOF
}

enable_launchd() {
  local domain agent_dir serve_plist update_plist
  command -v launchctl >/dev/null 2>&1 || return 1
  [[ "$(uname -s)" == "Darwin" ]] || return 1
  if [[ "$OBSCURA_SERVICE_MODE" == "system" ]]; then
    domain="system"
    agent_dir="/Library/LaunchDaemons"
    serve_plist="${agent_dir}/sh.obscura.serve.plist"
    update_plist="${agent_dir}/sh.obscura.update.plist"
    write_plist "sh.obscura.serve" "$serve_plist" "${OBSCURA_SRC}/scripts/serve.sh"
    # 864000 seconds is 10 days.
    write_plist "sh.obscura.update" "$update_plist" "${OBSCURA_SRC}/scripts/update.sh" "864000"
    obscura_priv launchctl bootout "${domain}/sh.obscura.serve" >/dev/null 2>&1 || true
    obscura_priv launchctl bootout "${domain}/sh.obscura.update" >/dev/null 2>&1 || true
    obscura_priv launchctl bootstrap "$domain" "$serve_plist"
    obscura_priv launchctl bootstrap "$domain" "$update_plist"
    obscura_priv launchctl enable "${domain}/sh.obscura.serve" || true
    obscura_priv launchctl enable "${domain}/sh.obscura.update" || true
    obscura_priv launchctl kickstart -k "${domain}/sh.obscura.serve"
    printf '%s\n' "launchd-system" > "${OBSCURA_STATE_DIR}/supervisor"
  else
    domain="gui/$(id -u)"
    agent_dir="${HOME}/Library/LaunchAgents"
    serve_plist="${agent_dir}/sh.obscura.serve.plist"
    update_plist="${agent_dir}/sh.obscura.update.plist"
    write_plist "sh.obscura.serve" "$serve_plist" "${OBSCURA_SRC}/scripts/serve.sh"
    # 864000 seconds is 10 days.
    write_plist "sh.obscura.update" "$update_plist" "${OBSCURA_SRC}/scripts/update.sh" "864000"
    launchctl bootout "${domain}/sh.obscura.serve" >/dev/null 2>&1 || true
    launchctl bootout "${domain}/sh.obscura.update" >/dev/null 2>&1 || true
    launchctl bootstrap "$domain" "$serve_plist"
    launchctl bootstrap "$domain" "$update_plist"
    launchctl enable "${domain}/sh.obscura.serve" || true
    launchctl enable "${domain}/sh.obscura.update" || true
    launchctl kickstart -k "${domain}/sh.obscura.serve"
    printf '%s\n' "launchd-user" > "${OBSCURA_STATE_DIR}/supervisor"
  fi
}

start_service() {
  case "$(uname -s)" in
    Linux)
      write_systemd_units
      if enable_systemd; then
        obscura_log "started systemd ${OBSCURA_SERVICE_MODE} service and 10 day update timer"
        return 0
      fi
      obscura_warn "systemd is not running. Starting Obscura in the background and scheduling updates with cron."
      printf '%s\n' "process" > "${OBSCURA_STATE_DIR}/supervisor"
      obscura_install_cron
      obscura_start_fallback
      ;;
    Darwin)
      if enable_launchd; then
        obscura_log "started launchd agent and 10 day update job"
        return 0
      fi
      obscura_die "launchctl failed. Obscura was built but the agent is not loaded."
      ;;
    *)
      obscura_die "unsupported OS"
      ;;
  esac
}

install_packages
ensure_rust
ensure_checkout
write_paths
write_config_if_missing
obscura_load_config
obscura_validate_features

if [[ "${OBSCURA_USE_PREBUILT:-0}" == "1" ]] && obscura_download_prebuilt; then
  obscura_log "installed prebuilt release binaries"
else
  if [[ "${OBSCURA_USE_PREBUILT:-0}" == "1" ]]; then
    obscura_warn "prebuilt asset unavailable. Compiling from source."
  fi
  export PATH="${HOME}/.cargo/bin:/usr/local/cargo/bin:${PATH:-}"
  obscura_build_source
fi
obscura_write_stamp
install_mcp_shim
obscura_ensure_path_marker
start_service

if ! obscura_wait_cdp; then
  obscura_die "CDP did not answer on ${OBSCURA_HOST}:${OBSCURA_PORT}. See ${OBSCURA_LOG_DIR}/serve.log"
fi

probe=$(obscura_probe_host)
obscura_log "OK Obscura CDP is listening at http://${probe}:${OBSCURA_PORT}"
obscura_log "binary ${OBSCURA_BIN_DIR}/obscura"
obscura_log "config ${OBSCURA_CONFIG_FILE}"
obscura_log "logs ${OBSCURA_LOG_DIR}"
obscura_log "checkout ${OBSCURA_SRC}"
if [[ "$OBSCURA_SERVICE_MODE" == "user" ]]; then
  case ":${PATH}:" in
    *":${OBSCURA_BIN_DIR}:"*) ;;
    *) obscura_log "open a new shell, or run: export PATH=\"${OBSCURA_BIN_DIR}:\$PATH\"" ;;
  esac
fi
