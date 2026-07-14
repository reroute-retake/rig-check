#!/usr/bin/env bash
# RigCheck shared helpers (sourced by all modules)

log()  { printf '\033[1;36m[rigcheck]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
banner(){ printf '\n\033[1;44m  %s  \033[0m\n\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# capture <outfile-basename> <cmd...>   — best-effort raw capture into $RUN/raw/
capture() {
    local out="$RUN/raw/$1"; shift
    "$@" > "$out" 2>&1 || true
}

# run_stress <name> <timeout_s> <logfile> <cmd...>
# Runs cmd in its own process group; kills it on $RUN/ABORT (watchdog/user) or timeout.
# Echoes outcome: completed | timeout | aborted | crashed   (exit code of cmd in $RUN/<name>.rc)
run_stress() {
    local name="$1" tmo="$2" logf="$3"; shift 3
    setsid "$@" > "$logf" 2>&1 &
    local pid=$! start=$(date +%s) outcome=completed
    while kill -0 "$pid" 2>/dev/null; do
        if [ -f "$RUN/ABORT" ]; then
            kill -TERM -- "-$pid" 2>/dev/null; sleep 3; kill -KILL -- "-$pid" 2>/dev/null
            outcome=aborted; break
        fi
        if [ $(( $(date +%s) - start )) -ge "$tmo" ]; then
            kill -TERM -- "-$pid" 2>/dev/null; sleep 3; kill -KILL -- "-$pid" 2>/dev/null
            outcome=timeout; break
        fi
        sleep 1
    done
    wait "$pid" 2>/dev/null; local rc=$?
    echo "$rc" > "$RUN/${name}.rc"
    if [ "$outcome" = "completed" ] && [ "$rc" -ne 0 ]; then outcome=crashed; fi
    echo "$outcome"
}

# max temp helpers (millidegrees) — used by watchdog and tests
cpu_temp_mc() {
    local max=0 t f name hw
    for hw in /sys/class/hwmon/hwmon*; do
        name=$(cat "$hw/name" 2>/dev/null) || continue
        case "$name" in
          coretemp|k10temp|zenpower|cpu_thermal|soc_thermal)
            for f in "$hw"/temp*_input; do
                [ -r "$f" ] || continue
                t=$(cat "$f" 2>/dev/null) || continue
                [ -n "$t" ] && [ "$t" -gt "$max" ] 2>/dev/null && max=$t
            done ;;
        esac
    done
    if [ "$max" -eq 0 ]; then  # fallback: thermal zones
        local z
        for z in /sys/class/thermal/thermal_zone*; do
            case "$(cat "$z/type" 2>/dev/null)" in
              x86_pkg_temp|cpu*|acpitz)
                t=$(cat "$z/temp" 2>/dev/null) || continue
                [ -n "$t" ] && [ "$t" -gt "$max" ] 2>/dev/null && max=$t ;;
            esac
        done
    fi
    echo "$max"
}
nvme_temp_mc() {
    local max=0 t f hw
    for hw in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$hw/name" 2>/dev/null)" = "nvme" ] || continue
        for f in "$hw"/temp*_input; do
            [ -r "$f" ] || continue
            t=$(cat "$f" 2>/dev/null) || continue
            [ -n "$t" ] && [ "$t" -gt "$max" ] 2>/dev/null && max=$t
        done
    done
    echo "$max"
}
sata_temp_mc() {  # SATA/USB drive temps via the drivetemp hwmon driver
    local max=0 t f hw
    for hw in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$hw/name" 2>/dev/null)" = "drivetemp" ] || continue
        for f in "$hw"/temp*_input; do
            [ -r "$f" ] || continue
            t=$(cat "$f" 2>/dev/null) || continue
            [ -n "$t" ] && [ "$t" -gt "$max" ] 2>/dev/null && max=$t
        done
    done
    echo "$max"
}

# PC-speaker beeps for headless runs (best-effort; silent when unsupported)
beep_init() { [ "${BEEP:-yes}" = "yes" ] && modprobe pcspkr 2>/dev/null || true; }
beep_pattern() { # <count> [duration_ms]
    [ "${BEEP:-yes}" = "yes" ] || return 0
    local n=${1:-1} d=${2:-150} i
    if command -v beep >/dev/null 2>&1; then
        for ((i=0; i<n; i++)); do beep -l "$d" 2>/dev/null || true; sleep 0.15; done
    else
        for ((i=0; i<n; i++)); do { printf '\a' > /dev/tty0; } 2>/dev/null || printf '\a' 2>/dev/null || true; sleep 0.3; done
    fi
    return 0
}
