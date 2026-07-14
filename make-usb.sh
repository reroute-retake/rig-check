#!/usr/bin/env bash
# RigCheck Phase 0 — USB creator (run on your Linux PC)
# Creates a bootable diagnostic USB: Ventoy + SystemRescue + Memtest86+ + RigCheck payload.
# WARNING: the selected USB drive will be completely WIPED.
set -uo pipefail

VENTOY_VER="1.1.16"
SYSRESCUE_VER="13.01"
MEMTEST_VER="8.10"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL="${RIGCHECK_DL:-$SCRIPT_DIR/downloads}"   # override download dir: RIGCHECK_DL=/path bash make-usb.sh
PAYLOAD="$SCRIPT_DIR/payload"
mkdir -p "$DL"

c()  { printf '\033[1;36m[rigcheck]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# Single-quote-escape a value for the conf file. Deliberately NOT printf '%q' /
# ${var@Q}: rigcheck.conf is consumed by bash (source) AND python (report.py),
# and both understand plain single-quote wrapping with the '\'' escape — %q's
# backslash/$'...' forms would break the python parser. Pure bash, no subprocess.
q() { local s=${1//\'/\'\\\'\'}; printf '%s' "$s"; }

fetch() { # fetch <url> <outfile>
    local url="$1" out="$2"
    if command -v curl >/dev/null; then
        curl -fL --connect-timeout 15 --retry 2 -o "$out.part" "$url" && mv "$out.part" "$out"
    else
        wget -q --timeout=15 -O "$out.part" "$url" && mv "$out.part" "$out"
    fi
}

# ---------------------------------------------------------------- deps
c "RigCheck Phase 0 USB creator"
[ "$(uname -s)" = "Linux" ] || die "This script must run on Linux."
for t in lsblk tar openssl; do command -v "$t" >/dev/null || die "Missing required tool: $t"; done
command -v curl >/dev/null || command -v wget >/dev/null || die "Need curl or wget."
command -v unzip >/dev/null || warn "unzip not found — needed only if Memtest86+ downloads as .zip"
[ -d "$PAYLOAD" ] || die "payload/ directory not found next to this script."
SUDO="sudo"; [ "$(id -u)" = "0" ] && SUDO=""

# ---------------------------------------------------------------- downloads
SYSRESCUE_ISO="$DL/systemrescue-${SYSRESCUE_VER}-amd64.iso"
MEMTEST_ISO="$DL/mt86plus_${MEMTEST_VER}.iso"
VENTOY_TAR="$DL/ventoy-${VENTOY_VER}-linux.tar.gz"

# preflight: downloads need ~2.5GB; skip the check when everything is cached
if [ ! -f "$SYSRESCUE_ISO" ] || [ ! -f "$VENTOY_TAR" ]; then
    free_kb=$(df -Pk "$DL" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt 2621440 ]; then
        die "Only $((free_kb/1024))MB free at $DL — need ~2.5GB for downloads. Free up space or re-run with RIGCHECK_DL=/path/with/space"
    fi
    fstype=$(df -PT "$DL" 2>/dev/null | awk 'NR==2{print $2}')
    [ "${fstype:-}" = "tmpfs" ] && warn "$DL is on tmpfs (RAM-backed) — large downloads may exhaust memory; consider RIGCHECK_DL=/path/on/disk"
fi

if [ ! -f "$SYSRESCUE_ISO" ]; then
    # accept any systemrescue iso the user pre-downloaded
    alt=$(ls "$DL"/systemrescue-*-amd64.iso 2>/dev/null | head -1 || true)
    if [ -n "$alt" ]; then SYSRESCUE_ISO="$alt"; ok "Using pre-downloaded $(basename "$alt")"
    else
        c "Downloading SystemRescue ${SYSRESCUE_VER} (~900MB)..."
        fetch "https://fastly-cdn.system-rescue.org/releases/${SYSRESCUE_VER}/systemrescue-${SYSRESCUE_VER}-amd64.iso" "$SYSRESCUE_ISO" \
        || fetch "https://sourceforge.net/projects/systemrescuecd/files/sysresccd-x86/${SYSRESCUE_VER}/systemrescue-${SYSRESCUE_VER}-amd64.iso/download" "$SYSRESCUE_ISO" \
        || die "SystemRescue download failed. Manually download the ISO from https://www.system-rescue.org/Download/ into: $DL/ then re-run."
    fi
fi

if [ ! -f "$MEMTEST_ISO" ]; then
    alt=$(ls "$DL"/mt86plus*.iso "$DL"/memtest*.iso 2>/dev/null | head -1 || true)
    if [ -n "$alt" ]; then MEMTEST_ISO="$alt"; ok "Using pre-downloaded $(basename "$alt")"
    else
        c "Downloading Memtest86+ ${MEMTEST_VER}..."
        if fetch "https://memtest.org/download/v${MEMTEST_VER}/mt86plus_${MEMTEST_VER}.iso.zip" "$DL/mt86plus.zip"; then
            (cd "$DL" && unzip -o mt86plus.zip >/dev/null) || die "unzip failed"
            found=$(ls "$DL"/*.iso 2>/dev/null | grep -iv systemrescue | head -1 || true)
            [ -n "$found" ] && mv -f "$found" "$MEMTEST_ISO" 2>/dev/null || true
        fi
        [ -f "$MEMTEST_ISO" ] || { warn "Memtest86+ auto-download failed. Get the ISO from https://memtest.org and place it in $DL/ as mt86plus_${MEMTEST_VER}.iso"; warn "Continuing WITHOUT Memtest86+ (userspace RAM test still works)."; MEMTEST_ISO=""; }
    fi
fi

if [ ! -f "$VENTOY_TAR" ]; then
    c "Downloading Ventoy ${VENTOY_VER}..."
    fetch "https://github.com/ventoy/Ventoy/releases/download/v${VENTOY_VER}/ventoy-${VENTOY_VER}-linux.tar.gz" "$VENTOY_TAR" \
    || die "Ventoy download failed. Download ventoy-*-linux.tar.gz from https://github.com/ventoy/Ventoy/releases into $DL/ then re-run."
fi
VENTOY_DIR="$DL/ventoy-${VENTOY_VER}"
[ -d "$VENTOY_DIR" ] || (cd "$DL" && tar xzf "$VENTOY_TAR") || die "Failed to extract Ventoy."
ok "All components ready."

# ---------------------------------------------------------------- pick drive
c "Scanning for USB / removable drives..."
# lsblk -P (key="value" pairs) is robust to empty fields, unlike positional parsing
DRIVES=()
while IFS= read -r line; do
    name=""; size=""; model=""; tran=""; rmflag=""
    [[ $line =~ NAME=\"([^\"]*)\" ]]  && name="${BASH_REMATCH[1]}"
    [[ $line =~ SIZE=\"([^\"]*)\" ]]  && size="${BASH_REMATCH[1]}"
    [[ $line =~ MODEL=\"([^\"]*)\" ]] && model="${BASH_REMATCH[1]}"
    [[ $line =~ TRAN=\"([^\"]*)\" ]]  && tran="${BASH_REMATCH[1]}"
    [[ $line =~ RM=\"([^\"]*)\" ]]    && rmflag="${BASH_REMATCH[1]}"
    [ -n "$name" ] || continue
    if [ "$rmflag" = "1" ] || [ "$tran" = "usb" ]; then
        DRIVES+=("${name}"$'\t'"${size:-?}"$'\t'"${model:-?}"$'\t'"${tran:-?}")
    fi
done < <(lsblk -dpn -P -o NAME,SIZE,MODEL,TRAN,RM 2>/dev/null)
[ ${#DRIVES[@]} -gt 0 ] || die "No removable USB drive detected. Insert the stick and re-run."
echo
i=1
for d in "${DRIVES[@]}"; do
    IFS=$'\t' read -r dn ds dm dt <<< "$d"
    printf '  %d) %-14s %8s  %s [%s]\n' "$i" "$dn" "$ds" "$dm" "$dt"
    i=$((i+1))
done
echo
read -rp "Select drive number to WIPE and use for RigCheck: " N
[[ "$N" =~ ^[0-9]+$ ]] && [ "$N" -ge 1 ] && [ "$N" -le ${#DRIVES[@]} ] || die "Invalid selection."
DEV="${DRIVES[$((N-1))]%%$'\t'*}"
echo
warn "Selected: $DEV — current contents:"
lsblk "$DEV" || true
echo
printf '\033[1;31mALL DATA ON %s WILL BE PERMANENTLY DESTROYED.\033[0m\n' "$DEV"
read -rp "Type YES to continue: " CONFIRM
[ "$CONFIRM" = "YES" ] || die "Aborted."

# ---------------------------------------------------------------- install ventoy
c "Unmounting any mounted partitions on $DEV..."
for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do $SUDO umount "$p" 2>/dev/null || true; done
c "Installing Ventoy onto $DEV (this wipes the drive)..."
(cd "$VENTOY_DIR" && printf 'y\ny\n' | $SUDO sh Ventoy2Disk.sh -I "$DEV") || die "Ventoy install failed."
$SUDO partprobe "$DEV" 2>/dev/null || true; sleep 3

PART=$(lsblk -lnpo NAME "$DEV" | sed -n 2p)
[ -n "$PART" ] || die "Could not find Ventoy data partition on $DEV."
MNT=$(mktemp -d)
$SUDO mount "$PART" "$MNT" || die "Could not mount $PART (kernel exFAT support needed, Linux 5.7+)."
ok "Ventoy installed; data partition mounted."

# ---------------------------------------------------------------- copy files
c "Copying ISOs and RigCheck payload (this can take a few minutes)..."
$SUDO cp "$SYSRESCUE_ISO" "$MNT/" || die "ISO copy failed."
[ -n "$MEMTEST_ISO" ] && $SUDO cp "$MEMTEST_ISO" "$MNT/"
$SUDO mkdir -p "$MNT/rigcheck/reports"
$SUDO cp -r "$PAYLOAD/." "$MNT/rigcheck/"
$SUDO cp "$SCRIPT_DIR/verify.py" "$MNT/rigcheck/" 2>/dev/null || true

# ---------------------------------------------------------------- config wizard
echo
c "=== Setup options (press Enter to skip any of them) ==="
read -rp "Preselect test mode? [ask/coffee/standard/detailed] (default: ask): " MODE
case "${MODE:-ask}" in coffee|standard|detailed|ask) MODE="${MODE:-ask}";; *) warn "Unknown mode, using 'ask'"; MODE=ask;; esac
read -rp "WiFi SSID (phone hotspot, optional): " WIFI_SSID
WIFI_PASSWORD=""; WIFI_COUNTRY=""
if [ -n "$WIFI_SSID" ]; then
    read -rsp "WiFi password: " WIFI_PASSWORD; echo
    read -rp "WiFi country code (e.g. IN, US — helps old cards see the hotspot): " WIFI_COUNTRY
fi
read -rp "Email the report to (optional, needs SMTP below): " EMAIL_TO
SMTP_HOST=""; SMTP_PORT="587"; SMTP_USER=""; SMTP_PASSWORD=""; EMAIL_FROM=""
if [ -n "$EMAIL_TO" ]; then
    read -rp "SMTP host (Gmail: smtp.gmail.com): " SMTP_HOST
    read -rp "SMTP port (default 587): " SMTP_PORT; SMTP_PORT="${SMTP_PORT:-587}"
    read -rp "SMTP username (Gmail: your address): " SMTP_USER
    read -rsp "SMTP password (Gmail: 16-char App Password, NOT your account password): " SMTP_PASSWORD; echo
    EMAIL_FROM="$SMTP_USER"
fi
read -rsp "Anthropic API key for LLM analysis (optional): " LLM_API_KEY; echo
read -rp "After unattended test: stay on or power off? [stay/poweroff] (default: stay): " AFTER_TEST
case "${AFTER_TEST:-stay}" in poweroff|stay) AFTER_TEST="${AFTER_TEST:-stay}";; *) AFTER_TEST=stay;; esac

# ---------------------------------------------------------------- signing key
STICK_ID="rigcheck-$(date +%Y%m%d-%H%M%S)"
SIGNING_KEY=$(openssl rand -hex 32)
KEYDIR="$HOME/.rigcheck/keys"; mkdir -p "$KEYDIR"
printf '%s\n' "$SIGNING_KEY" > "$KEYDIR/$STICK_ID.key"; chmod 600 "$KEYDIR/$STICK_ID.key"

TMPCONF=$(mktemp)
cat > "$TMPCONF" <<EOF
# RigCheck configuration — generated $(date -u +%FT%TZ)
MODE='$(q "$MODE")'
WIFI_SSID='$(q "$WIFI_SSID")'
WIFI_PASSWORD='$(q "$WIFI_PASSWORD")'
WIFI_COUNTRY='$(q "$WIFI_COUNTRY")'
EMAIL_TO='$(q "$EMAIL_TO")'
EMAIL_FROM='$(q "$EMAIL_FROM")'
SMTP_HOST='$(q "$SMTP_HOST")'
SMTP_PORT='$(q "$SMTP_PORT")'
SMTP_USER='$(q "$SMTP_USER")'
SMTP_PASSWORD='$(q "$SMTP_PASSWORD")'
LLM_PROVIDER='anthropic'
LLM_MODEL='claude-sonnet-4-6'
LLM_API_KEY='$(q "$LLM_API_KEY")'
ABORT_TEMP_C='95'
NVME_ABORT_TEMP_C='82'
DISK_ABORT_TEMP_C='70'
BEEP='yes'
AFTER_TEST='$(q "$AFTER_TEST")'
CHALLENGE_NONCE=''
NONCE_PROMPT='no'
SIGNING_KEY='$SIGNING_KEY'
SIGNING_KEY_ID='$STICK_ID'
EOF
$SUDO cp "$TMPCONF" "$MNT/rigcheck/rigcheck.conf"; rm -f "$TMPCONF"

c "Flushing writes to USB (do not remove)..."
sync
$SUDO umount "$MNT" && rmdir "$MNT"

echo
ok  "=========================================================="
ok  "RigCheck USB created successfully on $DEV"
ok  "  Signing key saved to: $KEYDIR/$STICK_ID.key  (keep this!)"
ok  "  Verify reports later: python3 verify.py <report.json> --key-file $KEYDIR/$STICK_ID.key"
echo
c   "On the PC you want to test:"
c   "  1. Plug in the stick, power on, press the boot-menu key (F12/F11/F8/ESC)"
c   "  2. Pick the USB -> Ventoy menu -> SystemRescue (default boot entry is fine)"
c   "  3. At the root shell prompt run:"
c   "       mount -L Ventoy /mnt && bash /mnt/rigcheck/rigcheck.sh"
c   "  For a full standalone RAM test instead: pick the Memtest86+ entry in Ventoy."
ok  "=========================================================="
