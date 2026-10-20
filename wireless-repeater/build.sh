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

# Reject the example placeholder keys so firmware can never ship with a known
# default root or WiFi password.
for var_name in ROOT_PASSWORD BACKHAUL_KEY AP_KEY AP_IOT_KEY AP_LOCAL_KEY BACKHAUL_AP_KEY; do
    val="${!var_name:-}"
    if [[ "$val" == changeme* ]]; then
        echo "Error: $var_name is still the example placeholder '$val'. Set a real value."
        exit 1
    fi
done

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/files/etc/uci-defaults"

if [[ -d "$SCRIPT_DIR/files" ]]; then
    cp -a "$SCRIPT_DIR/files/"* "$TMPDIR/files/" 2>/dev/null || true
fi

# Main roaming SSID block (WPA2-Personal + 802.11r FT-PSK).
# AP_DEVICES lists the radios that serve it (space separated, one wifi-iface
# per radio, like the wired APs do on both bands).
AP_BLOCK=""
if [[ "${AP_ENABLED:-0}" == "1" ]]; then
    if [[ -z "${AP_DEVICES:-}" ]]; then
        echo "Error: AP_ENABLED=1 but AP_DEVICES is empty. Set the radio(s) that serve '$AP_SSID'."
        exit 1
    fi
    ap_n=0
    for ap_dev in $AP_DEVICES; do
        ap_n=$((ap_n + 1))
        ap_iface="default_ap"
        [[ "$ap_n" -gt 1 ]] && ap_iface="default_ap${ap_n}"
        AP_BLOCK+="uci set wireless.${ap_iface}=wifi-iface
uci set wireless.${ap_iface}.device=$(shell_quote "$ap_dev")
uci set wireless.${ap_iface}.network='lan'
uci set wireless.${ap_iface}.mode='ap'
uci set wireless.${ap_iface}.ssid=$(shell_quote "$AP_SSID")
uci set wireless.${ap_iface}.encryption='psk2'
uci set wireless.${ap_iface}.wpa_pairwise='CCMP'
uci set wireless.${ap_iface}.key=$(shell_quote "$AP_KEY")
uci set wireless.${ap_iface}.ieee80211w='1'
uci set wireless.${ap_iface}.dtim_period='3'
uci set wireless.${ap_iface}.wnm_sleep_mode='1'
uci set wireless.${ap_iface}.ieee80211k='1'
uci set wireless.${ap_iface}.ieee80211v='1'
uci set wireless.${ap_iface}.bss_transition='1'
uci set wireless.${ap_iface}.ieee80211r=$(shell_quote "${AP_FT_ENABLED:-1}")
uci set wireless.${ap_iface}.ft_over_ds='0'
uci set wireless.${ap_iface}.ft_psk_generate_local='1'
uci set wireless.${ap_iface}.pmk_r1_push='1'
uci set wireless.${ap_iface}.mobility_domain=$(shell_quote "$MOBILITY_DOMAIN")
"
    done
fi

# IoT SSID block (no FT, PMF on)
# AP_IOT_DEVICES is a space separated radio list, same as AP_DEVICES.
AP_IOT_BLOCK=""
if [[ "${AP_IOT_ENABLED:-0}" == "1" ]]; then
    if [[ -z "${AP_IOT_DEVICES:-}" ]]; then
        echo "Error: AP_IOT_ENABLED=1 but AP_IOT_DEVICES is empty. Set the radio(s) that serve '$AP_IOT_SSID'."
        exit 1
    fi
    iot_n=0
    for iot_dev in $AP_IOT_DEVICES; do
        iot_n=$((iot_n + 1))
        iot_iface="iot_ap"
        [[ "$iot_n" -gt 1 ]] && iot_iface="iot_ap${iot_n}"
        AP_IOT_BLOCK+="uci set wireless.${iot_iface}=wifi-iface
uci set wireless.${iot_iface}.device=$(shell_quote "$iot_dev")
uci set wireless.${iot_iface}.network='lan'
uci set wireless.${iot_iface}.mode='ap'
uci set wireless.${iot_iface}.ssid=$(shell_quote "$AP_IOT_SSID")
uci set wireless.${iot_iface}.encryption='psk2'
uci set wireless.${iot_iface}.wpa_pairwise='CCMP'
uci set wireless.${iot_iface}.key=$(shell_quote "$AP_IOT_KEY")
uci set wireless.${iot_iface}.ieee80211w='1'
"
    done
fi

# Downstream WDS-AP block — daisy-chain another repeater through this one.
# Falls back to the common BACKHAUL_KEY so a downstream STA using the shared
# common.conf credentials can still associate.
BACKHAUL_AP_BLOCK=""
if [[ "${BACKHAUL_AP_ENABLED:-0}" == "1" ]]; then
    BACKHAUL_AP_BLOCK="uci set wireless.bh_ap=wifi-iface
uci set wireless.bh_ap.device=$(shell_quote "$BACKHAUL_AP_DEVICE")
uci set wireless.bh_ap.network='lan'
uci set wireless.bh_ap.mode='ap'
uci set wireless.bh_ap.ssid=$(shell_quote "$BACKHAUL_AP_SSID")
uci set wireless.bh_ap.encryption='psk2'
uci set wireless.bh_ap.wpa_pairwise='CCMP'
uci set wireless.bh_ap.key=$(shell_quote "${BACKHAUL_AP_KEY:-$BACKHAUL_KEY}")
uci set wireless.bh_ap.hidden='1'
uci set wireless.bh_ap.wds='1'
uci set wireless.bh_ap.isolate='0'"
fi

