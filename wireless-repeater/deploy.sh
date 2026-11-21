#!/usr/bin/env bash
# Flash one profile over SSH with your key: upload, checksum, sysupgrade -T, sysupgrade -n,
# wait for the node, post-check. The work is in ../tools/flash.sh; pass --dry-run to stop
# after the `sysupgrade -T` check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"

usage() {
    echo "Usage: $0 [--dry-run] <profile>"
    echo ""
    echo "Available profiles:"
    for f in "$PROFILES_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .conf)"
        [[ "$name" == "common" ]] && continue
        echo "  $name"
    done
    exit 1
}

[[ $# -lt 1 ]] && usage

PROFILE_NAME="${!#}"
[[ ! -f "$PROFILES_DIR/${PROFILE_NAME}.conf" ]] && echo "Error: profile '$PROFILE_NAME' not found" && exit 1

exec "$SCRIPT_DIR/../tools/flash.sh" "$@"
