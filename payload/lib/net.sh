#!/usr/bin/env bash
# RigCheck — best-effort connectivity: ethernet first, then configured wifi hotspot.
# Creates $RUN/online on success. Never fatal.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
CONF="$RIGDIR/rigcheck.conf"; [ -f "$CONF" ] && . "$CONF"

is_online() {
    if has curl; then curl -sm 5 -o /dev/null https://connectivitycheck.gstatic.com/generate_204 && return 0; fi
    ping -c1 -W3 1.1.1.1 >/dev/null 2>&1
}

if is_online; then ok "Network: already online (ethernet/DHCP)"; touch "$RUN/online"; exit 0; fi

# wait briefly for ethernet DHCP to settle
for _ in 1 2 3; do sleep 5; is_online && { ok "Network: online via ethernet"; touch "$RUN/online"; exit 0; }; done

if [ -z "${WIFI_SSID:-}" ]; then log "Network: offline (no wifi configured) — continuing offline"; exit 0; fi

log "Trying wifi hotspot '$WIFI_SSID'..."
[ -n "${WIFI_COUNTRY:-}" ] && has iw && iw reg set "$WIFI_COUNTRY" 2>/dev/null || true

if has nmcli; then
    nmcli radio wifi on >/dev/null 2>&1 || true
    for attempt in 1 2 3; do
        nmcli dev wifi rescan >/dev/null 2>&1 || true; sleep 4
        if nmcli dev wifi connect "$WIFI_SSID" password "${WIFI_PASSWORD:-}" >/dev/null 2>&1; then break; fi
        sleep 6
    done
elif has iwctl; then
    WLAN=$(iwctl device list 2>/dev/null | awk '/station/{print $2; exit}')
    [ -n "${WLAN:-}" ] && iwctl --passphrase "${WIFI_PASSWORD:-}" station "$WLAN" connect "$WIFI_SSID" >/dev/null 2>&1 || true
    sleep 8
elif has wpa_supplicant; then
    WLAN=$(ls /sys/class/net | grep -m1 '^wl' || true)
    if [ -n "$WLAN" ]; then
        wpa_passphrase "$WIFI_SSID" "${WIFI_PASSWORD:-}" > /tmp/rig_wpa.conf 2>/dev/null || true
        wpa_supplicant -B -i "$WLAN" -c /tmp/rig_wpa.conf >/dev/null 2>&1 || true
        sleep 6; (dhcpcd "$WLAN" >/dev/null 2>&1 || dhclient "$WLAN" >/dev/null 2>&1) || true
    fi
fi

sleep 4
if is_online; then ok "Network: online via wifi"; touch "$RUN/online"
else warn "Network: could not get online — continuing offline (report stays on the USB)"; fi
exit 0
