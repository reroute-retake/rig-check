# Building the RigCheck ISO

The custom ISO bakes the whole toolchain in — no dependence on what a stock
live distro happens to ship: smartmontools, nvme-cli, fio, memtester,
stress-ng, sysbench, lm_sensors, glmark2 (incl. `glmark2-drm` for GPU stress
without X on AMD/Intel), NetworkManager, and the RigCheck payload at
`/opt/rigcheck`. It boots BIOS **and** UEFI and keeps the archiso `releng`
boot menu, which includes a **Memtest86+** entry for full-coverage RAM tests.

## CI (recommended)

Every pushed tag `v*` triggers `.github/workflows/build-iso.yml`, which builds
the ISO in an Arch container and attaches it (plus `sha256sums.txt`) to a
GitHub Release. Manual runs via *Actions → Build RigCheck ISO → Run workflow*
produce a downloadable artifact instead.

Release a version:

```bash
git tag v0.4.0 && git push --tags
```

## Local build (Arch Linux, root)

```bash
pacman -Syu --noconfirm archiso
sudo bash iso/build.sh            # output: out/rigcheck-*.iso + sha256sums.txt
```

Knobs (env vars): `RIGCHECK_VERSION`, `RIGCHECK_OUT_DIR`, `RIGCHECK_WORK_DIR`
(needs ~6GB scratch).

## How the build works

`iso/build.sh` copies the official archiso **releng** profile (proven
BIOS+UEFI+Secure-Boot-shim-less boot plumbing, memtest entries, autologin),
then overlays RigCheck:

1. Branding (`iso_name=rigcheck`, menu title "RigCheck diagnostic")
2. `iso/packages-extra.txt` appended to the package list — each name is
   validated against the repos and skipped with a warning if unknown, so a
   renamed package degrades the image instead of breaking the build
3. `payload/` → `/opt/rigcheck/` (read-only, versioned with the ISO)
4. `iso/airootfs/` overlay: `rigcheck-launch` + tty1 autostart (`.zlogin`)

## How the ISO behaves at boot

1. releng autologin lands on tty1 → `.zlogin` runs **`rigcheck-launch`**
2. The launcher finds the **data partition** — `RIGCHECK_DATA` label, the
   Ventoy partition, or any partition containing `rigcheck/rigcheck.conf` —
   mounts it, and exports `RIGCHECK_CONF` / `RIGCHECK_REPORTS`
3. The suite runs exactly like the Phase 0 payload: preselected mode
   auto-starts after a countdown; reports are written to the data partition
   first, then signed, then emailed
4. Other TTYs (Alt+F2…) stay plain root shells for debugging

## Using the ISO

- **With an existing RigCheck/Ventoy stick (recommended):** copy
  `rigcheck-*.iso` next to the other ISOs. Pick it in the Ventoy menu and boot
  the **copy-to-RAM entry** — Ventoy holds the stick's partition via
  device-mapper while an ISO boots from it, and only a copytoram session can
  release it (`rigcheck-launch` does this automatically). Your existing
  `rigcheck.conf` and `reports/` on the stick keep working. You can delete the
  SystemRescue ISO once you trust the RigCheck one.
- **dd/Etcher:** works (hybrid ISO), but the stick becomes read-only — add a
  partition labeled `RIGCHECK_DATA` (FAT32/exFAT) in the free space after the
  ISO if you want on-stick config/reports, or rely on email delivery.

## Known limitations

- **NVIDIA**: not bundled (proprietary driver size/licensing churn). NVIDIA
  GPUs are detected and reported; stress runs on AMD/Intel (in-kernel drivers).
- **Secure Boot**: the ISO is unsigned. Disable Secure Boot, or use Ventoy
  with its one-time key enrollment.
