#!/usr/bin/env bash
# RigCheck Phase 0 — main orchestrator. Run as root on a booted SystemRescue:
#   mount -L Ventoy /mnt && bash /mnt/rigcheck/rigcheck.sh
set -uo pipefail

export RIGDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB="$RIGDIR/lib"
. "$LIB/common.sh"

VERSION="0.3.0"
[ "$(id -u)" = "0" ] || die "Run as root (SystemRescue default shell is root)."
has python3 || die "python3 not found — is this really SystemRescue?"

# ------------------------------------------------------------ config
CONF="$RIGDIR/rigcheck.conf"
[ -f "$CONF" ] && . "$CONF"
MODE="${MODE:-ask}"; ABORT_TEMP_C="${ABORT_TEMP_C:-95}"; NVME_ABORT_TEMP_C="${NVME_ABORT_TEMP_C:-82}"
DISK_ABORT_TEMP_C="${DISK_ABORT_TEMP_C:-70}"; BEEP="${BEEP:-yes}"
AFTER_TEST="${AFTER_TEST:-stay}"
PRESELECTED=0; [ "$MODE" != "ask" ] && PRESELECTED=1
export DISK_ABORT_TEMP_C BEEP

banner "RigCheck $VERSION — PC hardware diagnostic"
beep_init; beep_pattern 2 120 &

# ------------------------------------------------------------ run dir (prefer USB so report survives)
RUN_PARENT="$RIGDIR/reports"
mkdir -p "$RUN_PARENT" 2>/dev/null
if ! touch "$RUN_PARENT/.rw_test" 2>/dev/null; then
    warn "USB not writable — falling back to /root/rigcheck-reports (copy or email the report before shutdown!)"
    RUN_PARENT="/root/rigcheck-reports"; mkdir -p "$RUN_PARENT"
else rm -f "$RUN_PARENT/.rw_test"; fi
export RUN="$RUN_PARENT/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN/raw"
log "Run directory: $RUN"

# ------------------------------------------------------------ mode selection
choose_menu() {
    echo; echo "  1) coffee    (~15 min)  quick smoke test"
    echo "  2) standard  (~40 min)  good confidence check"
    echo "  3) detailed  (hours)    burn-in / acceptance"
    echo "  4) quit"
    local sel=""
    read -rt 60 -p "Choose [1-4] (auto-selects 'standard' in 60s): " sel || true
    case "${sel:-2}" in 1) MODE=coffee;; 3) MODE=detailed;; 4) exit 0;; *) MODE=standard;; esac
}
if [ "$MODE" = "ask" ]; then
    if [ -t 0 ]; then choose_menu; else MODE=standard; log "No TTY; defaulting to standard"; fi
else
    log "Preselected mode: $MODE — starting in 10s (press M for menu, Ctrl-C to abort)"
    k=""; read -rt 10 -n1 k 2>/dev/null || true
    [ "${k,,}" = "m" ] && choose_menu
fi
case "$MODE" in coffee|standard|detailed) ;; *) MODE=standard;; esac
log "Mode: $MODE"

# ------------------------------------------------------------ tier parameters
case "$MODE" in
  coffee)   export RAM_WANT_MB=2048  RAM_TIMEOUT=420  RAM_LOOPS=1 CPU_SECS=300  FIO_SECS=40  SMART_KIND=short BENCH=quick TORTURE=0 ;;
  standard) export RAM_WANT_MB=pct60 RAM_TIMEOUT=900  RAM_LOOPS=1 CPU_SECS=720  FIO_SECS=90  SMART_KIND=short BENCH=full  TORTURE=0 ;;
  detailed) export RAM_WANT_MB=max   RAM_TIMEOUT=5400 RAM_LOOPS=4 CPU_SECS=3600 FIO_SECS=240 SMART_KIND=long  BENCH=full  TORTURE=1 ;;
esac
export ABORT_TEMP_C NVME_ABORT_TEMP_C MODE

# ------------------------------------------------------------ nonce (report freshness for 3rd-party runs)
if [ "${NONCE_PROMPT:-no}" = "yes" ] && [ -z "${CHALLENGE_NONCE:-}" ] && [ -t 0 ]; then
    read -rt 60 -p "Challenge code from the owner (Enter to skip): " CHALLENGE_NONCE || true
fi

# ------------------------------------------------------------ meta + traps
START_TS=$(date +%s)
{   echo "RIG_VERSION=$VERSION"; echo "MODE=$MODE"; echo "START_TS=$START_TS"
    echo "START_UTC=$(date -u +%FT%TZ)"; echo "CHALLENGE_NONCE=${CHALLENGE_NONCE:-}"
    echo "ABORT_TEMP_C=$ABORT_TEMP_C"
} > "$RUN/meta.env"

