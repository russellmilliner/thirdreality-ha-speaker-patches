#!/usr/bin/env bash
# ==============================================================================
# apply-speaker-patches.sh
#
# Deploys the ThirdReality Home Assistant Speaker (3RAB01090D, Firmware 1.02.04)
# Wi-Fi, SDIO, DHCP, D-Bus, and Voice Assistant reliability patches over ADB.
#
# DISCLAIMER: COMPLETELY DIAGNOSED AND DEVELOPED BY AI (GOOGLE GEMINI 4 ARGON).
# UNSUPPORTED BY THE AUTHOR OR VENDOR (THIRDREALITY). PROVIDED "AS IS" WITHOUT
# WARRANTY OR SUPPORT OF ANY KIND. USE AT YOUR OWN RISK.
# Support / Buy Me a Coffee: https://ko-fi.com/russellmilliner
#
# Usage:
#   ./scripts/apply-speaker-patches.sh <speaker_ip> [<speaker_ip_2> ...]
#   ./scripts/apply-speaker-patches.sh --wait <speaker_ip>
#   ./scripts/apply-speaker-patches.sh --dry-run <speaker_ip>
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FILES_DIR="${REPO_ROOT}/files"

WAIT_FOR_ONLINE=0
DRY_RUN=0
TARGETS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <speaker_ip_or_host> [<speaker_ip_2> ...]

Options:
  --wait       Wait for an offline/wedged speaker to respond to ping (e.g. while
               power-cycling it) and immediately deploy as soon as ADB comes up.
  --dry-run    Connect via ADB and compare live files against the patched files
               without modifying the speaker.
  -h, --help   Show this help message.

Examples:
  $(basename "$0") 192.168.1.250 192.168.0.250
  $(basename "$0") --wait 192.168.1.250
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wait)
            WAIT_FOR_ONLINE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            usage
            exit 1
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "Error: At least one speaker IP address or hostname is required." >&2
    usage
    exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
    echo "Error: 'adb' (Android Debug Bridge) is required but not installed in PATH." >&2
    exit 1
fi

PATCHED_REL_PATHS=(
    "etc/init.d/S30dbus"
    "etc/init.d/S39wifi"
    "etc/init.d/S41dhcpcd"
    "etc/init.d/S99ha-speaker"
    "usr/share/thirdreality/script/netmonitor"
    "usr/share/udhcpc/default.script.d/disable-wifi-powersave"
)

