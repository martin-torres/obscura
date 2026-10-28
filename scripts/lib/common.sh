#!/usr/bin/env bash
# Shared helpers for the personal Obscura install. Source this file.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Obscura scripts require bash." >&2
  exit 1
fi

OBSCURA_DEFAULT_REPO="${OBSCURA_DEFAULT_REPO:-https://github.com/martin-torres/obscura.git}"
OBSCURA_UPSTREAM_URL="${OBSCURA_UPSTREAM_URL:-https://github.com/h4ckf0r0day/obscura.git}"
OBSCURA_BRANCH="${OBSCURA_BRANCH:-main}"
OBSCURA_PORT="${OBSCURA_PORT:-9222}"
OBSCURA_HOST="${OBSCURA_HOST:-127.0.0.1}"

obscura_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

obscura_warn() {
  obscura_log "WARNING $*" >&2
}

obscura_die() {
  obscura_log "ERROR $*" >&2
  exit 1
}

obscura_priv() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

obscura_layout() {
  local mode="${OBSCURA_SERVICE:-auto}"
  if [[ "$mode" == "auto" ]]; then
    if [[ "$(id -u)" -eq 0 ]]; then
      mode="system"
    else
      mode="user"
    fi
  fi
  case "$mode" in
    user|system) ;;
    *) obscura_die "OBSCURA_SERVICE must be user, system, or auto" ;;
  esac
  OBSCURA_SERVICE_MODE="$mode"
  if [[ "$mode" == "system" ]]; then
    OBSCURA_BIN_DIR="${OBSCURA_BIN_DIR:-/usr/local/bin}"
    OBSCURA_LIB_DIR="${OBSCURA_LIB_DIR:-/usr/local/lib/obscura}"
    OBSCURA_CONFIG_DIR="${OBSCURA_CONFIG_DIR:-/etc/obscura}"
    OBSCURA_STATE_DIR="${OBSCURA_STATE_DIR:-/var/lib/obscura}"
    OBSCURA_LOG_DIR="${OBSCURA_LOG_DIR:-/var/log/obscura}"
    if [[ -z "${OBSCURA_SRC:-}" ]]; then
      OBSCURA_SRC="/usr/local/src/obscura"
    fi
  else
    OBSCURA_BIN_DIR="${OBSCURA_BIN_DIR:-${HOME}/.local/bin}"
    OBSCURA_LIB_DIR="${OBSCURA_LIB_DIR:-${HOME}/.local/lib/obscura}"
    OBSCURA_CONFIG_DIR="${OBSCURA_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/obscura}"
    OBSCURA_STATE_DIR="${OBSCURA_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/obscura}"
    OBSCURA_LOG_DIR="${OBSCURA_LOG_DIR:-${OBSCURA_STATE_DIR}/log}"
    if [[ -z "${OBSCURA_SRC:-}" ]]; then
      OBSCURA_SRC="${XDG_DATA_HOME:-$HOME/.local/share}/obscura/src"
    fi
  fi
  OBSCURA_CONFIG_FILE="${OBSCURA_CONFIG_FILE:-${OBSCURA_CONFIG_DIR}/obscura.env}"
  OBSCURA_STORAGE_DIR="${OBSCURA_STORAGE_DIR:-${OBSCURA_STATE_DIR}/storage}"
}

obscura_load_paths() {
  local file="${OBSCURA_PATHS_FILE:-}"
  if [[ -z "$file" ]]; then
    if [[ -f "${HOME}/.local/lib/obscura/install.paths" ]]; then
      file="${HOME}/.local/lib/obscura/install.paths"
    elif [[ -f /usr/local/lib/obscura/install.paths ]]; then
      file="/usr/local/lib/obscura/install.paths"
    fi
  fi
  [[ -n "$file" && -f "$file" ]] || return 1
  # shellcheck disable=SC1090
  source "$file"
  OBSCURA_PATHS_FILE="$file"
}

