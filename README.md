# RigCheck

**A bootable USB stick that health-checks any PC.** Boot from it, and RigCheck
identifies every component (CPU, motherboard, BIOS, RAM DIMMs, drives, GPU, NICs —
with serial numbers), runs tiered hardware tests under a thermal-safety watchdog,
and produces a **signed JSON + HTML report** — shown on screen, saved to the stick,
and optionally emailed to you with AI-assisted analysis.

Built for real-world situations: checking a used PC before buying, diagnosing a
flaky machine, burn-in testing new builds — including **headless** machines
(no monitor/keyboard) and old hardware (BIOS or UEFI, 8GB-RAM friendly).

## Status

| Phase | What | State |
|---|---|---|
| 0 | Ventoy + SystemRescue + script payload (this repo, works today) | ✅ shipped |
| 1 | GitHub project skeleton | ✅ this repo |
| 2 | Structured detection (`hardware.json`) + capability probing that scales test intensity to the machine | ✅ shipped |
| 3–6 | Hardened test modules, setup wizard, hardened unattended mode | 🔜 planned |
| 7 | Custom ISO built by CI, GPU stress, Secure Boot story | 🔜 planned |

See [docs/ROADMAP.md](docs/ROADMAP.md).

## How it works (Phase 0)

```
┌─ USB stick (Ventoy) ─────────────────────────────┐
│  SystemRescue ISO   ← boots the test environment │
│  Memtest86+ ISO     ← full-coverage RAM testing  │
│  rigcheck/          ← test suite + config        │
│    rigcheck.sh, lib/, rigcheck.conf, reports/    │
└──────────────────────────────────────────────────┘
```

Tests are **strictly non-destructive**: SMART self-tests run inside the drive,
disk benchmarks are read-only, RAM tests use only free memory. Nothing on the
target machine's drives is modified.

## Quick start

### 1. Create the USB (Linux)

```bash
git clone https://github.com/reroute-retake/rig-check.git
cd rig-check
bash make-usb.sh
```

Needs: `sudo`, `curl`/`wget`, `unzip`, ~2.5GB free disk, a USB stick (8GB min,
16–32GB recommended), internet on first run (downloads cached in `downloads/`).

The wizard picks the USB drive (explicit `YES` confirmation before wiping),
installs [Ventoy](https://www.ventoy.net), copies
[SystemRescue](https://www.system-rescue.org) + [Memtest86+](https://memtest.org)
and the RigCheck payload, then asks for optional settings:

- **Preselected mode** → the test PC auto-starts after a 10s countdown (headless-friendly)
- **WiFi hotspot** credentials (ethernet is tried first, automatically)
- **Email** via SMTP (Gmail: app password) → report mailed to you
- **Anthropic API key** → optional AI analysis appended to the report
- **After-test action**: stay on, or power off (your headless "done" signal)

It also generates a per-stick **signing key** (`~/.rigcheck/keys/`) so reports can
be verified later.

### 2. Test a PC

1. Plug in → power on → boot-menu key (**F12**/F11/F8/ESC) → USB → **SystemRescue**
2. At the root shell:
   ```bash
   mount -L Ventoy /mnt && bash /mnt/rigcheck/rigcheck.sh
   ```
3. Pick a tier:

| Tier | Time | Signal |
|---|---|---|
| **coffee** | ~15 min | smoke test — gross RAM errors, dying drives (SMART), obvious thermal/instability |
| **standard** | ~40 min | solid confidence check |
| **detailed** | hours | burn-in: SMART extended tests, near-full free-RAM sweep, 1h CPU torture |

For **100% RAM coverage**, reboot into the **Memtest86+** entry (userspace tests
physically cannot reach memory the OS occupies).

4. Report → screen summary + `rigcheck/reports/run-*/report.html` on the stick
   (+ email if configured).

### 3. Verify a received report

If someone else ran the test for you:

```bash
python3 verify.py report.json --key-file ~/.rigcheck/keys/<stick-id>.key
```

Valid = unmodified and signed by *your* stick. The report embeds board/drive
serials and MACs (cross-check against the physical machine) and an optional
**challenge nonce** you issue at test time — together these defeat fabricated,
edited, replayed, or wrong-machine reports. See the threat model in
[docs/ROADMAP.md](docs/ROADMAP.md#report-authenticity).

## Safety

- Watchdog samples temps every 2s; **auto-aborts** stress at 95°C CPU / 82°C NVMe
  (configurable in `rigcheck.conf`)
- **Ctrl-C** = graceful emergency stop, partial report still written
- Storage tests are read-only / in-drive; nothing is written to target drives

## Honest limits (Phase 0)

- **GPU**: detect-only (drivers for GPU stress arrive with the custom ISO; NVIDIA
  needs the proprietary driver stock live ISOs don't ship)
- **PSU**: no software can truly test a PSU — rails are reported where sensors
  expose them; instability under combined load is flagged
- **RAM**: userspace tests cover free memory only — Memtest86+ boot entry is the
  real thing
- **Secure Boot**: disable it, or enroll Ventoy's key once (needs a monitor that
  one time)

## License

[MIT](LICENSE)