deploy_to_speaker() {
    local host="$1"
    local adb_target="${host%:5555}:5555"
    local ip_only="${host%:5555}"

    echo "================================================================================"
    echo "[*] Target Speaker: ${ip_only} (ADB: ${adb_target})"
    echo "================================================================================"

    if [[ "${WAIT_FOR_ONLINE}" -eq 1 ]]; then
        echo "[*] Waiting for ${ip_only} to respond to ping..."
        while ! ping -c 1 -W 1 "${ip_only}" >/dev/null 2>&1; do
            sleep 2
        done
        echo "[+] ${ip_only} is online! Waiting 3s for adbd..."
        sleep 3
    fi

    adb disconnect "${adb_target}" >/dev/null 2>&1 || true
    local connect_out
    connect_out="$(adb connect "${adb_target}" 2>&1 || true)"
    if [[ "${connect_out}" != *"connected to"* ]]; then
        echo "[!] Failed to connect to ${adb_target}: ${connect_out}" >&2
        return 1
    fi

    # Verify target is a ThirdReality 3RAB01090D Linux Voice Assistant speaker
    if ! adb -s "${adb_target}" shell "test -f /rom/etc/init.d/S99ha-speaker && test -d /data/overlay/upper" </dev/null >/dev/null 2>&1; then
        echo "[!] Target ${ip_only} does not appear to be a ThirdReality 3RAB01090D speaker with OverlayFS." >&2
        return 1
    fi

    local spk_name
    spk_name="$(adb -s "${adb_target}" shell "jq -r '.device.name // \"unknown\"' /data/conf/device.json 2>/dev/null" </dev/null | tr -d '\r')"
    echo "[+] Connected to speaker: ${spk_name} (${ip_only})"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[*] Dry-run mode: checking SHA-256 checksums on ${ip_only}..."
        for rel in "${PATCHED_REL_PATHS[@]}"; do
            local local_sha remote_sha
            local_sha="$(sha256sum "${FILES_DIR}/${rel}" | awk '{print $1}')"
            remote_sha="$(adb -s "${adb_target}" shell "sha256sum /${rel} 2>/dev/null" </dev/null | awk '{print $1}' | tr -d '\r')"
            if [[ "${local_sha}" == "${remote_sha}" ]]; then
                echo "    [OK]      /${rel} (already matches patched version)"
            else
                echo "    [CHANGED] /${rel} (will be updated)"
            fi
        done
        return 0
    fi

    # 1. Backup pre-patch files on the speaker
    echo "[*] Backing up current files on speaker to /data/conf/backup-pre-patch/..."
    adb -s "${adb_target}" shell "
        mkdir -p /data/conf/backup-pre-patch/etc/init.d \
                 /data/conf/backup-pre-patch/usr/share/thirdreality/script \
                 /data/conf/backup-pre-patch/usr/share/udhcpc/default.script.d
        for rel in etc/init.d/S30dbus etc/init.d/S39wifi etc/init.d/S41dhcpcd etc/init.d/S99ha-speaker usr/share/thirdreality/script/netmonitor usr/share/udhcpc/default.script.d/disable-wifi-powersave; do
            if [ ! -f \"/data/conf/backup-pre-patch/\${rel}\" ] && [ -f \"/\${rel}\" ]; then
                cp -p \"/\${rel}\" \"/data/conf/backup-pre-patch/\${rel}\"
            fi
        done
    " </dev/null

    # 2. Push hardened files
    echo "[*] Pushing 6 hardened scripts/hooks to ${ip_only}..."
    for rel in "${PATCHED_REL_PATHS[@]}"; do
        adb -s "${adb_target}" push "${FILES_DIR}/${rel}" "/${rel}" >/dev/null
    done

    # 3. Apply permissions, clean up leaked artifacts, persist machine-id, and disable Wi-Fi power-save
    echo "[*] Setting permissions, persisting D-Bus machine-id, pruning /var/pulse, and disabling wlan0 power_save..."
    adb -s "${adb_target}" shell "
        chmod 0755 /etc/init.d/S30dbus \
                   /etc/init.d/S39wifi \
                   /etc/init.d/S41dhcpcd \
                   /etc/init.d/S99ha-speaker \
                   /usr/share/thirdreality/script/netmonitor \
                   /usr/share/udhcpc/default.script.d/disable-wifi-powersave

        # Remove stray '/1' file created by stock S41dhcpcd '2&>1' redirection bug
        rm -f /1 /data/overlay/upper/1 2>/dev/null || true

        # Ensure /var/lib/ntp exists so ntpd can write ntp.drift
        mkdir -p /var/lib/ntp

        # Persist D-Bus machine-id across reboots and prune leaked /var/pulse files
        if [ -s /var/lib/dbus/machine-id ]; then
            MID=\$(cat /var/lib/dbus/machine-id)
            [ ! -s /etc/machine-id ] && cp /var/lib/dbus/machine-id /etc/machine-id
            for f in /var/pulse/*; do
                [ -e \"\$f\" ] || continue
                case \"\$f\" in
                    *\"\$MID\"*|*/cookie) ;;
                    *) rm -f \"\$f\" \"/data/overlay/upper\$f\" 2>/dev/null || true ;;
                esac
            done
        fi

        # Immediately disable BCM43438 Wi-Fi power save
        iw dev wlan0 set power_save off 2>/dev/null || true
        sync
    " </dev/null

    # 4. Restart netmonitor cleanly in the background without dropping Wi-Fi or voice-assistant
    echo "[*] Restarting netmonitor daemon..."
    adb -s "${adb_target}" shell "start-stop-daemon -S -b -x /etc/init.d/S99ha-speaker -- netmonitor restart" </dev/null
    sleep 2

    echo "[+] Successfully patched ${spk_name} (${ip_only})!"
    "${SCRIPT_DIR}/check-speaker-status.sh" "${ip_only}"
}

EXIT_CODE=0
for target in "${TARGETS[@]}"; do
    if ! deploy_to_speaker "${target}"; then
        EXIT_CODE=1
    fi
done

exit "${EXIT_CODE}"