obscura_load_config() {
  [[ -n "${OBSCURA_CONFIG_FILE:-}" && -f "$OBSCURA_CONFIG_FILE" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$OBSCURA_CONFIG_FILE"
  set +a
}

obscura_validate_features() {
  case "${OBSCURA_FEATURES:-render}" in
    render|render,stealth|stealth|none) OBSCURA_FEATURES="${OBSCURA_FEATURES:-render}" ;;
    *) obscura_die "OBSCURA_FEATURES must be render, render,stealth, stealth, or none" ;;
  esac
}

obscura_pid1_is_systemd() {
  local comm
  comm=$(ps -p 1 -o comm= 2>/dev/null || true)
  comm=${comm##*/}
  [[ "$comm" == "systemd" ]]
}

obscura_user_systemd_ok() {
  obscura_pid1_is_systemd || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user show-environment >/dev/null 2>&1
}

obscura_system_systemd_ok() {
  obscura_pid1_is_systemd || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
}

obscura_origin_slug() {
  local url
  url=$(git -C "$OBSCURA_SRC" remote get-url origin 2>/dev/null || true)
  url=${url%.git}
  url=${url%/}
  case "$url" in
    git@github.com:*) printf '%s\n' "${url#git@github.com:}" ;;
    https://github.com/*) printf '%s\n' "${url#https://github.com/}" ;;
    http://github.com/*) printf '%s\n' "${url#http://github.com/}" ;;
    ssh://git@github.com/*) printf '%s\n' "${url#ssh://git@github.com/}" ;;
    *) printf '\n' ;;
  esac
}

obscura_asset_name() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  case "${os}-${arch}" in
    Linux-x86_64) printf '%s\n' "obscura-x86_64-linux.tar.gz" ;;
    Linux-aarch64|Linux-arm64) printf '%s\n' "obscura-aarch64-linux.tar.gz" ;;
    Darwin-arm64) printf '%s\n' "obscura-aarch64-macos.tar.gz" ;;
    Darwin-x86_64) printf '%s\n' "obscura-x86_64-macos.tar.gz" ;;
    *) return 1 ;;
  esac
}

# Tracked edits and untracked files both block a pull. Ignored build
# output such as target/ does not.
obscura_worktree_dirty() {
  [[ -n "$(git -C "$OBSCURA_SRC" status --porcelain --untracked-files=normal)" ]]
}

obscura_probe_host() {
  case "${OBSCURA_HOST}" in
    0.0.0.0|::|"[::]") printf '%s\n' "127.0.0.1" ;;
    *) printf '%s\n' "$OBSCURA_HOST" ;;
  esac
}

obscura_loopback_host() {
  case "${OBSCURA_HOST}" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) return 1 ;;
  esac
}

obscura_check_bind() {
  if obscura_loopback_host; then
    return 0
  fi
  local token="${OBSCURA_CDP_TOKEN:-}"
  if [[ "${#token}" -lt 32 ]]; then
    obscura_die "OBSCURA_HOST=${OBSCURA_HOST} is not loopback. Set OBSCURA_CDP_TOKEN to at least 32 bytes in ${OBSCURA_CONFIG_FILE}, or bind 127.0.0.1."
  fi
}

obscura_wait_cdp() {
  local host url i
  host=$(obscura_probe_host)
  url="http://${host}:${OBSCURA_PORT}/json/version"
  i=0
  while [[ "$i" -lt 60 ]]; do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

obscura_install_bins() {
  local src_bin="${1}"
  local src_worker="${2}"
  [[ -x "$src_bin" ]] || obscura_die "missing binary ${src_bin}"
  [[ -x "$src_worker" ]] || obscura_die "missing binary ${src_worker}"
  mkdir -p "$OBSCURA_BIN_DIR"
  install -m 0755 "$src_bin" "${OBSCURA_BIN_DIR}/obscura"
  install -m 0755 "$src_worker" "${OBSCURA_BIN_DIR}/obscura-worker"
}

obscura_cargo_features_args() {
  case "$OBSCURA_FEATURES" in
    render) printf '%s\n' "--features render" ;;
    render,stealth) printf '%s\n' "--features render,stealth" ;;
    stealth) printf '%s\n' "--no-default-features --features stealth" ;;
    none) printf '%s\n' "--no-default-features" ;;
  esac
}

