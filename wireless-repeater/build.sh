#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

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
COMMON_FILE="$PROFILES_DIR/common.conf"

[[ ! -f "$COMMON_FILE" ]] && echo "Error: common.conf not found (copy common.conf.example)" && exit 1
[[ ! -f "$PROFILE_FILE" ]] && echo "Error: profile '$PROFILE_NAME' not found" && exit 1

# shellcheck source=/dev/null
source "$COMMON_FILE"
# shellcheck source=/dev/null
source "$PROFILE_FILE"

echo "=== Building OpenWrt $OPENWRT_VERSION for $OPENWRT_PROFILE ==="
echo "    Profile: $PROFILE_NAME"
echo "    Device IP: $DEVICE_IP"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/files/etc/uci-defaults"

if [[ -d "$SCRIPT_DIR/files" ]]; then
    cp -a "$SCRIPT_DIR/files/"* "$TMPDIR/files/" 2>/dev/null || true
fi

# Main roaming SSID block (WPA2-Personal + 802.11r FT-PSK)
AP_BLOCK=""
if [[ "${AP_ENABLED:-0}" == "1" ]]; then
    AP_BLOCK="uci set wireless.default_ap=wifi-iface
uci set wireless.default_ap.device='${AP_DEVICE}'
uci set wireless.default_ap.network='lan'
uci set wireless.default_ap.mode='ap'
uci set wireless.default_ap.ssid='${AP_SSID}'
uci set wireless.default_ap.encryption='psk2'
uci set wireless.default_ap.wpa_pairwise='CCMP'
uci set wireless.default_ap.key='${AP_KEY}'
uci set wireless.default_ap.ieee80211k='1'
uci set wireless.default_ap.ieee80211v='1'
uci set wireless.default_ap.bss_transition='1'
uci set wireless.default_ap.ieee80211r='${AP_FT_ENABLED:-1}'
uci set wireless.default_ap.ft_over_ds='0'
uci set wireless.default_ap.ft_psk_generate_local='1'
uci set wireless.default_ap.pmk_r1_push='1'
uci set wireless.default_ap.mobility_domain='${MOBILITY_DOMAIN}'"
fi

# IoT SSID block (no FT, PMF on)
AP_IOT_BLOCK=""
if [[ "${AP_IOT_ENABLED:-0}" == "1" ]]; then
    AP_IOT_BLOCK="uci set wireless.iot_ap=wifi-iface
uci set wireless.iot_ap.device='${AP_IOT_DEVICE}'
uci set wireless.iot_ap.network='lan'
uci set wireless.iot_ap.mode='ap'
uci set wireless.iot_ap.ssid='${AP_IOT_SSID}'
uci set wireless.iot_ap.encryption='psk2'
uci set wireless.iot_ap.wpa_pairwise='CCMP'
uci set wireless.iot_ap.key='${AP_IOT_KEY}'
uci set wireless.iot_ap.ieee80211w='1'"
fi

# Downstream WDS-AP block — daisy-chain another repeater through this one.
# Falls back to the common BACKHAUL_KEY so a downstream STA using the shared
# common.conf credentials can still associate.
BACKHAUL_AP_BLOCK=""
if [[ "${BACKHAUL_AP_ENABLED:-0}" == "1" ]]; then
    BACKHAUL_AP_BLOCK="uci set wireless.bh_ap=wifi-iface
uci set wireless.bh_ap.device='${BACKHAUL_AP_DEVICE}'
uci set wireless.bh_ap.network='lan'
uci set wireless.bh_ap.mode='ap'
uci set wireless.bh_ap.ssid='${BACKHAUL_AP_SSID}'
uci set wireless.bh_ap.encryption='psk2'
uci set wireless.bh_ap.wpa_pairwise='CCMP'
uci set wireless.bh_ap.key='${BACKHAUL_AP_KEY:-$BACKHAUL_KEY}'
uci set wireless.bh_ap.hidden='1'
uci set wireless.bh_ap.wds='1'
uci set wireless.bh_ap.isolate='0'"
fi

# Site-specific SSID block (no FT, no roaming)
AP_LOCAL_BLOCK=""
if [[ "${AP_LOCAL_ENABLED:-0}" == "1" ]]; then
    AP_LOCAL_BLOCK="uci set wireless.local_ap=wifi-iface
