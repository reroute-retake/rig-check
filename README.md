# RigCheck

[![Latest release](https://img.shields.io/github/v/release/reroute-retake/rig-check?label=release&color=2ea44f)](https://github.com/reroute-retake/rig-check/releases/latest)
[![ISO build](https://img.shields.io/github/actions/workflow/status/reroute-retake/rig-check/build-iso.yml?label=ISO%20build)](https://github.com/reroute-retake/rig-check/actions/workflows/build-iso.yml)
[![Downloads](https://img.shields.io/github/downloads/reroute-retake/rig-check/total?label=downloads&color=blue)](https://github.com/reroute-retake/rig-check/releases)
[![Platform](https://img.shields.io/badge/platform-x86--64%20·%20BIOS%20%2B%20UEFI-informational)](#honest-limits)
[![License](https://img.shields.io/github/license/reroute-retake/rig-check)](LICENSE)

**Boot any PC from USB → identify every component → run safety-guarded hardware tests →
get a tamper-evident report.** For checking used PCs before buying, diagnosing flaky
machines, and burn-in testing builds — including **headless** machines (no monitor or
keyboard) and old hardware. 8 GB-RAM friendly; tests scale themselves to the machine.

## 📥 Get it

**Easiest — one command builds a zero-touch stick:**

```bash
git clone https://github.com/reroute-retake/rig-check.git && cd rig-check
bash make-usb.sh
```

It downloads the [latest ISO](https://github.com/reroute-retake/rig-check/releases/latest)
(~1.7 GB, BIOS + UEFI hybrid), installs Ventoy, walks you through one-time settings
(test mode, wifi, email, AI key), generates your signing key, and configures
**hands-off boot**.

Then on the PC to test: **power on → boot-menu key (F12/F11/ESC) → pick the USB.
That's it.** No menus, no typing — RigCheck auto-boots in seconds, reads the stick's
config, runs the tests, saves the signed report to the stick, and emails it to you.
Set "USB first" once in BIOS and it's true plug-and-power-on for headless machines.

**Manual alternative:** grab the ISO from [Releases](https://github.com/reroute-retake/rig-check/releases/latest)
(verify with `sha256sums.txt`) and drop it on your own Ventoy stick — add
`ventoy/ventoy.json` for auto-boot and a `rigcheck/rigcheck.conf`
([template](payload/rigcheck.conf.example)); details in [docs/BUILDING.md](docs/BUILDING.md).
Zero-touch boot needs ISO **v0.4.1+** and ~4 GB RAM on the target (the ISO runs from
RAM so it can free the USB stick for config/reports).

## What a run looks like

```text
──── Detected hardware ────
  CPU      Intel(R) Core(TM) i7-8550U CPU @ 1.80GHz  (4c/8t, AVX2)
  RAM      7.7GB total, 6400MB free  [8 GB DDR4@2400 MT/s]
  Drive    /dev/nvme0n1  SK hynix PC401  512.1GB  [nvme, SMART ok]
  GPU      Intel UHD Graphics 620  [driver: i915, full]
  Sensors  coretemp, nvme, acpitz  → abort at 93°C

Class: MID — 8 threads / 7.7GB RAM; NVMe present
  coffee tier scaled: RAM test 1920MB, CPU stress 5min, disk bench 40s

================ RigCheck summary ================
  Overall: PASS   mode=coffee  duration=15min
  Fingerprint: 0b49d42a069c  (read this out to the owner if asked)

  PASS  RAM      2048MB tested clean; full coverage needs Memtest86+ boot entry
  PASS  CPU      stable for 5 min on 8 threads, peak 85°C, no throttling
  PASS  Storage  /dev/nvme0n1: healthy (self-test passed, 1450MB/s seq read)
  PASS  System   max CPU 85°C / max drive 50°C; no hardware errors in kernel log
==================================================
```

…plus a self-contained `report.html` (temperature chart, DIMM/drive serials, benchmark
scores) and machine-readable `report.json`, both written to the USB stick and optionally
emailed to you.

## Features

- 🔍 **Deep identification** — CPU features & mitigation status, per-DIMM details + ECC,
  board/BIOS with serials, drives + SMART health, GPU driver class, NICs, sensor limits
- 📏 **Capability-scaled tests** — weak/mid/strong machine classing adjusts working sets
  and durations; low-RAM systems skip safely toward Memtest86+; sensor-blind systems get
  shortened stress
- ☕ **Three tiers** — coffee (~15 min smoke test) · standard (~40 min) · detailed
  (hours: SMART extended, multi-pass RAM, CPU torture)
- 🛡️ **Safety watchdog** — CPU/NVMe/SATA temperature auto-abort (Tjmax-aware), **mid-run
  SMART-error abort** (drive degrading under load), Ctrl-C graceful stop, headless beeps
- 🎯 **Per-core fault attribution** — verification errors trigger an isolation pass that
  names the faulty core(s)
- 🔏 **Tamper-evident reports** — per-stick HMAC signing, challenge nonce, hardware-serial
  binding; validate anything you're handed with one `verify.py` command
- 📶 **Headless & connected** — auto-start with countdown, ethernet-first networking with
  phone-hotspot fallback, start/finish notifications, emailed reports, optional power-off
- 🤖 **Optional AI triage** — plain-language analysis via API key; rule-based pass/fail
  always works fully offline
- 🧯 **Strictly non-destructive** — SMART self-tests run inside the drive, benchmarks are
  read-only, RAM tests use only free memory

## Test tiers

| Tier | Time | Honest signal |
|---|---|---|
| **coffee** | ~15 min | smoke test: gross RAM errors, dying drives (SMART), obvious thermal/instability |
| **standard** | ~40 min | solid confidence check for buy/keep decisions |
| **detailed** | hours | burn-in: SMART extended self-tests, near-full free-RAM sweeps, 1 h+ CPU torture |

For **100 % RAM coverage** reboot into the **Memtest86+** entry in the boot menu —
userspace tests physically cannot reach memory the OS occupies.

## Create a USB from the repo

```bash
git clone https://github.com/reroute-retake/rig-check.git && cd rig-check
bash make-usb.sh
```

Linux host; needs `sudo`, `curl`/`wget`, `unzip`, ~2.5 GB free (checked at start; relocate
downloads with `RIGCHECK_DL=/path`). The wizard wipes the chosen stick only after an
explicit `YES`, installs Ventoy + SystemRescue + Memtest86+ + the payload, walks through
optional settings, and generates a per-stick **signing key** (kept in `~/.rigcheck/keys/`).

The wizard prefers the RigCheck ISO (zero-touch). If it isn't downloadable
(`RIGCHECK_USE_SYSRESCUE=1` forces this too), it falls back to **SystemRescue +
Memtest86+**, which needs manual steps on the test PC: boot the
**"copy system to RAM (copytoram)"** entry, then at the root shell:

```bash
umount /run/archiso/bootmnt; dmsetup remove ventoy
mount -L Ventoy /mnt && bash /mnt/rigcheck/rigcheck.sh
```

## Verifying a report

```bash
python3 verify.py report.json --key-file ~/.rigcheck/keys/<stick-id>.key
```

Valid = unmodified and signed by *your* stick. Cross-check the embedded board/drive
serials against the physical machine; issue a challenge nonce at test time
(`CHALLENGE_NONCE` / `NONCE_PROMPT='yes'`) to defeat replays. Threat model:
[docs/ROADMAP.md](docs/ROADMAP.md#report-authenticity).

## Safety

The watchdog samples temperatures every 2 s and aborts stress at 95 °C CPU / 82 °C NVMe /
70 °C SATA (auto-tightened below the chip's own critical limit; configurable). SMART
counters are re-checked every ~60 s mid-run. **Ctrl-C** always stops gracefully and still
writes a partial report. Storage tests never write to the machine's drives.

## Honest limits

- **NVIDIA**: detected, not stress-tested (proprietary driver not bundled); AMD/Intel get
  real GPU stress via `glmark2-drm` (no X needed)
- **PSU**: no software can truly test one — rails reported where sensors exist,
  instability under combined load is flagged
- **Secure Boot**: unsigned ISO — disable it or use Ventoy's one-time key enrollment
- Old CPUs (Intel 7th/8th gen etc.): fully supported; benchmark scores reflect
  Spectre/Meltdown mitigations — compare within CPU class

## Troubleshooting

- Stick won't boot → check boot-menu key, disable Secure Boot, try a USB 2.0 port on old boards
- No wifi on a desktop → plug ethernet, or run offline: the report stays on the stick
- Hotspot invisible → enable 2.4 GHz on the phone; set `WIFI_COUNTRY`
- `mount -L Ventoy` fails with **"Can't open blockdev"** → Ventoy still holds the stick;
  you booted without copy-to-RAM. Reboot → pick the **copytoram** entry → run
  `umount /run/archiso/bootmnt; dmsetup remove ventoy` before mounting

## More

- 🏗️ [Building the ISO](docs/BUILDING.md) — CI pipeline, local builds, boot behavior
- 🗺️ [Roadmap & architecture](docs/ROADMAP.md) — what shipped per phase, what's deferred
- 🤝 Issues and PRs welcome — [MIT](LICENSE) licensed

Standing on the shoulders of: archiso, Memtest86+, Ventoy, SystemRescue, smartmontools,
nvme-cli, fio, stress-ng, memtester, lm_sensors, glmark2.
