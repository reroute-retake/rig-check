#!/usr/bin/env bash
# RigCheck — userspace RAM test. Sizes itself to available memory with headroom
# (8GB-machine friendly). memtester preferred; pure-python fallback otherwise.
# True 100% coverage requires the Memtest86+ boot entry (noted in report).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ENV="$RUN/ram.env"; LOGF="$RUN/ram.log"

avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo); avail_mb=$((avail_kb/1024))
HEADROOM=1500
max_safe=$((avail_mb - HEADROOM))
case "${RAM_WANT_MB:-2048}" in
    pct60) want=$((avail_mb * 60 / 100)) ;;
    max)   want=$((avail_mb - 2048)) ;;
    *)     want=${RAM_WANT_MB} ;;
esac
size=$(( want < max_safe ? want : max_safe ))

{
echo "RAM_AVAIL_MB=$avail_mb"
if [ "$size" -lt 256 ]; then
    warn "Only ${avail_mb}MB available — skipping userspace RAM test (use the Memtest86+ boot entry)"
    echo "RAM_RESULT=skipped"; echo "RAM_NOTES=insufficient free memory (${avail_mb}MB avail); use Memtest86+ boot entry"
    exit 0
fi
echo "RAM_TESTED_MB=$size"

if has memtester; then
    log "memtester: testing ${size}MB (of ${avail_mb}MB available), ${RAM_LOOPS:-1} loop(s), timeout $((${RAM_TIMEOUT:-900}/60))min" >&2
    outcome=$(run_stress ram "${RAM_TIMEOUT:-900}" "$LOGF" memtester "${size}M" "${RAM_LOOPS:-1}")
    rc=$(cat "$RUN/ram.rc" 2>/dev/null || echo 1)
    fails=$(grep -ciE 'FAILURE' "$LOGF" 2>/dev/null); fails=${fails:-0}
    oks=$(grep -coE ': ok' "$LOGF" 2>/dev/null); oks=${oks:-0}
    echo "RAM_TOOL=memtester"; echo "RAM_ERRORS=$fails"; echo "RAM_CHECKS_OK=$oks"
    case "$outcome" in
        completed) if [ "$rc" -eq 0 ] && [ "$fails" -eq 0 ]; then echo "RAM_RESULT=pass"; else echo "RAM_RESULT=fail"; fi ;;
        timeout)   if [ "$fails" -eq 0 ]; then echo "RAM_RESULT=partial"; echo "RAM_NOTES=time-capped; $oks pattern checks passed, no errors"; else echo "RAM_RESULT=fail"; fi ;;
        aborted)   echo "RAM_RESULT=aborted"; echo "RAM_NOTES=stopped by watchdog/user" ;;
        crashed)   echo "RAM_RESULT=fail"; echo "RAM_NOTES=memtester exited abnormally (rc=$rc) — possible instability" ;;
    esac
else
    log "memtester not found — python fallback pattern test on ${size}MB" >&2
    cat > /tmp/rig_ramtest.py <<'PYEOF'
import os, sys, time, random
size_mb, budget = int(sys.argv[1]), int(sys.argv[2])
CH = 64*1024*1024
n = max(1, (size_mb*1024*1024)//CH)
end = time.time() + budget
errors = checks = 0
blocks = []
try:
    for _ in range(n): blocks.append(bytearray(CH))
except MemoryError:
    print(f"ALLOC_FAILED at {len(blocks)*64}MB"); n = len(blocks)
for pat in (0x00, 0xFF, 0xAA, 0x55):
    if time.time() > end: break
    pb = bytes([pat])*CH
    for b in blocks:
        b[:] = pb
    for i, b in enumerate(blocks):
        if time.time() > end: break
        if bytes(b) != pb: errors += 1; print(f"MISMATCH pattern {pat:#x} block {i}")
        checks += 1
random.seed(42)
if time.time() < end:
    rb = random.randbytes(CH) if hasattr(random,'randbytes') else bytes(random.getrandbits(8) for _ in range(1024))*(CH//1024)
    for b in blocks: b[:] = rb
    for i, b in enumerate(blocks):
        if time.time() > end: break
        if bytes(b) != rb: errors += 1; print(f"MISMATCH random block {i}")
        checks += 1
print(f"DONE tested_mb={n*64} checks={checks} errors={errors}")
sys.exit(1 if errors else 0)
PYEOF
    outcome=$(run_stress ram "${RAM_TIMEOUT:-900}" "$LOGF" python3 /tmp/rig_ramtest.py "$size" "${RAM_TIMEOUT:-900}")
    errors=$(grep -oE 'errors=[0-9]+' "$LOGF" | tail -1 | cut -d= -f2); errors=${errors:-0}
    mism=$(grep -c MISMATCH "$LOGF" 2>/dev/null); mism=${mism:-0}
    [ "$mism" -gt "$errors" ] && errors=$mism
    echo "RAM_TOOL=python-pattern"; echo "RAM_ERRORS=$errors"
    if [ "$errors" -gt 0 ]; then echo "RAM_RESULT=fail"
    elif [ "$outcome" = aborted ]; then echo "RAM_RESULT=aborted"
    elif grep -q DONE "$LOGF"; then echo "RAM_RESULT=pass"
    else echo "RAM_RESULT=partial"; echo "RAM_NOTES=time-capped, no errors found"; fi
fi
} >> "$ENV"
ok "RAM test done: $(grep RAM_RESULT "$ENV" | cut -d= -f2)"
