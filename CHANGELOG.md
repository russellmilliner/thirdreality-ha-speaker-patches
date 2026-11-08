# Changelog

All notable changes to the **ThirdReality Home Assistant Speaker (`3RAB01090D`) Firmware Hardening Patches** are documented in this file.

## [`1.02.04+milliner2`] - 2026-11-08

### Fixed
- **`/etc/init.d/S39wifi` SDIO Power-Down Race (`multi_wifi_load_driver`)**:
  - Prevented `S39wifi stop` and `S39wifi restart` from invoking `/usr/bin/multi_wifi_load_driver station 0` (which unloads `dhd.ko` and powers down the SDIO slot via `ioctl 0x6d04`).
  - Guarded `/usr/bin/multi_wifi_load_driver station 1` behind `[ ! -d /sys/class/net/wlan0 ]` so `S39wifi restart` reloads the Broadcom `BCM43438` firmware in-place via `ifconfig wlan0 down` -> `ifconfig wlan0 up` (`dhd_stop` / `dhd_open`) without hitting the 10ms SDIO enumeration race (`usleep(10000)` vs 240ms `meson-gx-mmc` enumeration).
  - Preserved existing `wlan0` IPv4 address if `S39wifi start` is called while an IPv4 lease is already assigned.
- **`/usr/share/thirdreality/script/netmonitor` (`v2`)**:
  - Fixed inverted `ssidCheck()` false-positive bug (`! grep -q "Not connected"` returning `0` when `wlan0` is missing/down) by requiring `[ -d /sys/class/net/wlan0 ] && iw dev wlan0 link 2>/dev/null | grep -q "^Connected to "`.
  - Changed intermediate Wi-Fi recovery steps (`15s`, `30s`, `45s`) to run `wpa_cli -i wlan0 scan && sleep 2 && wpa_cli -i wlan0 reassociate` and increased the full `S39wifi restart` threshold to `60s` (`wifi_fail_count -ge 20`) to accommodate 42.5-second 4-way handshake + scan cycles.
  - Added `maybe_rate_limited_reboot()` (rate-limited to at most once per 30 minutes via `/data/conf/.last_wifi_reboot`) if `/sys/class/net/wlan0` disappears or 3 consecutive `reset_wifi_stack` attempts fail.

### Added
- Automated deployment, diagnostic verification, and rollback scripts in `scripts/`:
  - `scripts/apply-speaker-patches.sh` (`--wait` and `--dry-run` support)
  - `scripts/check-speaker-status.sh`
  - `scripts/revert-speaker-patches.sh`
- Complete stock `1.02.04` reference files (`stock-1.02.04/`) and unified diff (`patches/thirdreality-speaker-1.02.04-hardening.patch`).

---

## [`1.02.04+milliner1`] - 2026-11-07

### Fixed
- **BCM43438 Wi-Fi Power Save Hook (`/usr/share/udhcpc/default.script.d/disable-wifi-powersave`)**:
  - Set executable permissions (`0755`) on `disable-wifi-powersave` (shipped as `0644` in stock firmware, causing `udhcpc` `default.script` to skip it on every DHCP bound/renew).
- **DHCP Client Stability (`/etc/init.d/S41dhcpcd`)**:
  - Fixed `2&>1` redirection syntax bug that created a stray `/1` file in `/data/overlay/upper/1`.
  - Created `/var/lib/ntp` directory for `ntpd` drift file persistence.
  - Relaxed `udhcpc` timeout parameters from `-A 1 -T 1` (3s total) to `-A 5 -T 3 -t 5 -b`.
- **D-Bus Machine-ID Persistence & `/var/pulse` UBIFS Leak (`/etc/init.d/S30dbus`, `/etc/init.d/S99ha-speaker`)**:
  - Persisted `/etc/machine-id` across reboots and added automatic startup pruning of orphaned `/var/pulse/<machine-id>-*` files.
- **Voice Assistant Boot Race & Port `:6053` Watchdog (`/etc/init.d/S99ha-speaker`)**:
  - Prevented `S99ha-speaker` from leaving `/tmp/ha_disable_voice` locked when `S49ntp` (`ntpdate.sh`) completes before `S99ha-speaker` starts.
  - Added a 30-second TCP `:6053` listener watchdog (`is_voice_port_listening`) to automatically restart `linux-voice-assistant-cpp` if the ESPHome API socket hangs.
- **Network Monitor Local Gateway Fallback (`/usr/share/thirdreality/script/netmonitor`)**:
  - Added `gatewayCheck()` fallback so ISP outages do not mark the speaker disconnected from the local Home Assistant LAN.
