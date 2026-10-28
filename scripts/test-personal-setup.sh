#!/usr/bin/env bash
# Offline checks for the auto-updater: dirty trees, fast-forward, divergence,
# and the 10-day cron gate. A manual run ignores that gate.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash." >&2
  exit 1
fi
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git_identity() {
  git -C "$1" config user.email "obscura-setup@example.com"
  git -C "$1" config user.name "obscura-setup"
}

git init -b main "$TMP/origin" >/dev/null
git_identity "$TMP/origin"
echo "v1" > "$TMP/origin/README"
git -C "$TMP/origin" add README
git -C "$TMP/origin" commit -m init >/dev/null

git clone "$TMP/origin" "$TMP/checkout" >/dev/null
git_identity "$TMP/checkout"

mkdir -p "$TMP/state/log" "$TMP/bin" "$TMP/lib"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$TMP/bin/obscura"
chmod 0755 "$TMP/bin/obscura"
git -C "$TMP/checkout" rev-parse HEAD > "$TMP/state/installed.commit"
printf '%s\n' "render" > "$TMP/state/installed.features"
printf '%s\n' "source" > "$TMP/state/installed.mode"
cat > "$TMP/obscura.env" <<EOF
OBSCURA_HOST=127.0.0.1
OBSCURA_PORT=9222
OBSCURA_FEATURES=render
OBSCURA_USE_PREBUILT=0
OBSCURA_BRANCH=main
EOF
cat > "$TMP/lib/install.paths" <<EOF
OBSCURA_SERVICE_MODE='user'
OBSCURA_BIN_DIR='$TMP/bin'
OBSCURA_LIB_DIR='$TMP/lib'
OBSCURA_CONFIG_DIR='$TMP'
OBSCURA_CONFIG_FILE='$TMP/obscura.env'
OBSCURA_STATE_DIR='$TMP/state'
OBSCURA_LOG_DIR='$TMP/state/log'
OBSCURA_STORAGE_DIR='$TMP/state/storage'
OBSCURA_SRC='$TMP/checkout'
OBSCURA_MANAGED_CLONE='0'
EOF

run_update() {
  OBSCURA_PATHS_FILE="$TMP/lib/install.paths" \
    bash "$ROOT/scripts/update.sh" >"$TMP/out" 2>&1
}

run_update
grep -q "already at" "$TMP/out"

echo "local edit" >> "$TMP/checkout/README"
run_update
grep -q "uncommitted" "$TMP/out"
grep -q "local edit" "$TMP/checkout/README"
if git -C "$TMP/checkout" diff --quiet; then
  echo "dirty checkout was modified by the updater" >&2
  exit 1
fi

git -C "$TMP/checkout" checkout -- README
echo "notes" > "$TMP/checkout/notes.txt"
run_update
grep -q "uncommitted" "$TMP/out"
grep -q "notes" "$TMP/checkout/notes.txt"
rm -f "$TMP/checkout/notes.txt"

echo "v2" >> "$TMP/origin/README"
git -C "$TMP/origin" add README
git -C "$TMP/origin" commit -m v2 >/dev/null
OBSCURA_UPDATE_SKIP_BUILD=1 run_update
grep -q "v2" "$TMP/checkout/README"
head_sha=$(git -C "$TMP/checkout" rev-parse HEAD)
stamp=$(cat "$TMP/state/installed.commit")
[[ "$head_sha" == "$stamp" ]]
[[ -n "$(cat "$TMP/state/last-successful-check")" ]]

echo "v3" >> "$TMP/origin/README"
git -C "$TMP/origin" add README
git -C "$TMP/origin" commit -m v3 >/dev/null
OBSCURA_UPDATE_SCHEDULED=1 OBSCURA_UPDATE_SKIP_BUILD=1 run_update
grep -q "scheduled check skipped" "$TMP/out"
if grep -q "v3" "$TMP/checkout/README"; then
  echo "scheduled run fast-forwarded before 10 days" >&2
  exit 1
fi

OBSCURA_UPDATE_SKIP_BUILD=1 run_update
grep -q "v3" "$TMP/checkout/README"

echo "v4" >> "$TMP/origin/README"
git -C "$TMP/origin" add README
git -C "$TMP/origin" commit -m v4 >/dev/null
now=$(date +%s)
printf '%s\n' "$((now - 900000))" > "$TMP/state/last-successful-check"
OBSCURA_UPDATE_SCHEDULED=1 OBSCURA_UPDATE_SKIP_BUILD=1 run_update
grep -q "v4" "$TMP/checkout/README"
grep -q "fast-forward" "$TMP/out"

echo "local only" >> "$TMP/checkout/README"
git -C "$TMP/checkout" add README
git -C "$TMP/checkout" commit -m local >/dev/null
local_sha=$(git -C "$TMP/checkout" rev-parse HEAD)
echo "origin only" >> "$TMP/origin/README"
git -C "$TMP/origin" add README
git -C "$TMP/origin" commit -m elsewhere >/dev/null
run_update
grep -q "diverged" "$TMP/out"
[[ "$(git -C "$TMP/checkout" rev-parse HEAD)" == "$local_sha" ]]
git -C "$TMP/checkout" merge-base --is-ancestor "$local_sha" HEAD

echo "personal setup updater checks passed"
