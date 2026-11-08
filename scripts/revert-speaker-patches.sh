#!/usr/bin/env bash
# ==============================================================================
# revert-speaker-patches.sh
#
# Reverts a ThirdReality Home Assistant Speaker (3RAB01090D) back to stock
# /rom firmware files by removing the OverlayFS upper-layer overrides and
# restarting netmonitor.
#
# Usage:
#   ./scripts/revert-speaker-patches.sh <speaker_ip> [<speaker_ip_2> ...]
# ==============================================================================
set -euo pipefail

if [[ $# -eq 0 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $(basename "$0") <speaker_ip_or_host> [<speaker_ip_2> ...]"
    exit 0
fi

for host in "$@"; do
    ip_only="${host%:5555}"
    adb_target="${ip_only}:5555"

    echo "[*] Connecting to ${adb_target} to revert OverlayFS patches..."
    adb connect "${adb_target}" >/dev/null 2>&1
    adb -s "${adb_target}" shell '
        rm -f /data/overlay/upper/etc/init.d/S30dbus \
              /data/overlay/upper/etc/init.d/S39wifi \
              /data/overlay/upper/etc/init.d/S41dhcpcd \
              /data/overlay/upper/etc/init.d/S99ha-speaker \
              /data/overlay/upper/usr/share/thirdreality/script/netmonitor \
              /data/overlay/upper/usr/share/udhcpc/default.script.d/disable-wifi-powersave
        sync
        mount -o remount / 2>/dev/null || true
        start-stop-daemon -S -b -x /etc/init.d/S99ha-speaker -- netmonitor restart
    ' </dev/null
    echo "[+] Reverted ${ip_only} to stock /rom scripts (reboot speaker to ensure clean lowerdir lookup)."
done
