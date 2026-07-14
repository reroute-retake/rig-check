#!/usr/bin/env bash
# RigCheck — storage tests (Phase 3). STRICTLY NON-DESTRUCTIVE:
#   in-drive SMART self-tests (short/long) + read-only benchmarks + snapshots.
# Self-tests are launched on ALL drives in parallel, then polled together with
# live progress; extended tests print an ETA from the drive's own estimate.
# Modes: main (default) | collect (re-poll long self-tests at end of run)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
PHASE="${1:-main}"
STICK_DISK=$(cat "$RUN/stick_disk" 2>/dev/null || true)

disks() {
    lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | grep -Ev '^(loop|zram|sr|fd)' \
        | while read -r d; do [ "$d" = "${STICK_DISK:-}" ] || echo "$d"; done
}

smart_probe() { # <disk> <field: status|remaining|eta_min> — one smartctl call, python extraction
    smartctl -aj "/dev/$1" 2>/dev/null | python3 -c '
import json, sys
field = sys.argv[1]
try: j = json.load(sys.stdin)
except Exception: print("unknown" if field == "status" else "?"); raise SystemExit
st = j.get("ata_smart_data", {}).get("self_test", {}).get("status", {})
if field == "eta_min":
    print(j.get("ata_smart_data", {}).get("self_test", {}).get("polling_minutes", {}).get("extended", "?")); raise SystemExit
if field == "remaining":
    if "remaining_percent" in st: print(100 - int(st["remaining_percent"]))
    else:
        c = j.get("nvme_self_test_log", {}).get("current_self_test_completion_percent")
        print(c if c is not None else "?")
    raise SystemExit
# status
if st:
    if "remaining_percent" in st or st.get("value", 0) >= 240: print("running")
    elif st.get("passed") is True: print("passed")
    elif st.get("passed") is False: print("failed")
    else: print("unknown")
else:
    cur = j.get("nvme_self_test_log", {}).get("current_self_test_operation", {})
    if isinstance(cur, dict) and cur.get("value", 0) != 0: print("running")
    else:
        tab = j.get("nvme_self_test_log", {}).get("table", [])
        if tab and isinstance(tab[0].get("self_test_result"), dict):
            print("passed" if tab[0]["self_test_result"].get("value", 15) == 0 else "failed")
        else:
            # fall back to the ATA self-test LOG (most recent entry)
            log_tab = j.get("ata_smart_self_test_log", {}).get("standard", {}).get("table", [])
            if log_tab:
                s = (log_tab[0].get("status") or {})
                print("passed" if s.get("passed") is True else ("failed" if s.get("passed") is False else "unknown"))
            else: print("unknown")
' "$2" 2>/dev/null || echo "unknown"
}
selftest_status() { smart_probe "$1" status; }

poll_selftests() { # <cap_seconds> <disks...> — unified poll with progress
    local cap=$1; shift
    local deadline=$(( $(date +%s) + cap )) all_done line s r d
    while [ "$(date +%s)" -lt "$deadline" ]; do
        [ -f "$RUN/ABORT" ] && return 1
        all_done=1; line=""
        for d in "$@"; do
            s=$(selftest_status "$d")
            if [ "$s" = "running" ]; then
                all_done=0; r=$(smart_probe "$d" remaining)
                line="${line}${d}:${r}% "
            fi
        done
        [ "$all_done" = "1" ] && return 0
        log "  self-tests in progress: ${line}"
        sleep 30
    done
    return 2
}

if [ "$PHASE" = "collect" ]; then
    LONGDISKS=$(cat "$RUN/longtest.list" 2>/dev/null || true)
    if [ -n "$LONGDISKS" ]; then
        # shellcheck disable=SC2086
        poll_selftests 9000 $LONGDISKS || true
        for d in $LONGDISKS; do
            capture "smart_after_${d}.json" smartctl -xj "/dev/$d"
            echo "STORAGE_${d}_LONGTEST=$(selftest_status "$d")" >> "$RUN/storage_${d}.env"
        done
    fi
    exit 0
fi

DISKS=$(disks)
[ -n "$DISKS" ] || { warn "No internal disks found (only the RigCheck stick?)"; echo "STORAGE_NONE=1" > "$RUN/storage_none.env"; exit 0; }
KIND="${SMART_KIND:-short}"

# 1. launch in-drive self-tests on ALL drives (they run inside drive firmware, in parallel)
LAUNCHED=""
for d in $DISKS; do
    ENV="$RUN/storage_${d}.env"; : > "$ENV"
    if has smartctl && smartctl -t "$KIND" "/dev/$d" >/dev/null 2>&1; then
        echo "STORAGE_${d}_SELFTEST_KIND=$KIND" >> "$ENV"
        LAUNCHED="$LAUNCHED $d"
        if [ "$KIND" = "long" ]; then
            echo "$d" >> "$RUN/longtest.list"
            eta=$(smart_probe "$d" eta_min)
            log "  /dev/$d: extended self-test launched (drive estimates ~${eta} min)"
        fi
    elif has nvme && [[ "$d" == nvme* ]] && nvme device-self-test "/dev/$d" -s 1 >/dev/null 2>&1; then
        echo "STORAGE_${d}_SELFTEST_KIND=short-nvme" >> "$ENV"
        LAUNCHED="$LAUNCHED $d"
    else
        echo "STORAGE_${d}_SELFTEST_KIND=unsupported" >> "$ENV"
    fi
done

# 2. read-only benchmarks while self-tests run in-drive
for d in $DISKS; do
    [ -f "$RUN/ABORT" ] && break
    ENV="$RUN/storage_${d}.env"
    log "Drive /dev/$d: read-only benchmark..."
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
        SPD=$( (dd if="/dev/$d" of=/dev/null bs=1M count=1024 iflag=direct 2>&1 || true) | grep -oE '[0-9.]+ [MG]B/s' | head -1)
        echo "STORAGE_${d}_BENCH_TOOL=dd" >> "$ENV"
        [ -n "${SPD:-}" ] && echo "STORAGE_${d}_SEQ_READ_MBS=${SPD% *}" >> "$ENV"
    fi
done

# 3. short tests: wait (bounded) for all launched drives together, then snapshot
if [ "$KIND" = "short" ] && [ -n "$LAUNCHED" ]; then
    cap=360; [ "${MODE:-standard}" = "coffee" ] && cap=240
    # shellcheck disable=SC2086
    poll_selftests "$cap" $LAUNCHED || true
fi
for d in $DISKS; do
    ENV="$RUN/storage_${d}.env"
    if [ "$KIND" = "short" ]; then
        echo "STORAGE_${d}_SELFTEST_STATUS=$(selftest_status "$d")" >> "$ENV"
    fi
    has smartctl && capture "smart_after_${d}.json" smartctl -xj "/dev/$d"
    ok "  /dev/$d done"
done
exit 0
