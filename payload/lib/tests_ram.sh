#!/usr/bin/env bash
# RigCheck — userspace RAM test (Phase 3: chunked sweeps).
# Splits the target into chunks (default 1GB) tested sequentially inside the
# time budget: lower OOM risk, live progress, and page-reuse between chunks
# improves coverage odds. Aggregates errors + coverage across chunks/loops.
# True 100% coverage still requires the Memtest86+ boot entry (noted in report).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ENV="$RUN/ram.env"; LOGF="$RUN/ram.log"; : > "$LOGF"

if [ "${SKIP_RAM:-0}" = "1" ]; then
    warn "capability probe: too little free RAM for a meaningful userspace test — skipping (use the Memtest86+ boot entry)"
    { echo "RAM_RESULT=skipped"; echo "RAM_NOTES=skipped by capability probe (low free RAM); use Memtest86+ boot entry"; } >> "$ENV"
    exit 0
fi

total_mb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
avail_mb() { echo $(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 )); }
HEADROOM=1500
case "${RAM_WANT_MB:-2048}" in
    pct60) want=$(( $(avail_mb) * 60 / 100 )) ;;
    max)   want=$(( $(avail_mb) - 2048 )) ;;
    *)     want=${RAM_WANT_MB} ;;
esac
max_safe=$(( $(avail_mb) - HEADROOM ))
target=$(( want < max_safe ? want : max_safe ))
if [ "$target" -lt 256 ]; then
    warn "only $(avail_mb)MB available — skipping userspace RAM test (use the Memtest86+ boot entry)"
    { echo "RAM_RESULT=skipped"; echo "RAM_NOTES=insufficient free memory; use Memtest86+ boot entry"; } >> "$ENV"
    exit 0
fi

CHUNK=${RAM_CHUNK_MB:-1024}
[ "$CHUNK" -gt "$target" ] && CHUNK=$target
LOOPS=${RAM_LOOPS:-1}
DEADLINE=$(( $(date +%s) + ${RAM_TIMEOUT:-900} ))
TOOL="memtester"; has memtester || TOOL="python-pattern"

# python fallback chunk tester (verifies fixed + random patterns)
cat > /tmp/rig_ramchunk.py <<'PYEOF'
import random, sys, time
size_mb, budget = int(sys.argv[1]), float(sys.argv[2])
CH = 64*1024*1024
n = max(1, (size_mb*1024*1024)//CH)
end = time.time() + budget
errors = checks = 0
blocks = []
try:
    for _ in range(n): blocks.append(bytearray(CH))
except MemoryError:
    n = len(blocks); print(f"ALLOC_SHORT at {n*64}MB", flush=True)
pats = [b"\x00"*CH, b"\xff"*CH, b"\xaa"*CH, b"\x55"*CH]
random.seed(42)
rnd = (random.randbytes(1024) if hasattr(random, "randbytes") else bytes(random.getrandbits(8) for _ in range(1024))) * (CH//1024)
for pb in pats + [rnd]:
    if time.time() > end: break
    for b in blocks: b[:] = pb
    for i, b in enumerate(blocks):
        if time.time() > end: break
        if bytes(b) != pb: errors += 1; print(f"MISMATCH block {i}", flush=True)
        checks += 1
print(f"CHUNKDONE tested_mb={n*64} checks={checks} errors={errors}", flush=True)
sys.exit(1 if errors else 0)
PYEOF

log "RAM sweep: target ${target}MB of ${total_mb}MB total, ${CHUNK}MB chunks, ${LOOPS} loop(s), tool: $TOOL"
tested=0; errors=0; chunks_done=0; loops_done=0; partial=0
for (( loop=1; loop<=LOOPS; loop++ )); do
    covered=0
    while [ "$covered" -lt "$target" ]; do
        [ -f "$RUN/ABORT" ] && break 2
        now=$(date +%s); left=$(( DEADLINE - now ))
        [ "$left" -lt 45 ] && { partial=1; break 2; }
        # re-check live headroom before each chunk (other tests / kernel may take RAM)
        safe_now=$(( $(avail_mb) - HEADROOM ))
        this=$CHUNK
        [ $(( target - covered )) -lt "$this" ] && this=$(( target - covered ))
        [ "$this" -gt "$safe_now" ] && this=$safe_now
        [ "$this" -lt 128 ] && { partial=1; warn "  free RAM shrank — stopping sweep early"; break 2; }

        if [ "$TOOL" = "memtester" ]; then
            outcome=$(run_stress ram_chunk "$left" "$RUN/ram_chunk.log" memtester "${this}M" 1)
            rc=$(cat "$RUN/ram_chunk.rc" 2>/dev/null || echo 1)
            cat "$RUN/ram_chunk.log" >> "$LOGF"
            f=$(grep -ciE 'FAILURE' "$RUN/ram_chunk.log" 2>/dev/null); f=${f:-0}
        else
            outcome=$(run_stress ram_chunk "$left" "$RUN/ram_chunk.log" python3 /tmp/rig_ramchunk.py "$this" "$left")
            rc=$(cat "$RUN/ram_chunk.rc" 2>/dev/null || echo 1)
            cat "$RUN/ram_chunk.log" >> "$LOGF"
            f=$(grep -c MISMATCH "$RUN/ram_chunk.log" 2>/dev/null); f=${f:-0}
        fi
        errors=$(( errors + f ))
        case "$outcome" in
            completed)
                covered=$(( covered + this )); chunks_done=$(( chunks_done + 1 ))
                [ "$loop" -eq 1 ] && tested=$covered
                log "  chunk ${chunks_done} ok: ${covered}/${target}MB (loop $loop/$LOOPS)$( [ "$f" -gt 0 ] && echo "  ERRORS:$f" )" ;;
            timeout) partial=1; break 2 ;;
            aborted) break 2 ;;
            crashed)
                # allocation failure isn't a RAM fault; shrink and retry once smaller
                if grep -qiE 'alloc|cannot|mlock' "$RUN/ram_chunk.log" 2>/dev/null && [ "$CHUNK" -gt 256 ]; then
                    CHUNK=$(( CHUNK / 2 )); warn "  chunk allocation failed — retrying with ${CHUNK}MB chunks"
                else
                    errors=$(( errors + 1 )); partial=1; break 2
                fi ;;
        esac
    done
    loops_done=$loop
done

cov_pct=$(( tested * 100 / (total_mb > 0 ? total_mb : 1) ))
{
echo "RAM_TOOL=$TOOL"; echo "RAM_TOTAL_MB=$total_mb"; echo "RAM_TARGET_MB=$target"
echo "RAM_TESTED_MB=$tested"; echo "RAM_CHUNKS_DONE=$chunks_done"; echo "RAM_LOOPS_DONE=$loops_done"
echo "RAM_COVERAGE_PCT=$cov_pct"; echo "RAM_ERRORS=$errors"
if [ -f "$RUN/ABORT" ] && [ "$errors" -eq 0 ]; then
    echo "RAM_RESULT=aborted"; echo "RAM_NOTES=stopped by watchdog/user after ${tested}MB"
elif [ "$errors" -gt 0 ]; then
    echo "RAM_RESULT=fail"
elif [ "$partial" -eq 1 ]; then
    echo "RAM_RESULT=partial"; echo "RAM_NOTES=time-capped at ${tested}MB of ${target}MB target, no errors"
else
    echo "RAM_RESULT=pass"
fi
} >> "$ENV"
ok "RAM sweep done: $(grep RAM_RESULT "$ENV" | cut -d= -f2) (${tested}MB ≈ ${cov_pct}% of physical RAM, $errors errors)"
