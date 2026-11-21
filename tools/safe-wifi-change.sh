#!/usr/bin/env bash
# Apply a wireless/network change on a node with a rollback armed: the old /etc/config files
# come back after 240 s unless the change is confirmed.
#   safe-wifi-change.sh [--secs N] [--auto] <node> -c '<shell commands>'    (or the script on stdin)
#   safe-wifi-change.sh confirm <node>      keep the change, disarm the rollback
#   safe-wifi-change.sh status <node>       is a rollback armed, and for how long
# --auto confirms by itself when the node answers over SSH afterwards and (repeaters) the uplink is back.
# The rollback runs on the node and lives in RAM, so it also covers a lost uplink; a reboot
# before it fires keeps the new config.
set -euo pipefail
# shellcheck source=tools/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SECS=240 AUTO=0 CMD="" NODE="" ACTION=apply
while [[ $# -gt 0 ]]; do
    case "$1" in
        --secs) SECS="$2"; shift ;;
        --auto) AUTO=1 ;;
        -c) CMD="$2"; shift ;;
        confirm|status) ACTION="$1" ;;
        -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) NODE="$1" ;;
    esac
    shift
done
[[ -n "$NODE" ]] || die "usage: safe-wifi-change.sh [--secs N] [--auto] <node> -c '<commands>' | confirm <node> | status <node>"
node_tier "$NODE" >/dev/null || die "no profile named '$NODE'"

case "$ACTION" in
    confirm)
        rsh "$NODE" <<'EOF'
if [ -f /tmp/safe-wifi.armed ]; then rm -f /tmp/safe-wifi.armed; echo "CONFIRMED: rollback disarmed, change kept"; else echo "NOTHING ARMED (already rolled back or confirmed)"; fi
EOF
        exit 0 ;;
    status)
        rsh "$NODE" <<'EOF'
if [ -f /tmp/safe-wifi.armed ]; then left=$(( $(cat /tmp/safe-wifi.armed) - $(date +%s) )); echo "ARMED: rollback in ${left}s"; else echo "NOT ARMED"; fi
EOF
        exit 0 ;;
esac

if [[ -z "$CMD" ]]; then
    [[ ! -t 0 ]] || die "give the change with -c '<commands>' or on stdin"
    CMD="$(cat)"
fi
[[ -n "$CMD" ]] || die "empty change"

# Arm first, then apply: if the apply cuts the connection the rollback is already counting down.
out="$({
    printf 'SECS=%s\n' "$SECS"
    cat <<'EOF'
if [ -f /tmp/safe-wifi.armed ]; then echo "BUSY: a rollback is already armed here (confirm it or wait)"; exit 3; fi
B=/tmp/safe-wifi.bak
rm -rf "$B"; mkdir "$B"
for f in wireless network usteer system dhcp; do [ -f /etc/config/$f ] && cp /etc/config/$f "$B/$f"; done
echo $(( $(date +%s) + SECS )) > /tmp/safe-wifi.armed
nohup sh -c "
    sleep $SECS
    if [ -f /tmp/safe-wifi.armed ]; then
        rm -f /tmp/safe-wifi.armed
        for f in $B/*; do cp \$f /etc/config/\$(basename \$f); done
        /etc/init.d/network reload; wifi reload; /etc/init.d/usteer restart
        logger -t safe-wifi 'rolled back to the config from before the change'
    fi" >/dev/null 2>&1 </dev/null &
echo ARMED
EOF
} | rsh "$NODE")" || true
[[ "$out" == *ARMED* ]] || { echo "NOT APPLIED $NODE: ${out:-no answer over ssh}"; exit 1; }

# The change itself. A dropped connection is expected when the uplink moves.
{
    printf '%s\n' "$CMD"
    echo "uci commit wireless; uci commit network; uci commit usteer 2>/dev/null"
    echo "wifi reload"
} | rsh "$NODE" >/dev/null 2>&1 || true

sleep 8
if ! wait_ssh "$NODE" 90; then
    echo "UNREACHABLE $NODE: no ssh after the change, the node rolls itself back within ${SECS}s of arming"
    exit 1
fi
read -r _ _ bss link _ < <(node_status "$NODE")
tier="$(node_tier "$NODE")"
ok=1
[[ "$bss" -ge 1 ]] || ok=0
if [[ "$tier" == wireless-repeater ]]; then
    for _ in 1 2 3 4 5 6; do
        [[ "$link" != none ]] && break
        sleep 5
        read -r _ _ bss link _ < <(node_status "$NODE")
    done
    [[ "$link" != none ]] || ok=0
fi
if [[ "$ok" == 1 && "$AUTO" == 1 ]]; then
    "$0" confirm "$NODE" >/dev/null
    echo "CHANGE OK $NODE: kept ($bss BSS, uplink $link dBm), rollback disarmed"
elif [[ "$ok" == 1 ]]; then
    echo "APPLIED $NODE: $bss BSS, uplink $link dBm; rollback in <= ${SECS}s unless: tools/safe-wifi-change.sh confirm $NODE"
else
    echo "CHANGE NOT OK $NODE: $bss BSS, uplink $link; the rollback restores the old config within ${SECS}s"
    exit 1
fi
