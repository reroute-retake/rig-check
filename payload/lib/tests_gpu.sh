#!/usr/bin/env bash
# RigCheck Phase 0 — GPU: detection + driver status (stress testing arrives with
# the custom ISO; NVIDIA needs the proprietary driver that stock live ISOs lack).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ENV="$RUN/gpu.env"; : > "$ENV"

GPUS=$(lspci -nnk 2>/dev/null | grep -iE 'vga|3d controller|display controller' || true)
if [ -z "$GPUS" ]; then
    echo "GPU_COUNT=0" >> "$ENV"; log "No GPU found via lspci"; exit 0
fi
echo "GPU_COUNT=$(echo "$GPUS" | wc -l)" >> "$ENV"
lspci -nnk 2>/dev/null | grep -iA3 -E 'vga|3d controller|display controller' > "$RUN/raw/gpu_lspci.txt" || true

has vulkaninfo && capture vulkaninfo.txt vulkaninfo --summary
has clinfo     && capture clinfo.txt     clinfo -l
[ -n "${DISPLAY:-}" ] && has glxinfo && capture glxinfo.txt glxinfo -B

# prefer glmark2-drm: renders directly on KMS, no X needed (ships on the RigCheck ISO)
DRIVER_OK=$(lspci -nnk 2>/dev/null | grep -A3 -iE 'vga|3d controller' | grep -cE 'Kernel driver in use: (i915|xe|amdgpu|radeon)' || true)
if [ -z "${DISPLAY:-}" ] && has glmark2-drm && [ "${DRIVER_OK:-0}" -gt 0 ] && [ ! -f "$RUN/ABORT" ]; then
    log "Running glmark2-drm (KMS — screen will show the benchmark for ~2 min)..."
    outcome=$(run_stress gpu 240 "$RUN/glmark2.log" glmark2-drm -b build -b texture -b shading)
    SCORE=$(grep -oE 'Score: *[0-9]+' "$RUN/glmark2.log" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    { echo "GPU_TEST=glmark2-drm"; echo "GPU_TEST_OUTCOME=$outcome"
      [ -n "${SCORE:-}" ] && echo "GPU_SCORE=$SCORE"; } >> "$ENV"
elif [ -n "${DISPLAY:-}" ] && has glmark2 && [ ! -f "$RUN/ABORT" ]; then
    log "Running short glmark2..."
    outcome=$(run_stress gpu 180 "$RUN/glmark2.log" glmark2 -b build -b texture -b shading)
    SCORE=$(grep -oE 'Score: *[0-9]+' "$RUN/glmark2.log" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    { echo "GPU_TEST=glmark2"; echo "GPU_TEST_OUTCOME=$outcome"
      [ -n "${SCORE:-}" ] && echo "GPU_SCORE=$SCORE"; } >> "$ENV"
else
    { echo "GPU_TEST=detect-only"
      echo "GPU_NOTES=no stress-capable GPU driver / glmark2 in this environment (full support on the RigCheck ISO for AMD/Intel)"; } >> "$ENV"
fi
ok "GPU: detection captured"
