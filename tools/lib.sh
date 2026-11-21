#!/usr/bin/env bash
# Shared helpers for the tools in this directory. Source it, do not run it.
# Node addresses come from the untracked profiles in wired-ap/profiles and
# wireless-repeater/profiles, so no real IP lives in the repository.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Flash and reboot order: leaf repeaters first, the wired APs last.
NODE_ORDER=(garden heatpump door ap-upper ap-main)
NAMES_FILE="${OPENWRT_NAMES:-$HOME/.config/openwrt-bench/names}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new)

die() { echo "Error: $*" >&2; exit 1; }

# node_tier <node> -> wired-ap | wireless-repeater
node_tier() {
    local t
    for t in wired-ap wireless-repeater; do
        [[ -f "$ROOT/$t/profiles/$1.conf" ]] && { echo "$t"; return; }
    done
    return 1
}

# node_var <node> <VAR> -> value from common.conf + the node's profile
node_var() {
    local tier
    tier="$(node_tier "$1")" || die "no profile named '$1' (looked in wired-ap/profiles and wireless-repeater/profiles)"
    (
        # shellcheck source=/dev/null
        source "$ROOT/$tier/profiles/common.conf"
        # shellcheck source=/dev/null
        source "$ROOT/$tier/profiles/$1.conf"
        printf '%s' "${!2:-}"
    )
}

node_ip() { node_var "$1" DEVICE_IP; }

# nodes_present: the nodes of NODE_ORDER that have a profile here
nodes_present() {
    local n
    for n in "${NODE_ORDER[@]}"; do node_tier "$n" >/dev/null 2>&1 && echo "$n"; done
}

# rsh <node>: run the script on stdin on the node (the images ship no base64)
rsh() { ssh "${SSH_OPTS[@]}" "root@$(node_ip "$1")" sh -s; }
rssh() { local n="$1"; shift; ssh "${SSH_OPTS[@]}" "root@$(node_ip "$n")" "$@"; }

# firmware_for <node> -> sysupgrade image in the tier's output dir
firmware_for() {
    local tier
    tier="$(node_tier "$1")" || die "no profile named '$1'"
    (
        # shellcheck source=/dev/null
        source "$ROOT/$tier/profiles/common.conf"
        # shellcheck source=/dev/null
        source "$ROOT/$tier/profiles/$1.conf"
        # Nightly images carry no version in their file name.
        v="${OPENWRT_VERSION}-"
        [[ "$OPENWRT_VERSION" == "main" ]] && v=""
        find "$ROOT/$tier/output/$1" -name "openwrt-${v}${OPENWRT_TARGET//\//-}-*-sysupgrade.bin" -type f | sort | head -1
    )
}

# wait_ssh <node> <seconds>: poll until key-based ssh answers
wait_ssh() {
    local ip deadline
    ip="$(node_ip "$1")"
    deadline=$((SECONDS + $2))
    until ssh "${SSH_OPTS[@]}" "root@$ip" true 2>/dev/null; do
        [[ $SECONDS -lt $deadline ]] || return 1
        sleep 3
    done
}

# node_status <node>: "uptime_s release ap_bss uplink_dbm|none carrier_changes"
node_status() {
    rsh "$1" <<'EOF'
up=$(cut -d. -f1 /proc/uptime)
rel=$(. /etc/openwrt_release; echo "$DISTRIB_RELEASE")
bss=$(iw dev | grep -c 'type AP$')
link=none
for i in $(iw dev | awk '/Interface/{i=$2} /type managed/{print i}'); do
    s=$(iw dev "$i" link | awk '/signal:/{print $2}')
    [ -n "$s" ] && link=$s
done
echo "$up $rel $bss $link $(cat /sys/class/net/eth0/carrier_changes 2>/dev/null || echo -)"
EOF
}

# name_to_mac <mac|name>: names come from "mac name" lines in $NAMES_FILE (untracked)
name_to_mac() {
    local q="${1,,}"
    if [[ "$q" =~ ^[0-9a-f:]{6,17}$ ]]; then echo "$q"; return; fi
    [[ -f "$NAMES_FILE" ]] || die "'$1' is not a MAC and $NAMES_FILE does not exist"
    awk -v q="$q" '$1 !~ /^#/ && index(tolower($0), q) {print tolower($1); exit}' "$NAMES_FILE" | grep . ||
        die "no client named '$1' in $NAMES_FILE"
}
