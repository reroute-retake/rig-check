#!/usr/bin/env bash
# RigCheck — hardware detection: capture raw tool output into $RUN/raw/ for report.py
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

log "Loading sensor modules..."
has sensors-detect && { yes "" | sensors-detect --auto >/dev/null 2>&1 || true; }
modprobe coretemp 2>/dev/null || true; modprobe k10temp 2>/dev/null || true; modprobe drivetemp 2>/dev/null || true

log "Collecting system inventory..."
capture uname.txt        uname -a
capture lscpu.txt        lscpu
capture meminfo.txt      cat /proc/meminfo
capture free.txt         free -b
has dmidecode && {
    capture dmi_bios.txt      dmidecode -t bios
    capture dmi_system.txt    dmidecode -t system
    capture dmi_baseboard.txt dmidecode -t baseboard
    capture dmi_memory.txt    dmidecode -t memory
    capture dmi_processor.txt dmidecode -t processor
    capture dmi_chassis.txt   dmidecode -t chassis
}

# boot mode, chassis power, sensor limits (for capability probing)
if [ -d /sys/firmware/efi ]; then echo uefi > "$RUN/raw/boot_mode.txt"; else echo bios > "$RUN/raw/boot_mode.txt"; fi
ls /sys/class/power_supply > "$RUN/raw/power_supply.txt" 2>/dev/null || true
{
    for hw in /sys/class/hwmon/hwmon*; do
        n=$(cat "$hw/name" 2>/dev/null) || continue
        echo "chip $n"
        for f in "$hw"/temp*_crit "$hw"/temp*_max; do
            [ -r "$f" ] && echo "$(basename "$f") $(cat "$f" 2>/dev/null)"
        done
    done
} > "$RUN/raw/hwmon.txt" 2>/dev/null || true
has lsblk  && capture lsblk.json  lsblk -J -b -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA,RM,PKNAME,MOUNTPOINT
has lspci  && capture lspci.txt   lspci -nnk
has lsusb  && capture lsusb.txt   lsusb
has ip     && capture ip_addr.json ip -j addr
has sensors && capture sensors.json sensors -j
has lshw   && capture lshw.json   lshw -json -quiet
has inxi   && capture inxi.txt    inxi -Fxz -c0
has nvme   && capture nvme_list.json nvme list -o json

# Per-drive SMART snapshots ("before"); exclude the RigCheck USB stick itself
STICK_DISK=""
src=$(findmnt -no SOURCE --target "$RIGDIR" 2>/dev/null || true)
[ -n "$src" ] && STICK_DISK=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1 || true)
echo "${STICK_DISK:-}" > "$RUN/stick_disk"

if has smartctl; then
    while read -r d; do
        [ -n "$d" ] || continue
        [ "$d" = "${STICK_DISK:-}" ] && continue
        capture "smart_before_${d}.json" smartctl -xj "/dev/$d"
    done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | grep -Ev '^(loop|zram|sr|fd)')
fi

ok "Detection complete ($(ls "$RUN/raw" | wc -l) artifacts)"
