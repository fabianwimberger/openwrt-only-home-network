#!/usr/bin/env bash
# Reboot every node at once, wait until all answer again, let the mesh settle, then check it.
#   reboot-all.sh [--settle 300] [--dry-run]
# Verdict: REBOOT OK / REBOOT NOT OK with what is missing (no ssh, no uplink, wired link flapped).
set -euo pipefail
# shellcheck source=tools/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTLE=300 DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --settle) SETTLE="$2"; shift ;;
        -n|--dry-run) DRY=1 ;;
        -h|--help) sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
    shift
done

mapfile -t NODES < <(nodes_present)
[[ ${#NODES[@]} -gt 0 ]] || die "no node profiles found"

boot_id() { rsh "$1" <<<'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true; }
declare -A BOOT
for n in "${NODES[@]}"; do
    BOOT[$n]="$(boot_id "$n")"
    [[ -n "${BOOT[$n]}" ]] || die "$n is not reachable over ssh"
done
if [[ "$DRY" == 1 ]]; then
    echo "DRY RUN: would reboot ${NODES[*]} together, wait for ssh and a new boot id, settle ${SETTLE}s, check"
    exit 0
fi

t0=$SECONDS
for n in "${NODES[@]}"; do
    # Detached so the dropped connection does not hang the call.
    rssh "$n" 'nohup sh -c "sleep 2; reboot" >/dev/null 2>&1 &' || true
done
sleep 20

pids=()
for n in "${NODES[@]}"; do
    (
        deadline=$((SECONDS + 420))
        until b="$(boot_id "$n")"; [[ -n "$b" && "$b" != "${BOOT[$n]}" ]]; do
            [[ $SECONDS -lt $deadline ]] || exit 1
            sleep 4
        done
    ) &
    pids+=($!)
done
missing=()
for i in "${!NODES[@]}"; do
    wait "${pids[$i]}" || missing+=("${NODES[$i]} (no ssh)")
done
back=$((SECONDS - t0))
sleep "$SETTLE"

bad=("${missing[@]}")
line=""
for n in "${NODES[@]}"; do
    [[ " ${missing[*]} " == *" $n (no ssh) "* ]] && continue
    read -r _ _ bss link carr < <(node_status "$n") || { bad+=("$n (status)"); continue; }
    line+="$n bss=$bss link=$link carr=$carr | "
    [[ "$(node_tier "$n")" == wireless-repeater && "$link" == none ]] && bad+=("$n uplink down")
    [[ "$(node_tier "$n")" == wired-ap && "$carr" != - && "$carr" -gt 3 ]] && bad+=("$n wired carrier_changes $carr")
    [[ "$bss" -ge 1 ]] || bad+=("$n no BSS up")
done
if [[ ${#bad[@]} -eq 0 ]]; then
    echo "REBOOT OK ${#NODES[@]}/${#NODES[@]} nodes back after ${back}s, settled ${SETTLE}s  [${line% | }]"
else
    echo "REBOOT NOT OK  $(IFS=';'; echo "${bad[*]}")  [${line% | }]"
    exit 1
fi
