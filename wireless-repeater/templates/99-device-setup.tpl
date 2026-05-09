#!/bin/sh
# UCI defaults — rendered from templates/99-device-setup.tpl
# Device: ${DEVICE_IP} (${NODE_NAME})
#
# Architecture: WDS / 4-address bridging (no batman, no relayd).
# Repeater is a 4-addr STA on the backhaul SSID + optional 3-addr AP(s) for
# clients, all sharing br-lan with eth0. L2-transparent to the upstream subnet.

# Clear imagebuilder defaults before re-creating with our config.
uci -q delete wireless.default_radio0
uci -q delete wireless.default_radio1

# === SYSTEM ===
uci set system.@system[0].hostname='${NODE_NAME}'
uci set system.@system[0].timezone='${TIMEZONE}'
uci set system.@system[0].zonename='${ZONENAME}'
uci commit system

# === LAN (static, upstream router as gateway/DNS) ===
uci -q delete network.lan.gateway
uci -q delete network.lan.dns
uci set network.lan.proto='static'
uci set network.lan.ipaddr='${DEVICE_IP}'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='${LAN_GATEWAY}'
uci add_list network.lan.dns='${LAN_DNS}'

# === br-lan = wired LAN port + (auto-attached) wifi-iface members of network='lan'
# This device's single LAN socket is exposed as eth0.
uci -q rename network.@device[0]='br_lan'
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci -q delete network.br_lan.ports
uci add_list network.br_lan.ports='eth0'

# === RADIOS ===
uci -q delete wireless.radio0.txpower
uci -q delete wireless.radio1.txpower
uci set wireless.radio0.disabled='${RADIO0_DISABLED}'
uci set wireless.radio0.country='${RADIO0_COUNTRY}'
uci set wireless.radio0.channel='${RADIO0_CHANNEL}'
uci set wireless.radio0.htmode='${RADIO0_HTMODE}'

uci set wireless.radio1.disabled='${RADIO1_DISABLED}'
${RADIO1_LINES}

# === WDS 4-addr STA (backhaul to a wired AP) ===
uci set wireless.wds_sta=wifi-iface
uci set wireless.wds_sta.device='${BACKHAUL_DEVICE}'
uci set wireless.wds_sta.network='lan'
uci set wireless.wds_sta.mode='sta'
uci set wireless.wds_sta.ssid='${BACKHAUL_SSID}'
uci set wireless.wds_sta.encryption='psk2'
uci set wireless.wds_sta.key='${BACKHAUL_KEY}'
uci set wireless.wds_sta.wds='1'

# === Hidden downstream WDS-AP — lets another repeater backhaul through us ===
${BACKHAUL_AP_BLOCK}

# === Main roaming SSID (WPA2-Personal + 802.11r FT-PSK) — optional ===
${AP_BLOCK}

# === IoT SSID (WPA2 + PMF, no FT) — optional ===
${AP_IOT_BLOCK}

# === Site-specific SSID (no FT) — optional ===
${AP_LOCAL_BLOCK}

# === usteer — only on nodes that broadcast the roaming SSID ===
${USTEER_BLOCK}

# === Prometheus exporter — bind to lan, not loopback ===
uci set prometheus-node-exporter-lua.main.listen_interface='lan'
uci commit prometheus-node-exporter-lua

# === Root password (+ optional SSH key) ===
(echo '${ROOT_PASSWORD}'; echo '${ROOT_PASSWORD}') | passwd root
${SSH_BLOCK}

uci commit network
uci commit wireless

rm -f "$0"
exit 0
