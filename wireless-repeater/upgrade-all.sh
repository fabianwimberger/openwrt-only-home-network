#!/usr/bin/env bash
# Builds and deploys profiles in parallel, logging each to its own file.
# Usage: ./upgrade-all.sh [profile1 profile2 ...]
# If no profiles are given, every profile in ./profiles/ is built.
# Logs written to: logs/upgrade-<profile>-<timestamp>.log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="${PROFILES_DIR:-$SCRIPT_DIR/profiles}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

if [[ $# -gt 0 ]]; then
    PROFILES=("$@")
else
    PROFILES=()
    for f in "$PROFILES_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .conf)"
        [[ "$name" == "common" ]] && continue
        PROFILES+=("$name")
    done
fi

if [[ ${#PROFILES[@]} -eq 0 ]]; then
    echo "Error: no profiles found in $PROFILES_DIR"
    exit 1
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
pids=()
logs=()

for profile in "${PROFILES[@]}"; do
    log="$LOG_DIR/upgrade-${profile}-${TIMESTAMP}.log"
    logs+=("$log")
    (
        echo "=== [$(date)] START: $profile ===" | tee "$log"

        echo "--- BUILD ---" | tee -a "$log"
        "$SCRIPT_DIR/build.sh" "$profile" 2>&1 | tee -a "$log"

        echo "--- DEPLOY ---" | tee -a "$log"
        # shellcheck source=/dev/null
        [[ ! -f "$PROFILES_DIR/common.conf" ]] && echo "Error: $PROFILES_DIR/common.conf not found" >&2 && exit 1
        [[ ! -f "$PROFILES_DIR/${profile}.conf" ]] && echo "Error: $PROFILES_DIR/${profile}.conf not found" >&2 && exit 1
        source "$PROFILES_DIR/common.conf"
        # shellcheck source=/dev/null
        source "$PROFILES_DIR/${profile}.conf"

        OUTPUT_DIR="$SCRIPT_DIR/output/$profile"
        FIRMWARE=$(find "$OUTPUT_DIR" -name '*-sysupgrade.bin' -type f | head -1)
        if [[ -z "$FIRMWARE" ]]; then
            echo "Error: no sysupgrade firmware found in $OUTPUT_DIR" >&2
            exit 1
        fi
        FIRMWARE_NAME="$(basename "$FIRMWARE")"
        SSH_OPTS=(-o StrictHostKeyChecking=accept-new)

        echo "Uploading $FIRMWARE_NAME to $DEVICE_IP ..." | tee -a "$log"
        SSHPASS="$ROOT_PASSWORD" timeout 120 sshpass -e scp -O "${SSH_OPTS[@]}" "$FIRMWARE" "root@${DEVICE_IP}:/tmp/${FIRMWARE_NAME}" 2>&1 | tee -a "$log"

        echo "Running sysupgrade on $DEVICE_IP ..." | tee -a "$log"
        SSHPASS="$ROOT_PASSWORD" timeout 120 sshpass -e ssh "${SSH_OPTS[@]}" "root@${DEVICE_IP}" "sysupgrade -n /tmp/${FIRMWARE_NAME}" 2>&1 | tee -a "$log" || true

        echo "Waiting for $DEVICE_IP to come back online ..." | tee -a "$log"
        until ping -c1 -W5 -q "$DEVICE_IP" &>/dev/null; do sleep 5; done
        echo "Device is back online." | tee -a "$log"

        echo "=== [$(date)] DONE: $profile ===" | tee -a "$log"
    ) &
    pid=$!
    pids+=("$pid")
    echo "Started $profile (pid $pid, log: $log)"
done

echo ""
echo "All ${#PROFILES[@]} builds+deploys running in parallel. Waiting..."
echo ""

failed=()
for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    profile="${PROFILES[$i]}"
    if wait "$pid"; then
        echo "[OK]   $profile"
    else
        rc=$?
        echo "[FAIL] $profile (exit $rc)"
        failed+=("$profile")
    fi
done

echo ""
echo "=== Summary ==="
echo "Logs written to: $LOG_DIR/"
for log in "${logs[@]}"; do
    echo "  $log"
done

if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    echo "FAILED profiles: ${failed[*]}"
    exit 1
else
    echo "All profiles upgraded successfully."
fi