obscura_build_source() {
  obscura_validate_features
  local jobs feature_args
  jobs="${CARGO_BUILD_JOBS:-2}"
  feature_args=$(obscura_cargo_features_args)
  obscura_log "building release binaries in ${OBSCURA_SRC} (${OBSCURA_FEATURES})"
  (
    cd "$OBSCURA_SRC" || exit 1
    # shellcheck disable=SC2086
    CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS="$jobs" \
      cargo build --release -p obscura-cli --bins ${feature_args}
  )
  obscura_install_bins \
    "${OBSCURA_SRC}/target/release/obscura" \
    "${OBSCURA_SRC}/target/release/obscura-worker"
}

obscura_latest_release_tag() {
  local slug json
  slug=$(obscura_origin_slug)
  [[ -n "$slug" ]] || return 1
  json=$(curl -fsSL --max-time 30 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: obscura-personal-setup" \
    "https://api.github.com/repos/${slug}/releases/latest") || return 1
  printf '%s' "$json" | python3 -c 'import json,sys
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(1)
tag=data.get("tag_name") or ""
if not tag:
    sys.exit(1)
print(tag)'
}

obscura_download_prebuilt() {
  local tag="${1:-}" slug asset url tmp
  slug=$(obscura_origin_slug)
  [[ -n "$slug" ]] || return 1
  asset=$(obscura_asset_name) || return 1
  if [[ -z "$tag" ]]; then
    tag=$(git -C "$OBSCURA_SRC" describe --exact-match --tags HEAD 2>/dev/null || true)
  fi
  if [[ -z "$tag" && "${OBSCURA_USE_PREBUILT:-0}" == "1" ]]; then
    tag=$(obscura_latest_release_tag) || return 1
    obscura_warn "HEAD is not a release tag. Using latest GitHub release ${tag}, which can lag origin/main."
  fi
  [[ -n "$tag" ]] || return 1
  url="https://github.com/${slug}/releases/download/${tag}/${asset}"
  tmp=$(mktemp -d)
  obscura_log "downloading ${url}"
  if ! curl -fL --retry 3 --max-time 180 -o "${tmp}/asset.tar.gz" "$url"; then
    rm -rf "$tmp"
    return 1
  fi
  tar -xzf "${tmp}/asset.tar.gz" -C "$tmp"
  [[ -f "${tmp}/obscura" && -f "${tmp}/obscura-worker" ]] || {
    rm -rf "$tmp"
    return 1
  }
  chmod 0755 "${tmp}/obscura" "${tmp}/obscura-worker"
  obscura_install_bins "${tmp}/obscura" "${tmp}/obscura-worker"
  printf '%s\n' "$tag" > "${OBSCURA_STATE_DIR}/installed.release"
  rm -rf "$tmp"
}

obscura_write_stamp() {
  mkdir -p "$OBSCURA_STATE_DIR"
  git -C "$OBSCURA_SRC" rev-parse HEAD > "${OBSCURA_STATE_DIR}/installed.commit"
  printf '%s\n' "$OBSCURA_FEATURES" > "${OBSCURA_STATE_DIR}/installed.features"
  if [[ "${OBSCURA_USE_PREBUILT:-0}" == "1" ]]; then
    printf '%s\n' "prebuilt" > "${OBSCURA_STATE_DIR}/installed.mode"
  else
    printf '%s\n' "source" > "${OBSCURA_STATE_DIR}/installed.mode"
  fi
}

obscura_stamp_matches() {
  local head features mode
  [[ "${OBSCURA_FORCE_REBUILD:-0}" == "1" ]] && return 1
  head=$(git -C "$OBSCURA_SRC" rev-parse HEAD)
  features=$(cat "${OBSCURA_STATE_DIR}/installed.features" 2>/dev/null || true)
  mode=$(cat "${OBSCURA_STATE_DIR}/installed.mode" 2>/dev/null || true)
  [[ -f "${OBSCURA_BIN_DIR}/obscura" ]] || return 1
  [[ "$(cat "${OBSCURA_STATE_DIR}/installed.commit" 2>/dev/null || true)" == "$head" ]] || return 1
  [[ "$features" == "$OBSCURA_FEATURES" ]] || return 1
  if [[ "${OBSCURA_USE_PREBUILT:-0}" == "1" ]]; then
    [[ "$mode" == "prebuilt" ]]
  else
    [[ "$mode" == "source" || -z "$mode" ]]
  fi
}

obscura_serve_args() {
  obscura_check_bind
  mkdir -p "$OBSCURA_STORAGE_DIR"
  OBSCURA_SERVE_ARGV=(
    "${OBSCURA_BIN_DIR}/obscura"
    serve
    --host "$OBSCURA_HOST"
    --port "$OBSCURA_PORT"
    --storage-dir "$OBSCURA_STORAGE_DIR"
  )
  if [[ "${OBSCURA_STEALTH:-0}" == "1" ]]; then
    OBSCURA_SERVE_ARGV+=(--stealth)
  fi
  if [[ -n "${OBSCURA_PROXY:-}" ]]; then
    OBSCURA_SERVE_ARGV+=(--proxy "$OBSCURA_PROXY")
  fi
  if [[ "${OBSCURA_ALLOW_PRIVATE_NETWORK:-0}" == "1" ]]; then
    OBSCURA_SERVE_ARGV+=(--allow-private-network)
  fi
  if [[ -n "${OBSCURA_SERVE_ARGS:-}" ]]; then
    local extra=()
    # Operator-controlled flags from obscura.env. Split on whitespace.
    # shellcheck disable=SC2206
    extra=( $OBSCURA_SERVE_ARGS )
    OBSCURA_SERVE_ARGV+=("${extra[@]}")
  fi
}

obscura_stop_fallback() {
  local pidfile="${OBSCURA_STATE_DIR}/serve.pid"
  local pid i
  [[ -f "$pidfile" ]] || return 0
  pid=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    i=0
    while [[ "$i" -lt 20 ]] && kill -0 "$pid" 2>/dev/null; do
      sleep 0.5
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pidfile"
}

obscura_start_fallback() {
  local pid
  mkdir -p "$OBSCURA_LOG_DIR" "$OBSCURA_STATE_DIR"
  obscura_stop_fallback
  # shellcheck disable=SC2094
  nohup "${OBSCURA_SRC}/scripts/serve.sh" >> "${OBSCURA_LOG_DIR}/serve.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "${OBSCURA_STATE_DIR}/serve.pid"
  disown "$pid" 2>/dev/null || true
}

obscura_restart_service() {
  local supervisor
  supervisor=$(cat "${OBSCURA_STATE_DIR}/supervisor" 2>/dev/null || true)
  case "$supervisor" in
    systemd-user)
      systemctl --user restart obscura.service
      ;;
    systemd-system)
      obscura_priv systemctl restart obscura.service
      ;;
    launchd-user)
      launchctl kickstart -k "gui/$(id -u)/sh.obscura.serve"
      ;;
    launchd-system)
      launchctl kickstart -k "system/sh.obscura.serve"
      ;;
    process|"")
      obscura_load_config
      obscura_serve_args
      obscura_start_fallback
      ;;
    *)
      obscura_die "unknown supervisor ${supervisor}"
      ;;
  esac
}

