#!/usr/bin/env bash
# RigCheck ISO builder — run as root on Arch Linux (or the CI container).
#   pacman -Syu --noconfirm archiso && bash iso/build.sh
#
# Strategy: start from archiso's official 'releng' profile (proven BIOS+UEFI
# boot plumbing, includes Memtest86+ boot entries), then overlay RigCheck:
# extra packages, the payload at /opt/rigcheck, an auto-launcher on tty1,
# and RigCheck branding. Output: out/rigcheck-<ver>-x86_64.iso + sha256.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${RIGCHECK_PROFILE_DIR:-/tmp/rigcheck-profile}"
WORK="${RIGCHECK_WORK_DIR:-/tmp/rigcheck-work}"
OUT="${RIGCHECK_OUT_DIR:-$REPO_DIR/out}"
VER="${RIGCHECK_VERSION:-dev}"

msg() { printf '\033[1;36m[iso-build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[iso-build error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root (mkarchiso requirement)"
command -v mkarchiso >/dev/null || die "archiso not installed (pacman -S archiso)"
[ -d /usr/share/archiso/configs/releng ] || die "releng profile not found"

msg "Preparing profile at $PROFILE (base: releng)"
rm -rf "$PROFILE" "$WORK"
cp -r /usr/share/archiso/configs/releng "$PROFILE"

# ---------------------------------------------------------------- identity
sed -i 's/^iso_name=.*/iso_name="rigcheck"/' "$PROFILE/profiledef.sh"
sed -i "s/^iso_label=.*/iso_label=\"RIGCHECK_$(date +%Y%m)\"/" "$PROFILE/profiledef.sh"
sed -i 's|^iso_publisher=.*|iso_publisher="RigCheck <https://github.com/reroute-retake/rig-check>"|' "$PROFILE/profiledef.sh"
sed -i 's/^iso_application=.*/iso_application="RigCheck PC hardware diagnostic"/' "$PROFILE/profiledef.sh"

# ---------------------------------------------------------------- packages
msg "Adding RigCheck packages (validating against repos; unknown ones are dropped with a warning)"
pacman -Sy >/dev/null
while IFS= read -r pkg; do
    [[ "$pkg" =~ ^\s*(#|$) ]] && continue
    pkg="$(echo "$pkg" | xargs)"
    if pacman -Si "$pkg" >/dev/null 2>&1; then
        echo "$pkg" >> "$PROFILE/packages.x86_64"
    else
        msg "WARNING: package '$pkg' not found in repos — skipped"
    fi
done < "$REPO_DIR/iso/packages-extra.txt"
sort -u -o "$PROFILE/packages.x86_64" "$PROFILE/packages.x86_64"

# ---------------------------------------------------------------- payload + overlay
msg "Installing RigCheck payload into airootfs"
mkdir -p "$PROFILE/airootfs/opt/rigcheck"
cp -r "$REPO_DIR/payload/." "$PROFILE/airootfs/opt/rigcheck/"
rm -f "$PROFILE/airootfs/opt/rigcheck/rigcheck.conf"   # conf comes from the USB data partition, never the image
cp "$REPO_DIR/verify.py" "$PROFILE/airootfs/opt/rigcheck/"
cp -r "$REPO_DIR/iso/airootfs/." "$PROFILE/airootfs/"
echo "$VER" > "$PROFILE/airootfs/opt/rigcheck/ISO_VERSION"
chmod 755 "$PROFILE/airootfs/usr/local/bin/rigcheck-launch" \
          "$PROFILE/airootfs/opt/rigcheck/rigcheck.sh" 2>/dev/null || true
find "$PROFILE/airootfs/opt/rigcheck/lib" -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true

# ---------------------------------------------------------------- branding in boot menus
sed -i 's/Arch Linux install medium/RigCheck diagnostic/g' \
    "$PROFILE"/grub/grub.cfg "$PROFILE"/syslinux/*.cfg "$PROFILE"/efiboot/loader/entries/*.conf 2>/dev/null || true

# ---------------------------------------------------------------- zero-touch boot
# The diagnostic should run itself: short menu timeout, and copytoram on the
# Linux entries so rigcheck-launch can release Ventoy's device-mapper hold on
# the USB stick (needed to read config / write reports). Low-RAM (<4GB)
# machines can still edit the entry (press 'e') and remove 'copytoram'.
msg "Enabling zero-touch boot (timeout 3s, copytoram default)"
sed -i 's/^set timeout=.*/set timeout=3/' "$PROFILE/grub/grub.cfg" 2>/dev/null || true
sed -i '/vmlinuz-linux/s/$/ copytoram/' "$PROFILE/grub/grub.cfg" 2>/dev/null || true
sed -i 's/^TIMEOUT .*/TIMEOUT 30/' "$PROFILE"/syslinux/syslinux.cfg 2>/dev/null || true
sed -i '/^ *APPEND /s/$/ copytoram/' "$PROFILE"/syslinux/archiso_sys*.cfg 2>/dev/null || true

# ---------------------------------------------------------------- build
msg "Building ISO (this takes a while)..."
mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

msg "Checksums"
( cd "$OUT" && sha256sum ./*.iso > sha256sums.txt && cat sha256sums.txt )
msg "Done: $(ls "$OUT"/*.iso)"