uci set wireless.local_ap.device='${AP_LOCAL_DEVICE}'
uci set wireless.local_ap.network='lan'
uci set wireless.local_ap.mode='ap'
uci set wireless.local_ap.ssid='${AP_LOCAL_SSID}'
uci set wireless.local_ap.encryption='psk2'
uci set wireless.local_ap.wpa_pairwise='CCMP'
uci set wireless.local_ap.key='${AP_LOCAL_KEY}'"
fi

# usteer only on nodes that participate in the roaming domain.
USTEER_BLOCK="# (usteer disabled — repeater is not in the roaming domain)"
if [[ "${AP_ENABLED:-0}" == "1" ]]; then
    USTEER_BLOCK="uci set usteer.@usteer[0].network='lan'
uci set usteer.@usteer[0].local_mode='0'
uci set usteer.@usteer[0].ipv6='0'
uci set usteer.@usteer[0].syslog='1'
uci -q delete usteer.@usteer[0].ssid_list
uci add_list usteer.@usteer[0].ssid_list='${AP_SSID}'
uci set usteer.@usteer[0].assoc_steering='1'
uci set usteer.@usteer[0].roam_scan_snr='-65'
uci set usteer.@usteer[0].signal_diff_threshold='8'
uci commit usteer"
fi

# radio1 settings only if not disabled
RADIO1_LINES="# (radio1 disabled)"
if [[ "${RADIO1_DISABLED:-1}" != "1" ]]; then
    RADIO1_LINES="uci set wireless.radio1.country='${RADIO1_COUNTRY}'
uci set wireless.radio1.channel='${RADIO1_CHANNEL}'
uci set wireless.radio1.htmode='${RADIO1_HTMODE}'"
fi

# Optional SSH key block
SSH_BLOCK="# (no SSH key configured)"
if [[ -n "${SSH_PUBKEY:-}" ]]; then
    SSH_BLOCK="mkdir -p /etc/dropbear
cat > /etc/dropbear/authorized_keys <<'SSHEOF'
${SSH_PUBKEY}
SSHEOF
chmod 600 /etc/dropbear/authorized_keys"
fi

export DEVICE_IP NODE_NAME ROOT_PASSWORD
export LAN_GATEWAY LAN_DNS TIMEZONE ZONENAME
export RADIO0_DISABLED RADIO0_COUNTRY RADIO0_CHANNEL RADIO0_HTMODE
export RADIO1_DISABLED RADIO1_LINES
export BACKHAUL_DEVICE BACKHAUL_SSID BACKHAUL_KEY
export AP_BLOCK AP_IOT_BLOCK AP_LOCAL_BLOCK BACKHAUL_AP_BLOCK USTEER_BLOCK SSH_BLOCK

envsubst < "$TEMPLATES_DIR/99-device-setup.tpl" > "$TMPDIR/files/etc/uci-defaults/99-device-setup"
chmod +x "$TMPDIR/files/etc/uci-defaults/99-device-setup"

echo ""
echo "--- Rendered UCI defaults script ---"
cat "$TMPDIR/files/etc/uci-defaults/99-device-setup"
echo ""
echo "------------------------------------"

DOCKER_TAG="openwrt-imagebuilder:${OPENWRT_VERSION}-$(echo "$OPENWRT_TARGET" | tr '/' '-')"

echo "=== Building Docker image ($DOCKER_TAG) ==="
docker build \
    --build-arg "OPENWRT_VERSION=$OPENWRT_VERSION" \
    --build-arg "OPENWRT_TARGET=$OPENWRT_TARGET" \
    -t "$DOCKER_TAG" \
    "$SCRIPT_DIR"

OUTPUT_DIR="$SCRIPT_DIR/output/$PROFILE_NAME"
mkdir -p "$OUTPUT_DIR"

echo "=== Running ImageBuilder ==="
docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$TMPDIR/files:/builder/custom-files" \
    -v "$OUTPUT_DIR:/output" \
    "$DOCKER_TAG" \
    "make image PROFILE='$OPENWRT_PROFILE' PACKAGES='$PACKAGES' FILES='/builder/custom-files' BIN_DIR='/output'"

echo ""
echo "=== Build complete ==="
echo "Firmware is in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/*.bin 2>/dev/null || echo "(no .bin files found — check build output above)"