obscura_ensure_path_marker() {
  [[ "$OBSCURA_SERVICE_MODE" == "user" ]] || return 0
  local file begin end block tmp
  begin="# >>> obscura personal setup >>>"
  end="# <<< obscura personal setup <<<"
  block="${begin}
export PATH=\"${OBSCURA_BIN_DIR}:\$PATH\"
${end}"
  for file in "${HOME}/.profile" "${HOME}/.zprofile"; do
    [[ "$file" == "${HOME}/.zprofile" && "$(uname -s)" != "Darwin" ]] && continue
    touch "$file"
    if grep -qF "$begin" "$file" 2>/dev/null; then
      tmp=$(mktemp)
      awk -v begin="$begin" -v end="$end" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        skip != 1 { print }
      ' "$file" > "$tmp"
      printf '\n%s\n' "$block" >> "$tmp"
      mv "$tmp" "$file"
    else
      printf '\n%s\n' "$block" >> "$file"
    fi
  done
}

obscura_remove_path_marker() {
  local file begin end tmp
  begin="# >>> obscura personal setup >>>"
  end="# <<< obscura personal setup <<<"
  for file in "${HOME}/.profile" "${HOME}/.zprofile"; do
    [[ -f "$file" ]] || continue
    grep -qF "$begin" "$file" 2>/dev/null || continue
    tmp=$(mktemp)
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      skip != 1 { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  done
}

# 10 days. Cron fires daily and allows an hour of slack so a run that
# lands a few seconds short of 864000s is not pushed out another day.
OBSCURA_UPDATE_INTERVAL_SEC=864000
OBSCURA_UPDATE_INTERVAL_SLACK_SEC=3600

obscura_record_successful_check() {
  mkdir -p "$OBSCURA_STATE_DIR"
  date +%s > "${OBSCURA_STATE_DIR}/last-successful-check"
}

# Scheduled runs (cron) wait 10 days after the last successful check.
# A manual scripts/update.sh leaves OBSCURA_UPDATE_SCHEDULED unset and always runs.
obscura_scheduled_check_due() {
  [[ "${OBSCURA_UPDATE_SCHEDULED:-0}" == "1" ]] || return 0
  local stamp now elapsed due
  stamp=$(cat "${OBSCURA_STATE_DIR}/last-successful-check" 2>/dev/null || true)
  case "$stamp" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now=$(date +%s)
  elapsed=$((now - stamp))
  if [[ "$elapsed" -lt 0 ]]; then
    return 0
  fi
  due=$((OBSCURA_UPDATE_INTERVAL_SEC - OBSCURA_UPDATE_INTERVAL_SLACK_SEC))
  if [[ "$elapsed" -lt "$due" ]]; then
    return 1
  fi
  return 0
}

obscura_remove_cron() {
  command -v crontab >/dev/null 2>&1 || return 0
  local current tmp
  current=$(crontab -l 2>/dev/null || true)
  [[ "$current" == *"OBSCURA_UPDATE_BEGIN"* ]] || return 0
  tmp=$(mktemp)
  printf '%s\n' "$current" | awk '
    $0 == "# OBSCURA_UPDATE_BEGIN" { skip=1; next }
    $0 == "# OBSCURA_UPDATE_END" { skip=0; next }
    skip != 1 { print }
  ' > "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

obscura_install_cron() {
  command -v crontab >/dev/null 2>&1 || {
    obscura_warn "crontab is not available, so the auto-updater is not scheduled. Run scripts/update.sh yourself, or install on a host with systemd or launchd."
    return 0
  }
  local current tmp
  obscura_remove_cron
  current=$(crontab -l 2>/dev/null || true)
  tmp=$(mktemp)
  printf '%s\n' "$current" > "$tmp"
  cat >> "$tmp" <<EOF
# OBSCURA_UPDATE_BEGIN
17 4 * * * OBSCURA_UPDATE_SCHEDULED=1 ${OBSCURA_SRC}/scripts/update.sh
# OBSCURA_UPDATE_END
EOF
  crontab "$tmp"
  rm -f "$tmp"
  obscura_log "scheduled scripts/update.sh daily at 04:17. It checks origin only when the last successful check is at least 10 days old."
}
