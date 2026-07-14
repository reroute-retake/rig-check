#!/usr/bin/env bash
# RigCheck — storage tests. STRICTLY NON-DESTRUCTIVE:
#   in-drive SMART self-tests (short/long) + read-only benchmarks + SMART snapshots.
# Modes: main (default) | collect (re-poll long self-tests at end of run)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PHASE="${1:-main}"
STICK_DISK=$(cat "$RUN/stick_disk" 2>/dev/null || true)

disks() {
    lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | grep -Ev '^(loop|zram|sr|fd)' \
        | while read -r d; do [ "$d" = "${STICK_DISK:-}" ] || echo "$d"; done
}

selftest_status() { # <disk> -> running|passed|failed|unknown
    local out
    out=$(smartctl -aj "/dev/$1" 2>/dev/null | python3 -c '
import json,sys
try: j=json.load(sys.stdin)
except Exception: print("unknown"); raise SystemExit
st=j.get("ata_smart_data",{}).get("self_test",{}).get("status",{})
if st:
    if "remaining_percent" in st or st.get("value",0)>=240: print("running")
    elif st.get("passed") is True: print("passed")
    elif st.get("passed") is False: print("failed")
    else: print("unknown")
else:
    cur=j.get("nvme_self_test_log",{}).get("current_self_test_operation",{})
    if isinstance(cur,dict) and cur.get("value",0)!=0: print("running")
    else:
        tab=j.get("nvme_self_test_log",{}).get("table",[])
        if tab and isinstance(tab[0].get("self_test_result"),dict) and tab[0]["self_test_result"].get("value",15)==0: print("passed")
        else: print("unknown")
' 2>/dev/null)
    echo "${out:-unknown}"
}

if [ "$PHASE" = "collect" ]; then
    # final poll of long self-tests (detailed mode), capped at 150 min
    deadline=$(( $(date +%s) + 9000 ))
    for d in $(cat "$RUN/longtest.list" 2>/dev/null); do
        while [ "$(date +%s)" -lt "$deadline" ] && [ ! -f "$RUN/ABORT" ]; do
            s=$(selftest_status "$d")
            [ "$s" = "running" ] || break
            log "SMART extended self-test still running on $d ..."; sleep 120
        done
        capture "smart_after_${d}.json" smartctl -xj "/dev/$d"
        echo "STORAGE_${d}_LONGTEST=$(selftest_status "$d")" >> "$RUN/storage_${d}.env"
    done
    exit 0
fi

DISKS=$(disks)
[ -n "$DISKS" ] || { warn "No internal disks found (only the RigCheck stick?)"; echo "STORAGE_NONE=1" > "$RUN/storage_none.env"; exit 0; }

for d in $DISKS; do
    ENV="$RUN/storage_${d}.env"; : > "$ENV"
    log "Drive /dev/$d:"

    # 1. launch in-drive SMART self-test (runs inside the drive firmware)
    KIND="${SMART_KIND:-short}"
    if has smartctl; then
        if smartctl -t "$KIND" "/dev/$d" >/dev/null 2>&1; then
            echo "STORAGE_${d}_SELFTEST_KIND=$KIND" >> "$ENV"
            [ "$KIND" = "long" ] && echo "$d" >> "$RUN/longtest.list"
        elif has nvme && [[ "$d" == nvme* ]] && nvme device-self-test "/dev/$d" -s 1 >/dev/null 2>&1; then
            echo "STORAGE_${d}_SELFTEST_KIND=short-nvme" >> "$ENV"
        else
            echo "STORAGE_${d}_SELFTEST_KIND=unsupported" >> "$ENV"
        fi
    fi

    # 2. read-only benchmark while self-test runs
    if has fio; then
        fio --name=seqread --filename="/dev/$d" --readonly --rw=read --bs=1M --iodepth=8 --direct=1 \
            --runtime="${FIO_SECS:-60}" --time_based --output-format=json \
            > "$RUN/raw/fio_seq_${d}.json" 2>/dev/null || true
        fio --name=randread --filename="/dev/$d" --readonly --rw=randread --bs=4k --iodepth=32 --direct=1 \
            --runtime="$(( ${FIO_SECS:-60} / 2 ))" --time_based --output-format=json \
            > "$RUN/raw/fio_rand_${d}.json" 2>/dev/null || true
        echo "STORAGE_${d}_BENCH_TOOL=fio" >> "$ENV"
    elif has hdparm; then
        capture "hdparm_${d}.txt" hdparm -t "/dev/$d"
        MBS=$(grep -oE '= *[0-9.]+ MB/sec' "$RUN/raw/hdparm_${d}.txt" 2>/dev/null | grep -oE '[0-9.]+' | head -1)
        echo "STORAGE_${d}_BENCH_TOOL=hdparm" >> "$ENV"
        [ -n "${MBS:-}" ] && echo "STORAGE_${d}_SEQ_READ_MBS=$MBS" >> "$ENV"
    else
        log "  (no fio/hdparm — dd read sample)"
        SPD=$( (dd if="/dev/$d" of=/dev/null bs=1M count=1024 iflag=direct 2>&1 || true) | grep -oE '[0-9.]+ [MG]B/s' | head -1)
        echo "STORAGE_${d}_BENCH_TOOL=dd" >> "$ENV"
        [ -n "${SPD:-}" ] && echo "STORAGE_${d}_SEQ_READ_MBS=${SPD% *}" >> "$ENV"
    fi

    # 3. wait for SHORT self-test to complete (bounded), then snapshot
    if [ "${SMART_KIND:-short}" = "short" ] && has smartctl; then
        for _ in 1 2 3 4 5 6 7 8; do
            [ -f "$RUN/ABORT" ] && break
            s=$(selftest_status "$d"); [ "$s" = "running" ] || break
            sleep 30
        done
        echo "STORAGE_${d}_SELFTEST_STATUS=$(selftest_status "$d")" >> "$ENV"
    fi
    has smartctl && capture "smart_after_${d}.json" smartctl -xj "/dev/$d"
    ok "  /dev/$d done"
    [ -f "$RUN/ABORT" ] && break
done
exit 0
