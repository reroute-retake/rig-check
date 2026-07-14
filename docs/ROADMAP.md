# RigCheck roadmap

Phase 0 (shipped in this repo) proves the concept on stock SystemRescue.
Later phases move to a custom, CI-built ISO with deeper tests.

## Phase 0 — Ventoy fast-path ✅
Ventoy 1.1.16 + SystemRescue 13.01 + Memtest86+ 8.10 + bash/python payload.
Tiered tests (coffee/standard/detailed), thermal watchdog with auto-abort,
signed reports, verify script, optional wifi/email/LLM. Defensive tool
fallbacks (stress-ng → stress → python burn; memtester → python patterns;
fio → hdparm → dd) so it runs on whatever the live ISO ships.

## Phase 1 — Project skeleton ✅
This repository: layout, license, docs.

## Phase 2 — Detection & capability probing ✅
Shipped as `payload/lib/detect.py`:
- **`hardware.json`** — structured inventory: CPU (flags like AVX2/AVX-512,
  Spectre/Meltdown mitigation status), DIMMs + ECC, chassis type (laptop
  detection), UEFI/BIOS boot mode, drives with SMART quick-status, GPU with
  driver class (full/basic/none), NICs, sensor chips + their critical limits.
- **`capability.json`** — machine class (weak/mid/strong), effective abort
  temperature derived from the chip's own critical limit (Tjmax − 7, clamped),
  applicable-test flags, per-tier parameters scaled to the machine.
- Scaling philosophy: each tier keeps its wall-clock promise; weak/8GB machines
  get smaller working sets (or a RAM-test skip + Memtest86+ pointer below
  1.8GB free), machines with unreadable temps get shortened stress ("blind
  watchdog" safety), strong machines get bigger sets and longer soaks.
- The orchestrator sources `capability.env`; the profile is embedded in the
  signed report and shown in the HTML.

## Phase 3 — Test modules, hardened ✅
Shipped:
- **Watchdog**: CPU + NVMe + SATA (drivetemp) thresholds; **mid-run SMART delta
  detection** (`smartwatch.py` baselines drives at start, re-checks every ~60s,
  aborts when reallocated/pending sectors or media errors GROW under load);
  PC-speaker beep patterns for headless (start/pass/warn/fail/abort).
- **RAM**: chunked sweeps (default 1GB chunks) with live progress, per-chunk
  time budget, dynamic headroom re-checks, allocation-failure shrink-and-retry,
  aggregate coverage % of physical RAM, multi-loop support in detailed tier.
- **Storage**: self-tests launched on all drives in parallel then polled
  together with completion %; extended tests print the drive's own ETA;
  result read from the self-test log; per-drive-class expectations in rules
  (NVMe/SSD/HDD read floors, class-aware temp limits).
- **CPU**: detailed-tier memory-bus torture stage (stress-ng --matrix --verify);
  on any verification error/crash, a **per-core isolation pass** pins a verified
  stressor to each core (taskset/sched_setaffinity) and reports faulty cores.
Deferred: mprime/gpu-burn (need the custom ISO), reboot-to-Memtest chainload
(GRUB entry arrives in Phase 7).

## Phase 4 — Orchestration & unattended mode
Menu with countdown auto-start (never blocks headless), tier scaling by
capability profile, start/finish notifications, configurable power-off.

## Phase 5 — Setup wizard
`setup.sh`: safe USB selection, boot payload install, config collection
(wifi, mode, email, LLM key, after-test action), per-stick signing key with
owner copy.

## Phase 6 — Reporting & authenticity
JSON source of truth → self-contained HTML (charts) + console summary.
Rule-based pass/fail is authoritative; LLM analysis is an optional layer.

### Report authenticity
Threat model and defenses (all shipped in Phase 0, hardened here):

| Fraud scenario | Defense |
|---|---|
| Edited/fabricated report file | canonical JSON → SHA-256 → HMAC with per-stick key; `verify.py` |
| Replayed old report | challenge nonce (owner-issued at test time) + timestamps |
| Run on a different machine | board/system/drive serials + MACs embedded and signed |
| Modified stick / extracted key | direct-from-session email is the authoritative copy; on-screen fingerprint read-back |

Honest limit: with physical control of stick + machine, a skilled attacker can
defeat local-only measures. TPM 2.0 remote attestation is the real fix —
tracked as a stretch goal (unreliable on pre-2018 consumer boards).

## Phase 7 — Custom ISO & CI ✅
Shipped (see docs/BUILDING.md):
- `iso/build.sh` bases the image on archiso's official **releng** profile
  (hybrid BIOS+UEFI boot, **Memtest86+ menu entries** included) and overlays
  RigCheck: full toolchain baked in (smartmontools, nvme-cli, fio, memtester,
  stress-ng, sysbench, lm_sensors, glmark2 incl. **glmark2-drm** for
  no-X GPU stress on AMD/Intel, NetworkManager), payload at `/opt/rigcheck`,
  auto-start on tty1 via `rigcheck-launch`.
- Package names are validated at build time and skipped with a warning if a
  repo renames one — the build degrades instead of breaking.
- The launcher finds the USB **data partition** (RIGCHECK_DATA label, Ventoy
  partition, or any partition with `rigcheck/rigcheck.conf`), so config and
  reports live on the stick while the image stays read-only.
- `.github/workflows/build-iso.yml`: tag `v*` → CI builds in an Arch
  container → GitHub Release with the ISO + sha256sums. Manual runs produce
  workflow artifacts.
Deferred: NVIDIA proprietary bundling; signed/shim Secure Boot; offline
package cache.