ABORTED_BY_USER=0
on_int() {
    if [ "$ABORTED_BY_USER" = "0" ]; then
        ABORTED_BY_USER=1; touch "$RUN/ABORT"; echo "USER" > "$RUN/abort_reason" 2>/dev/null
        warn "Ctrl-C — stopping tests gracefully, a partial report will be generated (Ctrl-C again to hard-exit)."
    else warn "Hard exit."; kill 0; exit 130; fi
}
trap on_int INT TERM

# ------------------------------------------------------------ detection + capability probing
step "1/6 Hardware detection & capability probing"
bash "$LIB/detect.sh" || warn "detection had non-fatal errors"
if python3 "$LIB/detect.py" "$RUN" "$MODE" "$ABORT_TEMP_C"; then
    if [ -f "$RUN/capability.env" ]; then
        . "$RUN/capability.env"
        export RAM_WANT_MB RAM_TIMEOUT RAM_LOOPS CPU_SECS FIO_SECS SMART_KIND ABORT_TEMP_C SKIP_RAM
        echo "ABORT_TEMP_C=$ABORT_TEMP_C" >> "$RUN/meta.env"
        log "Capability profile applied (class: ${MACHINE_CLASS:-unknown}) — test intensity scaled to this machine"
    fi
else
    warn "capability probing failed — using default tier parameters"
fi

# ------------------------------------------------------------ network (best-effort) + start notification
bash "$LIB/net.sh" || true
ONLINE=0; [ -f "$RUN/online" ] && ONLINE=1
if [ "$ONLINE" = "1" ] && [ -n "${EMAIL_TO:-}" ]; then
    python3 "$LIB/report.py" notify-start "$CONF" "$RUN" || warn "start notification failed (continuing)"
fi

# ------------------------------------------------------------ watchdog (thermal + mid-run SMART deltas)
step "2/6 Starting watchdog (abort: CPU ${ABORT_TEMP_C}°C / NVMe ${NVME_ABORT_TEMP_C}°C / disk ${DISK_ABORT_TEMP_C}°C / new SMART errors)"
python3 "$LIB/smartwatch.py" baseline "$RUN" || warn "SMART baseline unavailable (mid-run drive monitoring disabled)"
bash "$LIB/watchdog.sh" & WD_PID=$!
sleep 1

# ------------------------------------------------------------ tests
step "3/6 Storage tests (read-only + in-drive SMART self-tests)"
[ -f "$RUN/ABORT" ] || bash "$LIB/tests_storage.sh" main || warn "storage module error"

step "4/6 RAM test (userspace — for 100% coverage use the Memtest86+ boot entry)"
[ -f "$RUN/ABORT" ] || bash "$LIB/tests_ram.sh" || warn "RAM module error"

step "5/6 CPU stress + benchmark"
[ -f "$RUN/ABORT" ] || bash "$LIB/tests_cpu.sh" || warn "CPU module error"

step "6/6 GPU detection"
bash "$LIB/tests_gpu.sh" || warn "GPU module error"

# detailed mode: wait for SMART long tests kicked off earlier
if [ "$SMART_KIND" = "long" ] && [ -f "$RUN/longtest.list" ] && [ ! -f "$RUN/ABORT" ]; then
    step "Waiting for SMART extended self-tests to finish (this is the long part — Ctrl-C keeps partial results)"
    bash "$LIB/tests_storage.sh" collect || true
fi

# ------------------------------------------------------------ wrap up
kill "$WD_PID" 2>/dev/null; wait "$WD_PID" 2>/dev/null
dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -300 > "$RUN/raw/dmesg_err.txt" || dmesg 2>/dev/null | tail -300 > "$RUN/raw/dmesg_err.txt" || true
END_TS=$(date +%s)
{   echo "END_TS=$END_TS"; echo "DURATION_S=$((END_TS-START_TS))"
    [ -f "$RUN/ABORT" ] && echo "ABORTED=1" && echo "ABORT_REASON=$(cat "$RUN/abort_reason" 2>/dev/null || echo unknown)"
} >> "$RUN/meta.env"

step "Generating report"
python3 "$LIB/report.py" finalize "$CONF" "$RUN"; RC=$?

sync
echo
log "Files: $RUN/report.json  +  report.html  (open the HTML on any machine)"
[ "$RUN_PARENT" = "$RIGDIR/reports" ] && log "They are ON THE USB STICK — safe to power off after this message."
if grep -qE 'RAM_RESULT=(partial|skipped)' "$RUN/ram.env" 2>/dev/null || [ "$MODE" = "detailed" ]; then
    log "TIP: for 100% RAM coverage, reboot and pick the Memtest86+ entry in the Ventoy menu."
fi
case "$RC" in 0) beep_pattern 2 200 & ;; 1) beep_pattern 3 200 & ;; *) beep_pattern 5 300 & ;; esac

if [ "$AFTER_TEST" = "poweroff" ] && [ "$PRESELECTED" = "1" ]; then
    warn "Powering off in 20s (AFTER_TEST=poweroff). Ctrl-C to cancel."
    sleep 20 && { sync; poweroff; }
fi
exit $RC
