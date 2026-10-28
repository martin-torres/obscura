#!/usr/bin/env bash
# Exec the installed Obscura CDP server using the personal config.
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
: "${OBSCURA_HOST:=127.0.0.1}"
: "${OBSCURA_PORT:=9222}"
mkdir -p "$OBSCURA_STATE_DIR"
cd "$OBSCURA_STATE_DIR" || exit 1
obscura_serve_args
exec "${OBSCURA_SERVE_ARGV[@]}"
