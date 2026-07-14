#!/usr/bin/env bash
# RigCheck watchdog (Phase 3) — samples temps every 2s, logs temps.csv, and
# aborts stress ($RUN/ABORT) on: sustained CPU/NVMe/SATA over-temperature, or
# NEW SMART errors appearing mid-run (checked ~every 60s via smartwatch.py).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
LIBDIR="$(dirname "${BASH_SOURCE[0]}")"

ABORT_MC=$(( ${ABORT_TEMP_C:-95} * 1000 ))
NVME_ABORT_MC=$(( ${NVME_ABORT_TEMP_C:-82} * 1000 ))
DISK_ABORT_MC=$(( ${DISK_ABORT_TEMP_C:-70} * 1000 ))
CSV="$RUN/temps.csv"; WLOG="$RUN/watchdog.log"
echo "epoch,cpu_c,nvme_c,disk_c" > "$CSV"
strikes=0; nstrikes=0; dstrikes=0; tick=0

fire_abort() { # <reason...>
    [ -f "$RUN/ABORT" ] && return 0
    echo "$*" > "$RUN/abort_reason"; echo "$(date +%s) $*" >> "$WLOG"; touch "$RUN/ABORT"
    warn "WATCHDOG: $* — ABORTING stress tests"
    beep_pattern 5 400 &
}

while :; do
    cpu=$(cpu_temp_mc); nv=$(nvme_temp_mc); dk=$(sata_temp_mc)
    printf '%s,%s,%s,%s\n' "$(date +%s)" "$((cpu/1000))" "$((nv/1000))" "$((dk/1000))" >> "$CSV"

    # CPU: instant abort well past limit, sustained (2 samples) at limit
    if [ "$cpu" -ge $((ABORT_MC + 5000)) ]; then
        fire_abort "THERMAL_CPU $((cpu/1000))C (instant)"
    elif [ "$cpu" -ge "$ABORT_MC" ]; then
        strikes=$((strikes+1)); [ "$strikes" -ge 2 ] && fire_abort "THERMAL_CPU $((cpu/1000))C (sustained)"
    else strikes=0; fi

    # NVMe + SATA drive temps (sustained)
    if [ "$nv" -gt 0 ] && [ "$nv" -ge "$NVME_ABORT_MC" ]; then
        nstrikes=$((nstrikes+1)); [ "$nstrikes" -ge 2 ] && fire_abort "THERMAL_NVME $((nv/1000))C"
    else nstrikes=0; fi
    if [ "$dk" -gt 0 ] && [ "$dk" -ge "$DISK_ABORT_MC" ]; then
        dstrikes=$((dstrikes+1)); [ "$dstrikes" -ge 2 ] && fire_abort "THERMAL_DISK $((dk/1000))C"
    else dstrikes=0; fi

    # SMART delta check every ~60s (30 ticks x 2s)
    tick=$((tick+1))
    if [ $((tick % 30)) -eq 0 ] && [ ! -f "$RUN/ABORT" ]; then
        msg=$(python3 "$LIBDIR/smartwatch.py" check "$RUN" 2>/dev/null)
        if [ $? -eq 2 ] && [ -n "$msg" ]; then
            fire_abort "SMART_ERRORS $msg"
        fi
    fi
    sleep 2
done
