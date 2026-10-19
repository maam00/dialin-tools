#!/bin/bash
# Shared directory lock compatible with the existing mkdir/rmdir convention. Never removes stale/foreign locks.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="${DIALIN_BUILD_LOCK_DIR:-$REPO/.build-lock}"
TIMEOUT=900
if [ "${1:-}" = "--timeout" ]; then TIMEOUT="${2:-}"; shift 2; fi
[ "${1:-}" = "--" ] && shift
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo 'Build-lock timeout must be a nonnegative integer.' >&2; exit 2; }
[ "$#" -gt 0 ] || { echo 'Usage: scripts/with-build-lock.sh [--timeout seconds] -- command [args...]' >&2; exit 2; }
if [ -n "${DIALIN_BUILD_LOCK_TOKEN:-}" ] && [ -f "$LOCK/owner" ] && [ "$(cat "$LOCK/owner")" = "$DIALIN_BUILD_LOCK_TOKEN" ]; then
    "$@"
    exit $?
fi
OWNER="$$.$RANDOM.$RANDOM"
START=$SECONDS
while ! mkdir "$LOCK" 2>/dev/null; do
    if [ -e "$LOCK" ] && [ ! -d "$LOCK" ]; then
        echo "A legacy file lock exists at $LOCK. Finish its holder and inspect it before manually migrating; nothing was removed." >&2
        exit 3
    fi
    if [ $((SECONDS - START)) -ge "$TIMEOUT" ]; then
        echo "Timed out waiting for the build lock at $LOCK. Its holder was not interrupted or removed." >&2
        exit 4
    fi
    sleep 1
done
umask 077
printf '%s\n' "$OWNER" > "$LOCK/owner"
release() {
    if [ -f "$LOCK/owner" ] && [ "$(cat "$LOCK/owner")" = "$OWNER" ]; then
        rm "$LOCK/owner"
        rmdir "$LOCK" 2>/dev/null || true
    fi
}
trap release EXIT
# Bash defers these traps while a foreground command runs. Keep the lock until that command exits.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export DIALIN_BUILD_LOCK_TOKEN="$OWNER" DIALIN_BUILD_LOCK_DIR="$LOCK"
"$@"
