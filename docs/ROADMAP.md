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

## Phase 2 — Detection & capability probing
Structured JSON inventory (CPU/board/BIOS/DIMMs/drives/GPU/sensors) plus a
capability profile that decides *which* tests apply and *how hard* to push:
gentler on weak/old/8GB machines, heavier on strong ones (more threads,
bigger working sets, longer soaks).

## Phase 3 — Test modules, hardened
- Watchdog: per-sensor thresholds, Tjmax-aware (CPU spec − 5°C), SMART-error
  mid-run detection, PC-speaker beep codes for headless
- RAM: chunked userspace sweeps + first-class reboot-to-Memtest86+ flow
- Storage: extended self-test orchestration, per-drive-class expectations
- CPU: mprime/Linpack-class torture option, per-core error attribution
- GPU: glmark2/vkmark where drivers allow; gpu-burn on CUDA/ROCm

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

## Phase 7 — Custom ISO & CI
archiso (or live-build) profile baking all tools + GRUB menu with Memtest
entry; GitHub Actions builds the hybrid BIOS+UEFI ISO and publishes releases
on tag. Bundled GPU stress tools, optional shim/Secure Boot story, offline
package cache.
