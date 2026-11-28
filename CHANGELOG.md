# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v1.6.0] - 2026-11-28

A bench, a set of fleet tools and key-based flashing replace the sshpass flow.

### Features

- `bench/bench.sh` measures a wired link with `--quick` or `--phy`, keeps `serve`, `cmd`, `stop`, `report` and `stress` for longer runs, and ends every run with a one-line verdict; history lives in `~/.local/state/openwrt-bench/`.
- `tools/` adds `flash.sh`, `safe-wifi-change.sh` with a 240 s rollback, `reboot-all.sh`, `survey.sh`, `clients.sh` and `roamlog.sh`, plus `make flash-all` for the whole fleet in one order.
- `deploy.sh`, `upgrade-all.sh` and the tools use the key from `SSH_PUBKEY`; `sshpass` is no longer needed.
- Templates bake `log_level=1` into `hostapd` and forward to a remote syslog target when `LOG_IP` is set (`LOG_PORT`, default 514).

### Fixes

- The bench prints the previous run correctly when a quick run leaves the bidir fields empty, and flags an up or down rate more than 15 % below the 7-day mean.
- `stress` waits for its samplers and cleans them up, and AP-to-AP runs use their own iperf3 port.

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.5.0] - 2026-11-21

Wired APs can serve the IoT SSID on 5 GHz as well, like the repeaters.

### Features

- Add `AP_IOT_DEVICES` for wired APs, a space separated radio list; it defaults to `radio0`, so existing profiles build unchanged

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.4.0] - 2026-11-21

Wired APs can give each band its own hidden backhaul SSID, so every repeater only finds the AP and band it is meant to use.

### Features

- Add `BACKHAUL_24_SSID` and `BACKHAUL_5_SSID` for wired APs; both default to `BACKHAUL_SSID`, so existing profiles build unchanged

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.3.2] - 2026-10-24

Client steering only touches genuinely weak clients now, and a client that accepts a roam request gets time to move before it is deauthenticated.

### Fixes

- Gate roam scans on `roam_scan_snr -75` so clients sitting just under the old gate are left alone instead of being moved back and forth every minute
- Slow the roam path down: one attempt per client every 5 min (`roam_trigger_interval` 300000) and a 30 s kick delay (`roam_kick_delay`) so an accepting client can move before the deauthentication

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.3.1] - 2026-10-19

Builds now target OpenWrt 25.12.6, and the steering options follow the usteer package defaults instead of the earlier hand-tuned values.

### Fixes

- Return the steering options to the usteer package defaults: `aggressiveness 3`, `signal_diff_threshold 8`, `seen_policy_timeout` 30000 ms and `remote_update_interval` 1000 ms

### Dependencies

- Update wired AP and wireless repeater example profiles to OpenWrt 25.12.6

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.3.0] - 2026-10-17

Client steering is rebuilt around band steering with a signal guard plus a roam kick, repeaters can serve the roaming SSID on more than one radio, and a new service re-checks usteer's tracked BSSes after boot. Nightly images are supported.

### Features

- Add `usteer-recheck`: restarts `usteer` when it tracks fewer roaming BSSes than are up, so a radio that was not up when `usteer` started is not left unsteered
- Let a repeater serve the roaming SSID on more than one radio via `AP_DEVICES` / `AP_IOT_DEVICES`
- Support nightly OpenWrt images: match version-less sysupgrade filenames and pull the ImageBuilder container before each build

### Fixes

- Re-enable `usteer` band steering, now guarded by `band_steering_min_snr` so far-away and 2.4 GHz-only clients are left alone
- Turn on PMF, DTIM and WNM sleep mode on the roaming and IoT SSIDs
- Keep `usteer` and the re-check off on repeaters outside the roaming domain instead of running them with a default config

### Documentation

- Correct the README steering description and document the repeater radio lists and nightly builds

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.6] - 2026-09-19

Rejects example placeholder keys at build time, tightens shellcheck, and documents the tier layout.

### Fixes

- Reject every example placeholder key at build time, so a profile copied from the examples cannot be flashed with credentials still set to their placeholder values

### CI

- Run shellcheck at warning severity and assert the scripts' usage output

### Documentation

- Correct the tier layout and add a configuration reference to the README

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.5] - 2026-08-14

Client roaming no longer flaps between APs, and the unused uhttpd listener is disabled.

### Fixes

- Stop usteer assoc-steering from flapping clients between nodes — raise `signal_diff_threshold`, shorten `seen_policy_timeout`, and disable assoc-time rejection in favor of the cooldown-protected roam-kick path
- Disable the unused `uhttpd` web listener (empty docroot, no LuCI) on all node types
- Disable usteer band steering — it force-migrated well-connected 2.4 GHz clients to 5 GHz without checking the target band's signal quality, fighting the roam-kick path