# Site-specific SSID block (no FT, no roaming)
AP_LOCAL_BLOCK=""
if [[ "${AP_LOCAL_ENABLED:-0}" == "1" ]]; then
    AP_LOCAL_BLOCK="uci set wireless.local_ap=wifi-iface
uci set wireless.local_ap.device=$(shell_quote "$AP_LOCAL_DEVICE")
uci set wireless.local_ap.network='lan'
uci set wireless.local_ap.mode='ap'
uci set wireless.local_ap.ssid=$(shell_quote "$AP_LOCAL_SSID")
uci set wireless.local_ap.encryption='psk2'
uci set wireless.local_ap.wpa_pairwise='CCMP'
uci set wireless.local_ap.key=$(shell_quote "$AP_LOCAL_KEY")
uci set wireless.local_ap.ieee80211w='1'"
fi

# usteer only on nodes that participate in the roaming domain.
# Elsewhere the service is switched off: with its default config it would still
# broadcast node sync to the LAN once per second.
USTEER_BLOCK="/etc/init.d/usteer disable
/etc/init.d/usteer-recheck disable"
if [[ "${AP_ENABLED:-0}" == "1" ]]; then
    USTEER_BLOCK="uci set usteer.@usteer[0].network='lan'
uci set usteer.@usteer[0].local_mode='0'
uci set usteer.@usteer[0].ipv6='0'
uci set usteer.@usteer[0].syslog='1'
uci set usteer.@usteer[0].debug_level='2'
uci -q delete usteer.@usteer[0].ssid_list
uci add_list usteer.@usteer[0].ssid_list=$(shell_quote "$AP_SSID")
uci set usteer.@usteer[0].assoc_steering='0'
uci set usteer.@usteer[0].roam_scan_snr='-75'
uci set usteer.@usteer[0].signal_diff_threshold='8'
uci set usteer.@usteer[0].seen_policy_timeout='30000'
uci set usteer.@usteer[0].roam_trigger_interval='300000'
uci set usteer.@usteer[0].roam_kick_delay='30000'
uci set usteer.@usteer[0].band_steering_min_snr='-60'
uci set usteer.@usteer[0].aggressiveness='3'
uci set usteer.@usteer[0].remote_update_interval='1000'
uci commit usteer
/etc/init.d/usteer-recheck enable"
fi

# radio1 settings only if not disabled
RADIO1_LINES="# (radio1 disabled)"
if [[ "${RADIO1_DISABLED:-1}" != "1" ]]; then
    RADIO1_LINES="uci set wireless.radio1.country=$(shell_quote "$RADIO1_COUNTRY")
uci set wireless.radio1.channel=$(shell_quote "$RADIO1_CHANNEL")
uci set wireless.radio1.htmode=$(shell_quote "$RADIO1_HTMODE")"
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
RADIO0_DISABLED="$(shell_single_quote_content "$RADIO0_DISABLED")"
RADIO0_COUNTRY="$(shell_single_quote_content "$RADIO0_COUNTRY")"
RADIO0_CHANNEL="$(shell_single_quote_content "$RADIO0_CHANNEL")"
RADIO0_HTMODE="$(shell_single_quote_content "$RADIO0_HTMODE")"
RADIO1_DISABLED="$(shell_single_quote_content "$RADIO1_DISABLED")"
BACKHAUL_DEVICE="$(shell_single_quote_content "$BACKHAUL_DEVICE")"
BACKHAUL_SSID="$(shell_single_quote_content "$BACKHAUL_SSID")"
BACKHAUL_KEY="$(shell_single_quote_content "$BACKHAUL_KEY")"

export DEVICE_IP NODE_NAME ROOT_PASSWORD
export LAN_GATEWAY LAN_DNS TIMEZONE ZONENAME
export RADIO0_DISABLED RADIO0_COUNTRY RADIO0_CHANNEL RADIO0_HTMODE
export RADIO1_DISABLED RADIO1_LINES
export BACKHAUL_DEVICE BACKHAUL_SSID BACKHAUL_KEY
export AP_BLOCK AP_IOT_BLOCK AP_LOCAL_BLOCK BACKHAUL_AP_BLOCK USTEER_BLOCK SSH_BLOCK

envsubst < "$TEMPLATES_DIR/99-device-setup.tpl" > "$TMPDIR/files/etc/uci-defaults/99-device-setup"
chmod +x "$TMPDIR/files/etc/uci-defaults/99-device-setup"

DOCKER_TAG="openwrt/imagebuilder:$(echo "$OPENWRT_TARGET" | tr '/' '-')-${OPENWRT_VERSION}"

echo "=== Running ImageBuilder ==="
# A locally cached tag would otherwise be reused indefinitely.
docker pull "$DOCKER_TAG"
OUTPUT_DIR="$SCRIPT_DIR/output/$PROFILE_NAME"
mkdir -p "$OUTPUT_DIR"
docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$TMPDIR/files:/builder/custom-files" \
    -v "$OUTPUT_DIR:/output" \
    --entrypoint /bin/sh \
    "$DOCKER_TAG" \
    -c "{ [ -d ./scripts ] || ./setup.sh; } && make image PROFILE='$OPENWRT_PROFILE' PACKAGES='$PACKAGES' FILES='/builder/custom-files' BIN_DIR='/output'"

echo ""
echo "=== Build complete ==="
echo "Firmware is in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/*.bin 2>/dev/null || echo "(no .bin files found — check build output above)"
