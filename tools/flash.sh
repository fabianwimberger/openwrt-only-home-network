#!/usr/bin/env bash
# Key-based flash: upload with scp -O, verify the checksum, `sysupgrade -T`, then `sysupgrade -n`,
# drop the old host key, wait for SSH and check the node afterwards.
#   flash.sh [--dry-run] [--parallel] [--wait SEC] <node>...
# --dry-run stops after `sysupgrade -T` and removes the uploaded image again.
set -euo pipefail
# shellcheck source=tools/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY=0 PARALLEL=0 WAIT=300 NODES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run|-T) DRY=1 ;;
        --parallel) PARALLEL=1 ;;
        --wait) WAIT="$2"; shift ;;
        -h|--help) sed -n '2,5p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) NODES+=("$1") ;;
    esac
    shift
done
[[ ${#NODES[@]} -gt 0 ]] || die "usage: flash.sh [--dry-run] [--parallel] <node>...  (nodes: $(nodes_present | tr '\n' ' '))"

flash_one() {
    local node="$1" ip fw name local_sum remote_sum t0 up rel bss link carr expect gone until_link
    ip="$(node_ip "$node")"
    fw="$(firmware_for "$node")"
    [[ -n "$fw" ]] || { echo "FLASH FAILED $node: no sysupgrade image in output/$node (run build.sh $node)"; return 1; }
    name="$(basename "$fw")"
    local_sum="$(sha256sum "$fw" | cut -d' ' -f1)"

    scp -O "${SSH_OPTS[@]}" "$fw" "root@$ip:/tmp/$name" || { echo "FLASH FAILED $node: upload"; return 1; }
    remote_sum="$(rssh "$node" "sha256sum /tmp/$name" | cut -d' ' -f1)"
    if [[ "$remote_sum" != "$local_sum" ]]; then
        rssh "$node" "rm -f /tmp/$name" || true
        echo "FLASH FAILED $node: checksum mismatch after upload"
        return 1
    fi
    if ! rssh "$node" "sysupgrade -T /tmp/$name" >/dev/null 2>&1; then
        rssh "$node" "rm -f /tmp/$name" || true
        echo "FLASH FAILED $node: sysupgrade -T rejected $name"
        return 1
    fi
    if [[ "$DRY" == 1 ]]; then
        rssh "$node" "rm -f /tmp/$name" || true
        echo "DRY RUN OK $node: $name uploaded, checksum matches, sysupgrade -T accepts it, nothing flashed"
        return 0
    fi

    t0=$SECONDS
    # The connection drops while the node reboots, so a non-zero exit here is expected.
    rssh "$node" "sysupgrade -n /tmp/$name" >/dev/null 2>&1 || true
    # sysupgrade -n regenerates the host key; the stale entry would block the next connection.
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    # Wait for it to go down first, so the first answer is not the old system.
    gone=$((SECONDS + 90))
    while ping -c1 -W1 -q "$ip" >/dev/null 2>&1 && [[ $SECONDS -lt $gone ]]; do sleep 2; done
    wait_ssh "$node" "$WAIT" || { echo "FLASH FAILED $node: no ssh $WAIT s after sysupgrade"; return 1; }
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true

    # Post-check: fresh boot, expected release, BSSes up, backhaul connected on repeaters.
    sleep 20
    read -r up rel bss link carr < <(node_status "$node")
    expect="$(node_var "$node" OPENWRT_VERSION)"
    [[ "$expect" == main || "$rel" == "$expect" ]] || { echo "FLASH FAILED $node: runs $rel, expected $expect"; return 1; }
    [[ "$up" -lt $((SECONDS - t0 + 120)) ]] || { echo "FLASH FAILED $node: uptime ${up}s, it did not reboot"; return 1; }
    [[ "$bss" -ge 1 ]] || { echo "FLASH FAILED $node: no AP interface up after ${up}s"; return 1; }
    if [[ "$(node_tier "$node")" == wireless-repeater ]]; then
        until_link=$((SECONDS + 120))
        while [[ "$link" == none && $SECONDS -lt $until_link ]]; do
            sleep 5
            read -r up rel bss link carr < <(node_status "$node")
        done
        [[ "$link" != none ]] || { echo "FLASH FAILED $node: backhaul STA not connected after 120 s"; return 1; }
    fi
    echo "FLASH OK $node: $rel, up ${up}s, $bss BSS, uplink $link dBm, carrier_changes $carr, $((SECONDS - t0)) s"
}

if [[ "$PARALLEL" == 1 && ${#NODES[@]} -gt 1 ]]; then
    pids=()
    for n in "${NODES[@]}"; do flash_one "$n" & pids+=($!); done
    rc=0
    for p in "${pids[@]}"; do wait "$p" || rc=1; done
    exit "$rc"
fi
for n in "${NODES[@]}"; do flash_one "$n" || exit 1; done
