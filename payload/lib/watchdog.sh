#!/usr/bin/env bash
# RigCheck thermal watchdog — samples temps every 2s, logs to temps.csv,
# creates $RUN/ABORT when thresholds are breached (run_stress kills stressors).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ABORT_MC=$(( ${ABORT_TEMP_C:-95} * 1000 ))
NVME_ABORT_MC=$(( ${NVME_ABORT_TEMP_C:-82} * 1000 ))
CSV="$RUN/temps.csv"; WLOG="$RUN/watchdog.log"
echo "epoch,cpu_c,nvme_c" > "$CSV"
strikes=0; nstrikes=0

while :; do
    cpu=$(cpu_temp_mc); nv=$(nvme_temp_mc)
    printf '%s,%s,%s\n' "$(date +%s)" "$((cpu/1000))" "$((nv/1000))" >> "$CSV"

    if [ "$cpu" -ge $((ABORT_MC + 5000)) ]; then
        echo "THERMAL_CPU instant $((cpu/1000))C" >> "$WLOG"
        echo "THERMAL_CPU $((cpu/1000))C" > "$RUN/abort_reason"; touch "$RUN/ABORT"
        warn "WATCHDOG: CPU $((cpu/1000))°C — ABORTING stress tests NOW"
    elif [ "$cpu" -ge "$ABORT_MC" ]; then
        strikes=$((strikes+1))
        if [ "$strikes" -ge 2 ] && [ ! -f "$RUN/ABORT" ]; then
            echo "THERMAL_CPU sustained $((cpu/1000))C" >> "$WLOG"
            echo "THERMAL_CPU $((cpu/1000))C" > "$RUN/abort_reason"; touch "$RUN/ABORT"
            warn "WATCHDOG: CPU sustained $((cpu/1000))°C — ABORTING stress tests"
        fi
    else strikes=0; fi

    if [ "$nv" -gt 0 ]; then
        if [ "$nv" -ge "$NVME_ABORT_MC" ]; then
            nstrikes=$((nstrikes+1))
            if [ "$nstrikes" -ge 2 ] && [ ! -f "$RUN/ABORT" ]; then
                echo "THERMAL_NVME sustained $((nv/1000))C" >> "$WLOG"
                echo "THERMAL_NVME $((nv/1000))C" > "$RUN/abort_reason"; touch "$RUN/ABORT"
                warn "WATCHDOG: NVMe sustained $((nv/1000))°C — ABORTING stress tests"
            fi
        else nstrikes=0; fi
    fi
    sleep 2
done
