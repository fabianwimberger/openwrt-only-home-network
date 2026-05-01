#!/bin/sh
# UCI defaults — rendered from templates/99-device-setup.tpl
# Device: ${DEVICE_IP} (${NODE_NAME})

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

# === br-lan = wired uplink + (auto-attached) wifi-iface members of network='lan' ===
uci -q rename network.@device[0]='br_lan'
uci set network.br_lan.name='br-lan'
uci set network.br_lan.type='bridge'
uci -q delete network.br_lan.ports
uci add_list network.br_lan.ports='eth0'

# === RADIOS ===
uci -q delete wireless.radio0.txpower
uci set wireless.radio0.country='${RADIO0_COUNTRY}'
uci set wireless.radio0.channel='${RADIO0_CHANNEL}'
uci set wireless.radio0.htmode='${RADIO0_HTMODE}'
uci set wireless.radio0.disabled='0'

uci -q delete wireless.radio1.txpower
uci set wireless.radio1.country='${RADIO1_COUNTRY}'
uci set wireless.radio1.channel='${RADIO1_CHANNEL}'
uci set wireless.radio1.htmode='${RADIO1_HTMODE}'
uci set wireless.radio1.disabled='0'

# === Main roaming SSID (WPA2-Personal + 802.11r FT-PSK) on 2.4 GHz ===
uci set wireless.default_radio0=wifi-iface
uci set wireless.default_radio0.device='radio0'
uci set wireless.default_radio0.mode='ap'
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.ssid='${AP_SSID}'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.wpa_pairwise='CCMP'
uci set wireless.default_radio0.key='${AP_KEY}'
uci set wireless.default_radio0.ieee80211k='1'
uci set wireless.default_radio0.ieee80211v='1'
uci set wireless.default_radio0.bss_transition='1'
uci set wireless.default_radio0.ieee80211r='${AP_FT_ENABLED}'
uci set wireless.default_radio0.ft_over_ds='0'
uci set wireless.default_radio0.ft_psk_generate_local='1'
uci set wireless.default_radio0.pmk_r1_push='1'
uci set wireless.default_radio0.mobility_domain='${MOBILITY_DOMAIN}'

# === Main roaming SSID on 5 GHz ===
uci set wireless.default_radio1=wifi-iface
uci set wireless.default_radio1.device='radio1'
uci set wireless.default_radio1.mode='ap'
uci set wireless.default_radio1.network='lan'
uci set wireless.default_radio1.ssid='${AP_SSID}'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.wpa_pairwise='CCMP'
uci set wireless.default_radio1.key='${AP_KEY}'
uci set wireless.default_radio1.ieee80211k='1'
uci set wireless.default_radio1.ieee80211v='1'
uci set wireless.default_radio1.bss_transition='1'
uci set wireless.default_radio1.ieee80211r='${AP_FT_ENABLED}'
uci set wireless.default_radio1.ft_over_ds='0'
uci set wireless.default_radio1.ft_psk_generate_local='1'
uci set wireless.default_radio1.pmk_r1_push='1'
uci set wireless.default_radio1.mobility_domain='${MOBILITY_DOMAIN}'

# === Optional IoT SSID (WPA2 + PMF, no FT) on 2.4 GHz ===
${AP_IOT_BLOCK}

# === Hidden WDS-AP backhaul (4-addr) — per-radio toggle ===
${BACKHAUL_24_BLOCK}
${BACKHAUL_5_BLOCK}

# === usteer — assoc-time steering on the roaming SSID only ===
uci set usteer.@usteer[0].network='lan'
uci set usteer.@usteer[0].local_mode='0'
uci set usteer.@usteer[0].ipv6='0'
uci set usteer.@usteer[0].syslog='1'
uci -q delete usteer.@usteer[0].ssid_list
uci add_list usteer.@usteer[0].ssid_list='${AP_SSID}'
uci set usteer.@usteer[0].assoc_steering='1'
uci set usteer.@usteer[0].roam_scan_snr='-65'
uci set usteer.@usteer[0].signal_diff_threshold='8'
uci commit usteer

# === Prometheus exporter — bind to lan, not loopback ===
uci set prometheus-node-exporter-lua.main.listen_interface='lan'
uci commit prometheus-node-exporter-lua

# === Root password (+ optional SSH key) ===
(echo '${ROOT_PASSWORD}'; echo '${ROOT_PASSWORD}') | passwd root
${SSH_BLOCK}

uci commit network
uci commit wireless

exit 0
