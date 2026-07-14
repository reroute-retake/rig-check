#!/usr/bin/env bash
# RigCheck — CPU stability (Phase 3): verified stress, optional torture stage
# (detailed tier), throttle detection, benchmark, and — when errors appear —
# a per-core isolation pass that attributes faults to specific cores.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ENV="$RUN/cpu.env"; LOGF="$RUN/cpu_stress.log"
N=$(nproc)

throttle_sum() {
    local s=0 f v
    for f in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
        [ -r "$f" ] || continue; v=$(cat "$f" 2>/dev/null || echo 0); s=$((s+v))
    done
    echo "$s"
}
T0=$(throttle_sum)
W0=$(wc -l < "$RUN/temps.csv" 2>/dev/null || echo 1)

# ---------------------------------------------------------------- stage 1: parallel verified stress
log "Stressing $N threads for $((${CPU_SECS:-300}/60)) min..."
if has stress-ng; then
    TOOL="stress-ng"
    outcome=$(run_stress cpu $(( ${CPU_SECS:-300} + 60 )) "$LOGF" \
        stress-ng --cpu "$N" --cpu-method matrixprod --verify --metrics-brief --timeout "${CPU_SECS:-300}s")
elif has stress; then
    TOOL="stress"
    outcome=$(run_stress cpu $(( ${CPU_SECS:-300} + 60 )) "$LOGF" stress --cpu "$N" --timeout "${CPU_SECS:-300}")
else
    TOOL="python-burn"
    cat > /tmp/rig_cpuburn.py <<'PYEOF'
import hashlib, multiprocessing, sys, time
def burn(secs):
    ref = hashlib.sha256(b"rigcheck-reference").hexdigest()
    end = time.time() + secs; it = 0; errs = 0
    while time.time() < end:
        for _ in range(2000):
            if hashlib.sha256(b"rigcheck-reference").hexdigest() != ref:
                errs += 1; print("VERIFYFAIL", flush=True)
            it += 1
    print(f"worker done iters={it} errors={errs}", flush=True)
if __name__ == "__main__":
    secs, n = int(sys.argv[1]), int(sys.argv[2])
    ps = [multiprocessing.Process(target=burn, args=(secs,)) for _ in range(n)]
    [p.start() for p in ps]; [p.join() for p in ps]
PYEOF
    outcome=$(run_stress cpu $(( ${CPU_SECS:-300} + 60 )) "$LOGF" python3 /tmp/rig_cpuburn.py "${CPU_SECS:-300}" "$N")
fi
rc=$(cat "$RUN/cpu.rc" 2>/dev/null || echo 0)
VERIFY_ERRS=$(grep -ciE 'verif.*fail|VERIFYFAIL|error:' "$LOGF" 2>/dev/null); VERIFY_ERRS=${VERIFY_ERRS:-0}

# ---------------------------------------------------------------- stage 2 (detailed): memory-bus torture
TORTURE_ERRS=0; TORTURE_RAN=0
if [ "${TORTURE:-0}" = "1" ] && has stress-ng && [ ! -f "$RUN/ABORT" ]; then
    tsecs=$(( ${CPU_SECS:-300} / 2 )); [ "$tsecs" -lt 120 ] && tsecs=120
    log "Torture stage: matrix/memory-bus stress for $((tsecs/60)) min..."
    t_outcome=$(run_stress cpu_torture $(( tsecs + 60 )) "$RUN/cpu_torture.log" \
        stress-ng --matrix 0 --verify --timeout "${tsecs}s")
    TORTURE_ERRS=$(grep -ciE 'verif.*fail|error:' "$RUN/cpu_torture.log" 2>/dev/null); TORTURE_ERRS=${TORTURE_ERRS:-0}
    TORTURE_RAN=1
    [ "$t_outcome" = "crashed" ] && TORTURE_ERRS=$(( TORTURE_ERRS + 1 ))
fi

# ---------------------------------------------------------------- per-core attribution on failure
BAD_CORES=""
total_errs=$(( VERIFY_ERRS + TORTURE_ERRS ))
if { [ "$total_errs" -gt 0 ] || [ "$outcome" = "crashed" ] || [ "${CPU_FORCE_ATTRIB:-0}" = "1" ]; } && [ ! -f "$RUN/ABORT" ]; then
    per=${CPU_ATTRIB_SECS:-20}
    log "Errors detected — isolating faulty core(s) (${per}s per core, $N cores)..."
    cat > /tmp/rig_coreburn.py <<'PYEOF'
