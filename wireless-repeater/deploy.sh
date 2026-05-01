#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"
COMMON_FILE="$PROFILES_DIR/common.conf"

usage() {
    echo "Usage: $0 <profile>"
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

PROFILE_NAME="$1"
PROFILE_FILE="$PROFILES_DIR/${PROFILE_NAME}.conf"

[[ ! -f "$COMMON_FILE" ]] && echo "Error: common.conf not found" && exit 1
[[ ! -f "$PROFILE_FILE" ]] && echo "Error: profile '$PROFILE_NAME' not found" && exit 1

# shellcheck source=/dev/null
source "$COMMON_FILE"
# shellcheck source=/dev/null
source "$PROFILE_FILE"

OUTPUT_DIR="$SCRIPT_DIR/output/$PROFILE_NAME"
FIRMWARE=$(find "$OUTPUT_DIR" -name '*-sysupgrade.bin' -type f | head -1)

if [[ -z "$FIRMWARE" ]]; then
    echo "Error: no sysupgrade firmware found in $OUTPUT_DIR"
    echo "Run './build.sh $PROFILE_NAME' first."
    exit 1
fi

FIRMWARE_NAME="$(basename "$FIRMWARE")"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Deploying to $DEVICE_IP ==="
echo "    Firmware: $FIRMWARE_NAME"
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" != [yY] ]] && echo "Aborted." && exit 0

echo "=== Uploading firmware ==="
timeout 30 sshpass -p "$ROOT_PASSWORD" scp -O $SSH_OPTS "$FIRMWARE" "root@${DEVICE_IP}:/tmp/${FIRMWARE_NAME}"

echo "=== Starting sysupgrade (no config preservation) ==="
timeout 30 sshpass -p "$ROOT_PASSWORD" ssh $SSH_OPTS "root@${DEVICE_IP}" "sysupgrade -n /tmp/${FIRMWARE_NAME}" || true

echo ""
echo "=== Device is upgrading and will reboot ==="
echo "    It should come back at $DEVICE_IP"
