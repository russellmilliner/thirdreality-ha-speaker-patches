#!/usr/bin/env bash
# ==============================================================================
# check-speaker-status.sh
#
# Connects to one or more ThirdReality Home Assistant Speakers (3RAB01090D) via
# ADB, verifies that all 6 hardened files are installed with matching SHA-256
# checksums and permissions, and prints a full Wi-Fi + service health summary.
#
# Usage:
#   ./scripts/check-speaker-status.sh <speaker_ip> [<speaker_ip_2> ...]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FILES_DIR="${REPO_ROOT}/files"

if [[ $# -eq 0 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $(basename "$0") <speaker_ip_or_host> [<speaker_ip_2> ...]"
    exit 0
fi

PATCHED_REL_PATHS=(
    "etc/init.d/S30dbus"
    "etc/init.d/S39wifi"
    "etc/init.d/S41dhcpcd"
    "etc/init.d/S99ha-speaker"
    "usr/share/thirdreality/script/netmonitor"
    "usr/share/udhcpc/default.script.d/disable-wifi-powersave"
)

check_speaker() {
    local host="$1"
    local ip_only="${host%:5555}"
    local adb_target="${ip_only}:5555"

    echo "--------------------------------------------------------------------------------"
    echo "Speaker Diagnostic Report: ${ip_only}"
    echo "--------------------------------------------------------------------------------"

    if ! adb connect "${adb_target}" >/dev/null 2>&1; then
        echo "[!] ADB connection failed to ${adb_target}" >&2
        return 1
    fi

    adb -s "${adb_target}" shell '
        SPK_NAME=$(jq -r ".device.name // \"unknown\"" /data/conf/device.json 2>/dev/null)
        MODEL_ID=$(jq -r ".device.modelID // \"3RAB01090D\"" /data/conf/device.json 2>/dev/null)
        FW_VER=$(jq -r ".device.firmwareVersion // \"1.02.04\"" /data/conf/device.json 2>/dev/null)
        NET_STATUS=$(jq -r ".network.status // \"unknown\"" /data/conf/device.json 2>/dev/null)
        MAC_ADDR=$(cat /sys/class/net/wlan0/address 2>/dev/null || echo "missing")
        IPV4_ADDR=$(ip -o -4 addr show dev wlan0 scope global 2>/dev/null | awk "{print \$4}" | head -1)
        GW_ADDR=$(ip route show default dev wlan0 2>/dev/null | awk "/default/ {print \$3; exit}")
        PWR_SAVE=$(iw dev wlan0 get power_save 2>/dev/null | awk "{print \$NF}")
        BSSID=$(iw dev wlan0 link 2>/dev/null | awk "/Connected to/ {print \$3}")
        SSID=$(iw dev wlan0 link 2>/dev/null | awk -F": " "/SSID:/ {print \$2}")
        SIGNAL=$(iw dev wlan0 link 2>/dev/null | awk -F": " "/signal:/ {print \$2}")
        PULSE_COUNT=$(ls -1 /var/pulse 2>/dev/null | wc -l)
        MID_ETC=$(cat /etc/machine-id 2>/dev/null || echo "missing")
        MID_DBUS=$(cat /var/lib/dbus/machine-id 2>/dev/null || echo "missing")
        PORT_6053=$(netstat -tlne 2>/dev/null | grep -q ":6053 " && echo "LISTENING" || echo "DOWN")
        PORT_8928=$(netstat -tlne 2>/dev/null | grep -q ":8928 " && echo "LISTENING" || echo "DOWN")
        HOOK_PERM=$([ -x /usr/share/udhcpc/default.script.d/disable-wifi-powersave ] && echo "executable (+x)" || echo "NOT EXECUTABLE (0644)")

        echo "  Device Name      : ${SPK_NAME} (${MODEL_ID})"
        echo "  Firmware / Kernel: ${FW_VER} / $(uname -sr)"
        echo "  Uptime           : $(uptime)"
        echo "  wlan0 MAC / IPv4 : ${MAC_ADDR} / ${IPV4_ADDR:-none} (gw: ${GW_ADDR:-none})"
        echo "  Wi-Fi Link       : SSID=${SSID:-none}, BSSID=${BSSID:-none}, Signal=${SIGNAL:-n/a}"
        echo "  Wi-Fi Power Save : ${PWR_SAVE:-unknown} (udhcpc hook mode: ${HOOK_PERM})"
        echo "  netmonitor State : ${NET_STATUS}"
        echo "  D-Bus machine-id : /etc=${MID_ETC} (matches /var/lib/dbus: $([ \"$MID_ETC\" = \"$MID_DBUS\" ] && echo YES || echo NO))"
        echo "  /var/pulse Files : ${PULSE_COUNT} files"
        echo "  TCP Ports        : :6053 (ESPHome API)=${PORT_6053}, :8928 (Sendspin)=${PORT_8928}"
    ' </dev/null | tr -d '\r'

    echo "  Patch Checksums  :"
    local all_ok=1
    for rel in "${PATCHED_REL_PATHS[@]}"; do
        local local_sha remote_sha
        local_sha="$(sha256sum "${FILES_DIR}/${rel}" | awk '{print $1}')"
        remote_sha="$(adb -s "${adb_target}" shell "sha256sum /${rel} 2>/dev/null" </dev/null | awk '{print $1}' | tr -d '\r')"
        if [[ "${local_sha}" == "${remote_sha}" ]]; then
            echo "    [OK]       /${rel}"
        else
            echo "    [MISMATCH] /${rel} (remote=${remote_sha:-missing})"
            all_ok=0
        fi
    done

    if [[ "${all_ok}" -eq 1 ]]; then
        echo "[+] All 6 hardened patches verified on ${ip_only}."
    else
        echo "[!] One or more files on ${ip_only} do not match the repository." >&2
        return 1
    fi
}

EXIT_CODE=0
for target in "$@"; do
    if ! check_speaker "${target}"; then
        EXIT_CODE=1
    fi
done

exit "${EXIT_CODE}"
