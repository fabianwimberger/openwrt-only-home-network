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

shell_single_quote_content() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

shell_quote() {
    printf "'%s'" "$(shell_single_quote_content "$1")"
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
if [[ -z "${MOBILITY_DOMAIN:-}" ]]; then
    echo "Error: MOBILITY_DOMAIN is required. Set a unique 4-hex value in your profile config."
    exit 1
fi

for var_name in ROOT_PASSWORD BACKHAUL_KEY; do
    val="${!var_name:-}"
    if [[ "$val" == "changeme" || "$val" == "changeme-backhaul" || "$val" == "changeme-main" || "$val" == "changeme-iot" ]]; then
        echo "Error: $var_name is set to a default placeholder '$val'. Set a real value."
        exit 1
    fi
done

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/files/etc/uci-defaults"

if [[ -d "$SCRIPT_DIR/files" ]]; then
    cp -a "$SCRIPT_DIR/files/"* "$TMPDIR/files/" 2>/dev/null || true
fi

# Optional IoT SSID block (no FT, PMF on, 2.4 GHz only)
AP_IOT_BLOCK=""
if [[ "${AP_IOT_ENABLED:-0}" == "1" ]]; then
    AP_IOT_BLOCK="uci set wireless.iot=wifi-iface
uci set wireless.iot.device='radio0'
uci set wireless.iot.mode='ap'
uci set wireless.iot.network='lan'
uci set wireless.iot.ssid=$(shell_quote "$AP_IOT_SSID")
uci set wireless.iot.encryption='psk2'
uci set wireless.iot.wpa_pairwise='CCMP'
uci set wireless.iot.key=$(shell_quote "$AP_IOT_KEY")
uci set wireless.iot.ieee80211w='1'"
fi

# Hidden WDS-AP backhaul on 2.4 GHz
BACKHAUL_24_BLOCK=""
if [[ "${BACKHAUL_AP_24_ENABLED:-0}" == "1" ]]; then
    BACKHAUL_24_BLOCK="uci set wireless.bh0=wifi-iface
uci set wireless.bh0.device='radio0'
uci set wireless.bh0.mode='ap'
uci set wireless.bh0.network='lan'
uci set wireless.bh0.ssid=$(shell_quote "$BACKHAUL_SSID")
uci set wireless.bh0.encryption='psk2'
uci set wireless.bh0.key=$(shell_quote "$BACKHAUL_KEY")
uci set wireless.bh0.hidden='1'
uci set wireless.bh0.wds='1'
uci set wireless.bh0.isolate='0'"
fi

# Hidden WDS-AP backhaul on 5 GHz
BACKHAUL_5_BLOCK=""
if [[ "${BACKHAUL_AP_5_ENABLED:-0}" == "1" ]]; then
    BACKHAUL_5_BLOCK="uci set wireless.bh1=wifi-iface
uci set wireless.bh1.device='radio1'
uci set wireless.bh1.mode='ap'
uci set wireless.bh1.network='lan'
uci set wireless.bh1.ssid=$(shell_quote "$BACKHAUL_SSID")
uci set wireless.bh1.encryption='psk2'
uci set wireless.bh1.key=$(shell_quote "$BACKHAUL_KEY")
uci set wireless.bh1.hidden='1'
uci set wireless.bh1.wds='1'
uci set wireless.bh1.isolate='0'"
fi

# Optional SSH key block
SSH_BLOCK="# (no SSH key configured)"
if [[ -n "${SSH_PUBKEY:-}" ]]; then
    SSH_BLOCK="mkdir -p /etc/dropbear
printf '%s\n' $(shell_quote "$SSH_PUBKEY") > /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys"
fi

DEVICE_IP="$(shell_single_quote_content "$DEVICE_IP")"
NODE_NAME="$(shell_single_quote_content "$NODE_NAME")"
ROOT_PASSWORD="$(shell_single_quote_content "$ROOT_PASSWORD")"
LAN_GATEWAY="$(shell_single_quote_content "$LAN_GATEWAY")"
LAN_DNS="$(shell_single_quote_content "$LAN_DNS")"
TIMEZONE="$(shell_single_quote_content "$TIMEZONE")"
ZONENAME="$(shell_single_quote_content "$ZONENAME")"
RADIO0_COUNTRY="$(shell_single_quote_content "$RADIO0_COUNTRY")"
RADIO0_CHANNEL="$(shell_single_quote_content "$RADIO0_CHANNEL")"
RADIO0_HTMODE="$(shell_single_quote_content "$RADIO0_HTMODE")"
RADIO1_COUNTRY="$(shell_single_quote_content "$RADIO1_COUNTRY")"
RADIO1_CHANNEL="$(shell_single_quote_content "$RADIO1_CHANNEL")"
RADIO1_HTMODE="$(shell_single_quote_content "$RADIO1_HTMODE")"
AP_SSID="$(shell_single_quote_content "$AP_SSID")"
AP_KEY="$(shell_single_quote_content "$AP_KEY")"
AP_FT_ENABLED="$(shell_single_quote_content "$AP_FT_ENABLED")"
MOBILITY_DOMAIN="$(shell_single_quote_content "$MOBILITY_DOMAIN")"

export DEVICE_IP NODE_NAME ROOT_PASSWORD
export LAN_GATEWAY LAN_DNS TIMEZONE ZONENAME
export RADIO0_COUNTRY RADIO0_CHANNEL RADIO0_HTMODE
export RADIO1_COUNTRY RADIO1_CHANNEL RADIO1_HTMODE
export AP_SSID AP_KEY AP_FT_ENABLED MOBILITY_DOMAIN
export AP_IOT_BLOCK BACKHAUL_24_BLOCK BACKHAUL_5_BLOCK SSH_BLOCK

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
    --pull \
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