import hashlib, os, sys, time
core, secs = int(sys.argv[1]), float(sys.argv[2])
try: os.sched_setaffinity(0, {core})
except OSError: print(f"AFFINITY_FAIL core {core}"); sys.exit(0)
ref = hashlib.sha256(b"rigcheck-reference").hexdigest()
end = time.time() + secs; e = 0
while time.time() < end:
    for _ in range(2000):
        if hashlib.sha256(b"rigcheck-reference").hexdigest() != ref:
            e += 1; print("VERIFYFAIL", flush=True)
print(f"core {core} errors={e}", flush=True)
sys.exit(1 if e else 0)
PYEOF
    for (( c=0; c<N; c++ )); do
        [ -f "$RUN/ABORT" ] && break
        if has stress-ng && has taskset; then
            taskset -c "$c" stress-ng --cpu 1 --cpu-method matrixprod --verify --timeout "${per}s" \
                > "$RUN/percore_${c}.log" 2>&1; crc=$?
            cerr=$(grep -ciE 'verif.*fail|error:' "$RUN/percore_${c}.log" 2>/dev/null); cerr=${cerr:-0}
        else
            python3 /tmp/rig_coreburn.py "$c" "$per" > "$RUN/percore_${c}.log" 2>&1; crc=$?
            cerr=$(grep -c VERIFYFAIL "$RUN/percore_${c}.log" 2>/dev/null); cerr=${cerr:-0}
        fi
        if [ "$cerr" -gt 0 ] || [ "$crc" -gt 1 ]; then
            BAD_CORES="${BAD_CORES}${c},"
            warn "  core $c: FAULTY ($cerr verification errors)"
        else
            log "  core $c: ok"
        fi
    done
    BAD_CORES="${BAD_CORES%,}"
fi

# ---------------------------------------------------------------- collect
T1=$(throttle_sum); THROTTLE=$((T1 - T0))
MAXT=$(tail -n +"$W0" "$RUN/temps.csv" 2>/dev/null | awk -F, 'NR>0 && $2+0>m{m=$2+0} END{print m+0}')
BOGO=$(grep -oE 'cpu[[:space:]]+[0-9]+' "$LOGF" 2>/dev/null | awk '{print $2}' | head -1)

{
echo "CPU_TOOL=$TOOL"; echo "CPU_THREADS=$N"; echo "CPU_SECS=${CPU_SECS:-300}"
echo "CPU_OUTCOME=$outcome"; echo "CPU_VERIFY_ERRORS=$total_errs"
echo "CPU_TORTURE_RAN=$TORTURE_RAN"
echo "CPU_THROTTLE_EVENTS=$THROTTLE"; echo "CPU_MAX_TEMP_C=${MAXT:-0}"
[ -n "${BOGO:-}" ] && echo "CPU_BOGO_OPS=$BOGO"
[ -n "$BAD_CORES" ] && echo "CPU_BAD_CORES=$BAD_CORES"
case "$outcome" in
    completed|timeout)
        if [ "$total_errs" -gt 0 ]; then echo "CPU_RESULT=fail"; echo "CPU_NOTES=computation verification errors under load"
        else echo "CPU_RESULT=pass"; fi ;;
    aborted) echo "CPU_RESULT=aborted"; echo "CPU_NOTES=watchdog/user abort — see thermal data" ;;
    crashed) echo "CPU_RESULT=fail"; echo "CPU_NOTES=stressor exited abnormally (rc=$rc) — instability under load" ;;
esac
} >> "$ENV"

# ---------------------------------------------------------------- benchmark (skipped if aborted)
if [ ! -f "$RUN/ABORT" ]; then
    log "Benchmarking..."
    if has 7z; then
        capture 7z_bench.txt 7z b -mmt"$N"
        MIPS=$(grep -E '^Tot:' "$RUN/raw/7z_bench.txt" 2>/dev/null | awk '{print $NF}')
        [ -n "${MIPS:-}" ] && echo "BENCH_7Z_MIPS=$MIPS" >> "$ENV"
    fi
    if has openssl; then
        capture openssl_speed.txt openssl speed -multi "$N" -seconds 2 sha256
        OSSL=$(grep -E '^sha256' "$RUN/raw/openssl_speed.txt" 2>/dev/null | tail -1 | awk '{print $NF}')
        [ -n "${OSSL:-}" ] && echo "BENCH_SHA256_16K=$OSSL" >> "$ENV"
    fi
fi
ok "CPU test done: $(grep CPU_RESULT "$ENV" | cut -d= -f2)$( [ -n "$BAD_CORES" ] && echo " — faulty core(s): $BAD_CORES" )"