### Dependencies

- Bump shellcheck from v0.10.0 to v0.11.0

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.4] - 2026-07-17

Wired AP and wireless repeater builds now target OpenWrt 25.12.5.

### Dependencies

- Update wired AP and wireless repeater example profiles to OpenWrt 25.12.5
- Bump actions/checkout from 6 to 7

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.3] - 2026-05-15

Firmware deployment now selects OpenWrt 25.12.4 sysupgrade images explicitly and keeps build logs focused on actionable output.

### Fixes

- Select sysupgrade firmware artifacts that match the configured OpenWrt version before deploying
- Sort matching firmware artifacts so deploy selection is deterministic
- Stop printing rendered device setup scripts during wired AP and wireless repeater builds
- Update wired AP and wireless repeater example profiles to OpenWrt 25.12.4

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.2] - 2026-05-09

Firmware builds now use the official OpenWrt ImageBuilder containers instead of local custom builder images.

### Fixes

- Use official `openwrt/imagebuilder` containers for wired AP and wireless repeater firmware builds
- Run ImageBuilder through an explicit shell entrypoint for reliable command execution
- Keep deploy SSH behavior isolated from local SSH configuration
- Preserve generated first-boot defaults scripts instead of deleting them during first run

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.1] - 2026-05-09

Firmware generation and deployment hardening for both the wired AP and wireless repeater tiers.

### Fixes

- Quote generated UCI shell values safely when profiles contain apostrophes or other shell-sensitive characters
- Verify downloaded OpenWrt ImageBuilder archives against upstream SHA256 files
- Use SSH host-key `accept-new` instead of disabling host-key checks during deploys
- Avoid passing deploy passwords as command arguments
- Apply the safer deploy flow to single-profile deploys and parallel upgrades
- Fail parallel upgrades clearly when no sysupgrade image exists
- Remove the warning icon from the README security notice

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.2.0] - 2026-05-09

Security hardening and validation improvements.

### Fixes
- MOBILITY_DOMAIN now required in profiles (build aborts if missing)
- changeme/changeme-* rejected for ROOT_PASSWORD and BACKHAUL_KEY
- Template scripts self-shred after first boot (rm -f $0)
- source paths validated before sourcing in upgrade-all.sh
- scp/ssh timeout increased from 30 s to 120 s for multi-MB firmware
- docker build now passes --pull for fresh base images
- FIRMWARE emptiness check instead of find | head -1

### Documentation & Links
- https://github.com/fabianwimberger/openwrt-only-home-network

## [v1.1.0] - 2026-05-08

Adds an optional safeguard for repeater configurations and bumps the OpenWrt example version.

### Features

- Optional downstream WDS-AP block on repeaters

### Dependencies

- Bump OpenWrt example version to 25.12.3

### Documentation & Links

- [README](https://github.com/fabianwimberger/openwrt-only-home-network#readme)

## [v1.0.0] - 2026-05-02

**The first official release of a buildable, profile-driven blueprint for a whole-home WiFi network on OpenWrt — no vendor cloud, no proprietary mesh.**

Wired access points host the main roaming SSID with 802.11r FT-PSK; wireless repeaters extend coverage over a hidden WDS (4-address) backhaul. Just flash and go.

---

### Features

- **WDS / 4-address backhaul** — fully L2-transparent, no `batman-adv`, no `relayd`
- **802.11r FT-PSK** — fast transition between APs that share the mobility domain
- **`usteer`** — assoc-time client steering on the roaming SSID only
- **Multi-SSID** — separate IoT SSID without FT (some IoT chips mishandle it)
- **Anchor backhaul** — marginal-signal repeater can pin to a different AP
- **Profile-driven** — one `.conf` per node, baked into firmware via UCI defaults
- **Parallel build+deploy** — `upgrade-all.sh` rolls every node concurrently
- **No firewall, no DHCP, no PPP** — APs are dumb bridges; upstream router does L3

---

### Quick Start

```bash
cd wired-ap
cp profiles/common.conf.example profiles/common.conf
cp profiles/ap-main.conf.example profiles/ap-main.conf

# Edit profiles/*.conf with your SSIDs, keys, IPs, country code

# Build firmware for one node
./build.sh ap-main

# Or roll the whole house in parallel
./upgrade-all.sh
```

---

### Tested Devices

- **Wired AP:** Zyxel NWA50AX Pro (`zyxel_nwa50ax-pro`, `mediatek/filogic`)
- **Wireless repeater:** Cudy RE3000 v1 (`cudy_re3000-v1`, `mediatek/filogic`)

---

### Requirements

- Docker (for ImageBuilder container)
- `sshpass` (for `deploy.sh` / `upgrade-all.sh`)
- `envsubst` (usually shipped with `gettext`)

---

### License

[MIT](LICENSE)
