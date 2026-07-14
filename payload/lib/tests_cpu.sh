#!/usr/bin/env bash
# RigCheck — CPU stability stress (with computation verification where possible),
# throttle detection, and a quick benchmark. Watchdog can abort at any time.
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
T1=$(throttle_sum); THROTTLE=$((T1 - T0))
# max temp during the stress window (rows appended since W0)
MAXT=$(tail -n +"$W0" "$RUN/temps.csv" 2>/dev/null | awk -F, 'NR>0 && $2+0>m{m=$2+0} END{print m+0}')
BOGO=$(grep -oE 'cpu[[:space:]]+[0-9]+' "$LOGF" 2>/dev/null | awk '{print $2}' | head -1)

{
echo "CPU_TOOL=$TOOL"; echo "CPU_THREADS=$N"; echo "CPU_SECS=${CPU_SECS:-300}"
echo "CPU_OUTCOME=$outcome"; echo "CPU_VERIFY_ERRORS=$VERIFY_ERRS"
echo "CPU_THROTTLE_EVENTS=$THROTTLE"; echo "CPU_MAX_TEMP_C=${MAXT:-0}"
[ -n "${BOGO:-}" ] && echo "CPU_BOGO_OPS=$BOGO"
case "$outcome" in
    completed|timeout)
        if [ "$VERIFY_ERRS" -gt 0 ]; then echo "CPU_RESULT=fail"; echo "CPU_NOTES=computation verification errors under load"
        else echo "CPU_RESULT=pass"; fi ;;
    aborted) echo "CPU_RESULT=aborted"; echo "CPU_NOTES=watchdog/user abort — see thermal data" ;;
    crashed) echo "CPU_RESULT=fail"; echo "CPU_NOTES=stressor exited abnormally (rc=$rc) — instability under load" ;;
esac
} >> "$ENV"

# quick benchmark (skipped if aborted)
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
ok "CPU test done: $(grep CPU_RESULT "$ENV" | cut -d= -f2)"
