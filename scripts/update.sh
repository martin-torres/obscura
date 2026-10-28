#!/usr/bin/env bash
# Fast-forward origin/main when it moved, then rebuild and restart.
# A checkout with uncommitted tracked edits is left untouched.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash." >&2
  exit 1
fi
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

if ! obscura_load_paths; then
  obscura_die "Obscura is not installed. Run scripts/install.sh first."
fi
obscura_load_config
: "${OBSCURA_BRANCH:=main}"
: "${OBSCURA_HOST:=127.0.0.1}"
: "${OBSCURA_PORT:=9222}"
obscura_validate_features

mkdir -p "$OBSCURA_LOG_DIR" "$OBSCURA_STATE_DIR"
exec > >(tee -a "${OBSCURA_LOG_DIR}/update.log") 2>&1

obscura_log "update start src=${OBSCURA_SRC} branch=${OBSCURA_BRANCH}"

if obscura_worktree_dirty; then
  obscura_warn "refusing to pull, rebuild, or restart: ${OBSCURA_SRC} has uncommitted changes"
  git -C "$OBSCURA_SRC" status --porcelain --untracked-files=normal >&2 || true
  obscura_warn "commit or stash those edits yourself. This updater will not overwrite them."
  obscura_log "update skipped"
  exit 0
fi

if ! git -C "$OBSCURA_SRC" fetch --prune origin "$OBSCURA_BRANCH"; then
  obscura_die "git fetch origin ${OBSCURA_BRANCH} failed"
fi

if ! git -C "$OBSCURA_SRC" rev-parse --verify "origin/${OBSCURA_BRANCH}" >/dev/null 2>&1; then
  obscura_die "origin/${OBSCURA_BRANCH} does not exist after fetch"
fi

head_sha=$(git -C "$OBSCURA_SRC" rev-parse HEAD)
origin_sha=$(git -C "$OBSCURA_SRC" rev-parse "origin/${OBSCURA_BRANCH}")

if [[ "$head_sha" != "$origin_sha" ]]; then
  if git -C "$OBSCURA_SRC" merge-base --is-ancestor HEAD "origin/${OBSCURA_BRANCH}"; then
    obscura_log "fast-forward ${head_sha} -> ${origin_sha}"
    git -C "$OBSCURA_SRC" merge --ff-only "origin/${OBSCURA_BRANCH}"
  elif git -C "$OBSCURA_SRC" merge-base --is-ancestor "origin/${OBSCURA_BRANCH}" HEAD; then
    obscura_log "local commits are ahead of origin/${OBSCURA_BRANCH}. Not resetting. Will rebuild only if this checkout is not already installed."
  else
    obscura_warn "local history and origin/${OBSCURA_BRANCH} have diverged. Not merging and not rebuilding."
    obscura_warn "reconcile ${OBSCURA_SRC} yourself (merge or rebase), then push to origin. Nothing was reset."
    obscura_log "update skipped"
    exit 0
  fi
fi

if obscura_stamp_matches; then
  obscura_log "OK already at $(git -C "$OBSCURA_SRC" rev-parse --short HEAD) (${OBSCURA_FEATURES}). Service left as-is."
  exit 0
fi

if [[ "${OBSCURA_UPDATE_SKIP_BUILD:-0}" == "1" ]]; then
  obscura_write_stamp
  obscura_log "OK skip build requested. Stamp updated to $(git -C "$OBSCURA_SRC" rev-parse --short HEAD)."
  exit 0
fi

export PATH="${HOME}/.cargo/bin:${OBSCURA_BIN_DIR}:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

built=0
if [[ "${OBSCURA_USE_PREBUILT:-0}" == "1" ]]; then
  if obscura_download_prebuilt; then
    built=1
  else
    obscura_warn "no matching GitHub release asset for $(git -C "$OBSCURA_SRC" rev-parse --short HEAD). Keeping the installed binary."
    obscura_warn "Unset OBSCURA_USE_PREBUILT in ${OBSCURA_CONFIG_FILE} to compile from source."
    obscura_log "update skipped"
    exit 0
  fi
else
  obscura_build_source
  built=1
fi

if [[ "$built" -ne 1 ]]; then
  obscura_die "build did not produce binaries"
fi

obscura_write_stamp
obscura_log "restarting service"
if ! obscura_restart_service; then
  obscura_die "service restart failed"
fi
if ! obscura_wait_cdp; then
  obscura_die "CDP did not answer on ${OBSCURA_HOST}:${OBSCURA_PORT} after restart. See ${OBSCURA_LOG_DIR}/serve.log"
fi
obscura_log "OK updated to $(git -C "$OBSCURA_SRC" rev-parse --short HEAD) and CDP is up on port ${OBSCURA_PORT}"
