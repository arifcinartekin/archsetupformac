#!/bin/bash
#
# archopen-setup.sh
#
# Installs Arch Linux ARM on macOS (Apple Silicon) with QEMU and adds three
# terminal commands: `archopen`, `archclose` and `archuninstall`.
# One command, fully automatic:
#
#   1. Homebrew + qemu + gnupg (installed if missing)
#   2. Downloads the Alpine ISO and the pinned Arch Linux ARM tarball and
#      verifies them (sha256 + GPG)
#   3. Drives a temporary Alpine VM over the serial console to prepare the disk:
#      ESP (FAT32) + root (ext4), the tarball is extracted as root, and inside a
#      chroot it sets up pacman-key / pacman -Syu / systemd-boot / fstab /
#      hostname / terminfo / first-boot wizard
#   4. Generates start-uefi.sh, boots the new system via UEFI, logs in and checks it
#   5. Adds the archopen / archclose / archuninstall aliases to ~/.zshrc
#
# On the first `archopen`, log in as root (password: root). The first-boot
# wizard then creates your user, sets up sudo and zsh, and locks root.
#
# Usage:
#   bash archopen-setup.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/arifcinartekin/archsetupformac/main/archopen-setup.sh)
#
# Environment variables (all optional):
#   ARCHOPEN_DIR=~/vm/archarm   Install directory
#   ARCHOPEN_HOSTNAME=arch      Hostname inside Arch
#   ARCHOPEN_FORCE=1            Overwrite a completed install
#   ARCHOPEN_YES=1              Do not ask for confirmation
#   ARCHOPEN_PIN_BREW=1         brew pin qemu gnupg (keep brew upgrade away from them)
#   ARCHOPEN_CPUS=4  ARCHOPEN_MEM=4G  ARCHOPEN_ROOT_SIZE=20G  ARCHOPEN_ESP_SIZE=1G
#   ARCHOPEN_SSH_PORT=2222
#   ARCHOPEN_REPO=owner/name  ARCHOPEN_REF=main   Where companion files are fetched from
#   ARCHOPEN_ARCH_TARBALL_URL=... ARCH_TARBALL_SHA256=...   Use a different tarball
#
# For testing (non-macOS / no HVF): ARCHOPEN_ALLOW_NON_MAC=1 ARCHOPEN_ACCEL=tcg
#   ARCHOPEN_CPU=cortex-a72 ARCHOPEN_FW_CODE=... ARCHOPEN_FW_VARS=...
#
set -euo pipefail

###############################################################################
# VERSION PINS
###############################################################################
ARCHOPEN_REPO="${ARCHOPEN_REPO:-arifcinartekin/archsetupformac}"
ARCHOPEN_REF="${ARCHOPEN_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${ARCHOPEN_REPO}/${ARCHOPEN_REF}"

ALPINE_VERSION="3.24.3"
ALPINE_SERIES="v${ALPINE_VERSION%.*}"
ALPINE_ISO="alpine-virt-${ALPINE_VERSION}-aarch64.iso"
ALPINE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/releases/aarch64"
ALPINE_ISO_SHA256="e34603080e942e9ebc670689eee77dd7a6551c823a6ff5a299e308ded268098f"
ALPINE_KEY_URL="https://alpinelinux.org/keys/ncopa.asc"
ALPINE_KEY_FPR="0482D84022F52DF1C4E7CD43293ACD0907D9495A"

# The Arch Linux ARM tarball is mirrored unchanged (together with its upstream
# .sig) as a GitHub release asset of this repo, so the install never depends on
# the moving upstream "latest". tools/publish-tarball.sh updates these three lines.
ARCH_RELEASE_TAG="alarm-20260805"
ARCH_TARBALL="ArchLinuxARM-aarch64-20260805.tar.gz"
ARCH_TARBALL_SHA256="${ARCH_TARBALL_SHA256:-42a4eeaa038994ffd31fa173256ef2f0ef511358eeb41b9ea1f8626391b9b319}"
ARCH_TARBALL_URL="${ARCHOPEN_ARCH_TARBALL_URL:-https://github.com/${ARCHOPEN_REPO}/releases/download/${ARCH_RELEASE_TAG}/${ARCH_TARBALL}}"
ARCH_SIG_URL="${ARCHOPEN_ARCH_SIG_URL:-${ARCH_TARBALL_URL}.sig}"
ARCH_KEY_FPR="68B3537F39A313B3E574D06777193F152BDBE6A6"

# Root password until the first-boot wizard locks the root account
TEMP_ROOT_PASSWORD="root"

###############################################################################
# SETTINGS
###############################################################################
INSTALL_DIR="${ARCHOPEN_DIR:-$HOME/vm/archarm}"
ARCH_HOSTNAME="${ARCHOPEN_HOSTNAME:-arch}"
CPUS="${ARCHOPEN_CPUS:-4}"
MEM="${ARCHOPEN_MEM:-4G}"
ROOT_SIZE="${ARCHOPEN_ROOT_SIZE:-20G}"
ESP_SIZE="${ARCHOPEN_ESP_SIZE:-1G}"
SSH_PORT="${ARCHOPEN_SSH_PORT:-2222}"
ACCEL="${ARCHOPEN_ACCEL:-hvf}"
CPU_MODEL="${ARCHOPEN_CPU:-host}"

DL_DIR="$INSTALL_DIR/downloads"
LOG_FILE="$INSTALL_DIR/install.log"
INCOMPLETE_MARK="$INSTALL_DIR/.archopen-incomplete"
MANIFEST="$INSTALL_DIR/.archopen-manifest"

# Directory of this script when run from a checkout (empty under bash <(curl ...))
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

WORK=""
HTTP_PID=""
IS_MAC=0
FW_CODE=""
FW_VARS=""
QEMU_BIN=""
ARCH_SHA256=""
HAS_TERMINFO=0
BREW_INSTALLED_BY_US=0
FORMULAE_INSTALLED_BY_US=""

###############################################################################
# HELPERS
###############################################################################
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$HTTP_PID" ]; then
    kill "$HTTP_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

fetch() { # url file
  curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 20 -o "$2" "$1"
}

fetch_big() { # url file  (resumable, with progress bar)
  curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 -C - --progress-bar -o "$2" "$1"
}

# Copies a file of this repo from the local checkout, or downloads it from GitHub
repo_file() { # repo-path destination
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$1" ]; then
    cp "$SCRIPT_DIR/$1" "$2"
  else
    fetch "$RAW_BASE/$1" "$2" || die "Could not download $1 from $RAW_BASE"
  fi
}

###############################################################################
# GPG VERIFICATION (temporary keyring; fingerprints are pinned in this script)
###############################################################################
# gpg_verify_sig <key-file> <signature> <file> <expected-fingerprint>
gpg_verify_sig() {
  local keyfile="$1" sigfile="$2" datafile="$3" fpr="$4"
  local gh status
  gh="$(mktemp -d /tmp/archopen-gpg.XXXXXX)"
  chmod 700 "$gh"
  if ! GNUPGHOME="$gh" gpg --batch --no-tty --quiet --import "$keyfile" >/dev/null 2>&1; then
    rm -rf "$gh"
    return 2
  fi
  status="$(GNUPGHOME="$gh" gpg --batch --no-tty --status-fd 1 --verify "$sigfile" "$datafile" 2>/dev/null || true)"
  GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf "$gh"
  if printf '%s\n' "$status" | awk -v f="$fpr" '
        $2 == "BADSIG" || $2 == "ERRSIG" || $2 == "REVKEYSIG" { bad = 1 }
        $2 == "VALIDSIG" && ($3 == f || $NF == f) { good = 1 }
        END { exit (good && !bad) ? 0 : 1 }'; then
    return 0
  fi
  return 1
}

# Checks that a key file contains the expected fingerprint
key_has_fpr() { # file fpr
  local gh out rc=1
  gh="$(mktemp -d /tmp/archopen-gpg.XXXXXX)"
  chmod 700 "$gh"
  out="$(GNUPGHOME="$gh" gpg --batch --no-tty --show-keys --with-colons "$1" 2>/dev/null || true)"
  GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true
  rm -rf "$gh"
  if printf '%s\n' "$out" | awk -F: -v f="$2" '$1 == "fpr" && $10 == f { found = 1 } END { exit found ? 0 : 1 }'; then
    rc=0
  fi
  return "$rc"
}

fetch_arch_key() { # output-file
  local out="$1" url
  if [ -n "${ARCHOPEN_ARCH_KEY_FILE:-}" ]; then
    cp "$ARCHOPEN_ARCH_KEY_FILE" "$out"
    key_has_fpr "$out" "$ARCH_KEY_FPR" && return 0
    return 1
  fi
  for url in \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${ARCH_KEY_FPR}" \
    "https://pgp.mit.edu/pks/lookup?op=get&options=mr&search=0x${ARCH_KEY_FPR}" \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/${ARCH_KEY_FPR}"; do
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$out" "$url" 2>/dev/null && key_has_fpr "$out" "$ARCH_KEY_FPR"; then
      return 0
    fi
  done
  return 1
}

###############################################################################
# 0) PRE-FLIGHT CHECKS, DEPENDENCIES
###############################################################################
check_platform() {
  if [ "$(uname -s)" = "Darwin" ]; then
    IS_MAC=1
    [ "$(uname -m)" = "arm64" ] || die "This script is for Apple Silicon (arm64) Macs."
    [ "$(id -u)" -ne 0 ] || die "Do not run this script as root (Homebrew does not allow it)."
  else
    [ "${ARCHOPEN_ALLOW_NON_MAC:-0}" = "1" ] || die "This script is for macOS. (For testing: ARCHOPEN_ALLOW_NON_MAC=1)"
  fi
  printf '%s' "$ARCH_HOSTNAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' || die "Invalid hostname: $ARCH_HOSTNAME"
}

ensure_deps() {
  if [ "$IS_MAC" = "1" ]; then
    if ! xcode-select -p >/dev/null 2>&1; then
      warn "Xcode Command Line Tools are missing, opening the installer."
      xcode-select --install || true
      die "Run this script again once that installation has finished."
    fi

    local brew_bin=""
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(command -v brew)"
    elif [ -x /opt/homebrew/bin/brew ]; then
      brew_bin="/opt/homebrew/bin/brew"
    fi
    if [ -z "$brew_bin" ]; then
      log "Installing Homebrew (may ask for your Mac password)"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      brew_bin="/opt/homebrew/bin/brew"
      [ -x "$brew_bin" ] || die "Homebrew installation failed."
      BREW_INSTALLED_BY_US=1
    fi
    eval "$("$brew_bin" shellenv)"

    local pkg
    for pkg in qemu gnupg; do
      if ! brew list --versions "$pkg" >/dev/null 2>&1; then
        log "brew install $pkg"
        brew install "$pkg"
        FORMULAE_INSTALLED_BY_US="${FORMULAE_INSTALLED_BY_US:+$FORMULAE_INSTALLED_BY_US }$pkg"
      fi
    done
    if [ "${ARCHOPEN_PIN_BREW:-0}" = "1" ]; then
      brew pin qemu gnupg || warn "brew pin failed (not critical)."
    fi
  fi

  local t
  for t in curl python3 expect qemu-system-aarch64 qemu-img gpg gpgconf base64 awk uuidgen; do
    command -v "$t" >/dev/null 2>&1 || die "Missing tool: $t"
  done
  QEMU_BIN="$(command -v qemu-system-aarch64)"
}

find_firmware() {
  if [ -n "${ARCHOPEN_FW_CODE:-}" ]; then
    FW_CODE="$ARCHOPEN_FW_CODE"
    FW_VARS="${ARCHOPEN_FW_VARS:?ARCHOPEN_FW_VARS must be set as well}"
  else
    local prefix share=""
    prefix=""
    if command -v brew >/dev/null 2>&1; then
      prefix="$(brew --prefix 2>/dev/null || true)"
    fi
    local cand
    for cand in "$prefix/share/qemu" /opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu; do
      if [ -f "$cand/edk2-aarch64-code.fd" ] && [ -f "$cand/edk2-arm-vars.fd" ]; then
        share="$cand"
        break
      fi
    done
    [ -n "$share" ] || die "QEMU UEFI firmware files (edk2-aarch64-code.fd) not found."
    FW_CODE="$share/edk2-aarch64-code.fd"
    FW_VARS="$share/edk2-arm-vars.fd"
  fi
  if [ ! -f "$FW_CODE" ] || [ ! -f "$FW_VARS" ]; then
    die "Firmware files missing: $FW_CODE / $FW_VARS"
  fi
}

confirm_plan() {
  cat <<EOF

  Install directory : $INSTALL_DIR
  Virtual machine   : ${CPUS} CPUs, ${MEM} RAM, ${ROOT_SIZE} root disk, ${ESP_SIZE} ESP
  Hostname          : ${ARCH_HOSTNAME}
  Alpine            : ${ALPINE_VERSION} (verified with sha256 + GPG)
  Arch Linux ARM    : ${ARCH_TARBALL} (verified with pinned sha256 + GPG)
  Will change       : brew packages (qemu, gnupg),
                      ~/.zshrc (archopen, archclose, archuninstall aliases)

EOF
  if [ "${ARCHOPEN_YES:-0}" = "1" ]; then
    return 0
  fi
  [ -r /dev/tty ] || return 0
  local ans
  printf 'Continue? [Y/n] ' >/dev/tty
  IFS= read -r ans </dev/tty || ans="n"
  case "$ans" in
    ""|y|Y|yes|Yes) return 0 ;;
    *) die "Cancelled." ;;
  esac
}

check_existing() {
  if [ -e "$INSTALL_DIR/disk.qcow2" ] && [ ! -e "$INCOMPLETE_MARK" ] && [ "${ARCHOPEN_FORCE:-0}" != "1" ]; then
    die "There is already an install in $INSTALL_DIR. Stopping so it is not overwritten.
      Other directory: ARCHOPEN_DIR=~/vm/arch2 bash archopen-setup.sh
      Overwrite      : ARCHOPEN_FORCE=1 bash archopen-setup.sh
      Remove it      : archuninstall"
  fi
}

prepare_dirs() {
  mkdir -p "$DL_DIR"
  : > "$INCOMPLETE_MARK"
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/archopen.XXXXXX")"
  chmod 700 "$WORK"
}

# Records what this script installed on the Mac so archuninstall can offer to remove it.
# Earlier runs are merged: something installed by a previous attempt stays recorded.
write_manifest() {
  local prev_brew=0 prev_formulae="" f formulae
  if [ -f "$MANIFEST" ]; then
    prev_brew="$(awk -F= '$1 == "installed_homebrew" { print $2 }' "$MANIFEST")"
    prev_formulae="$(awk -F= '$1 == "installed_formulae" { print $2 }' "$MANIFEST")"
  fi
  formulae="$prev_formulae"
  for f in $FORMULAE_INSTALLED_BY_US; do
    case " $formulae " in
      *" $f "*) ;;
      *) formulae="${formulae:+$formulae }$f" ;;
    esac
  done
  {
    echo "# Written by archopen-setup.sh, read by archuninstall"
    echo "installed_homebrew=$([ "$BREW_INSTALLED_BY_US" = 1 ] || [ "${prev_brew:-0}" = 1 ] && echo 1 || echo 0)"
    echo "installed_formulae=$formulae"
    echo "pinned_formulae=$([ "${ARCHOPEN_PIN_BREW:-0}" = 1 ] && echo "qemu gnupg")"
    echo "ssh_port=$SSH_PORT"
  } > "$MANIFEST"
}

# Gets the companion files (first-boot wizard, zsh setup, Mac commands)
fetch_companions() {
  log "Getting companion files"
  repo_file guest/archopen-firstboot.sh "$WORK/archopen-firstboot.sh"
  repo_file third_party/zsh_setup/zsh_setup.sh "$WORK/zsh_setup.sh"
  repo_file mac/archclose.sh "$WORK/archclose.sh"
  repo_file mac/archuninstall.sh "$WORK/archuninstall.sh"
  ok "first-boot wizard, zsh_setup.sh, archclose, archuninstall"
}

###############################################################################
# 1) DOWNLOAD + VERIFY
###############################################################################
get_alpine() {
  log "Downloading and verifying Alpine ${ALPINE_VERSION} (installer environment)"
  local iso="$DL_DIR/$ALPINE_ISO"
  fetch "$ALPINE_BASE_URL/$ALPINE_ISO.sha256" "$iso.sha256"
  fetch "$ALPINE_BASE_URL/$ALPINE_ISO.asc" "$iso.asc"
  fetch "$ALPINE_KEY_URL" "$DL_DIR/alpine-ncopa.asc"

  if [ ! -f "$iso" ] || [ "$(sha256_of "$iso")" != "$ALPINE_ISO_SHA256" ]; then
    rm -f "$iso"
    fetch_big "$ALPINE_BASE_URL/$ALPINE_ISO" "$iso"
  fi

  local got published
  got="$(sha256_of "$iso")"
  published="$(awk '{print $1; exit}' "$iso.sha256")"
  [ "$got" = "$ALPINE_ISO_SHA256" ] || die "Alpine ISO sha256 does not match the pin in this script ($got)."
  [ "$got" = "$published" ] || die "Alpine ISO sha256 does not match the published value."
  ok "sha256 OK"

  key_has_fpr "$DL_DIR/alpine-ncopa.asc" "$ALPINE_KEY_FPR" || die "Alpine key fingerprint does not match the expected one."
  gpg_verify_sig "$DL_DIR/alpine-ncopa.asc" "$iso.asc" "$iso" "$ALPINE_KEY_FPR" || die "Alpine GPG signature could not be verified."
  ok "GPG signature OK (fingerprint $ALPINE_KEY_FPR)"
}

get_arch() {
  log "Downloading and verifying the Arch Linux ARM tarball"
  local tb="$DL_DIR/$ARCH_TARBALL"
  fetch "$ARCH_SIG_URL" "$tb.sig" || die "Could not download the tarball signature: $ARCH_SIG_URL"

  if [ ! -f "$tb" ] || [ "$(sha256_of "$tb")" != "$ARCH_TARBALL_SHA256" ]; then
    # A partial file from an interrupted run is resumed; a wrong file is downloaded again
    fetch_big "$ARCH_TARBALL_URL" "$tb" || true
    if [ "$(sha256_of "$tb" 2>/dev/null)" != "$ARCH_TARBALL_SHA256" ]; then
      rm -f "$tb"
      fetch_big "$ARCH_TARBALL_URL" "$tb" || die "Could not download the tarball: $ARCH_TARBALL_URL"
    fi
  fi

  ARCH_SHA256="$(sha256_of "$tb")"
  if [ "$ARCH_SHA256" != "$ARCH_TARBALL_SHA256" ]; then
    die "Arch tarball sha256 does not match the pin.
      pinned : $ARCH_TARBALL_SHA256
      got    : $ARCH_SHA256"
  fi
  ok "sha256 OK: $ARCH_SHA256"

  local keyfile="$DL_DIR/arch-builder.asc"
  fetch_arch_key "$keyfile" || die "Could not get the Arch signing key. You can provide a key file with ARCHOPEN_ARCH_KEY_FILE."
  gpg_verify_sig "$keyfile" "$tb.sig" "$tb" "$ARCH_KEY_FPR" || die "Arch GPG signature could not be verified."
  ok "GPG signature OK (fingerprint $ARCH_KEY_FPR)"
}

###############################################################################
# 2) DISKS AND THE INSTALLER VM
###############################################################################
create_images() {
  log "Creating virtual disks"
  rm -f "$INSTALL_DIR/disk.qcow2" "$INSTALL_DIR/efi.qcow2" "$INSTALL_DIR/vars.fd"
  qemu-img create -q -f qcow2 "$INSTALL_DIR/disk.qcow2" "$ROOT_SIZE"
  qemu-img create -q -f qcow2 "$INSTALL_DIR/efi.qcow2" "$ESP_SIZE"
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  ok "disk.qcow2 ($ROOT_SIZE), efi.qcow2 ($ESP_SIZE), vars.fd"
}

# terminfo source (infocmp -x output) of the Mac terminal, so the terminal also
# works over SSH inside Arch. Looks in the system first, then in the apps'
# own terminfo directories under /Applications (e.g. Ghostty).
find_terminfo_source() {
  local name="$1" d src
  [ -n "$name" ] || return 1
  if src="$(infocmp -x "$name" 2>/dev/null)" && [ -n "$src" ]; then
    printf '%s\n' "$src"; return 0
  fi
  for d in "${TERMINFO:-}" /Applications/*/Contents/Resources/terminfo \
           "$HOME"/Applications/*/Contents/Resources/terminfo; do
    [ -d "$d" ] || continue
    if src="$(TERMINFO="$d" infocmp -x "$name" 2>/dev/null)" && [ -n "$src" ]; then
      printf '%s\n' "$src"; return 0
    fi
  done
  return 1
}

stage_terminfo() { # output
  local name="${TERM:-}"
  case "$name" in
    ""|dumb|xterm|xterm-256color|screen*|tmux*|linux|vt100|vt220)
      return 0 ;;
  esac
  command -v infocmp >/dev/null 2>&1 || return 0
  if find_terminfo_source "$name" > "$1"; then
    HAS_TERMINFO=1
    ok "terminfo of this terminal will be installed: $name"
  else
    rm -f "$1"
    warn "terminfo '$name' not found on this Mac, skipping"
  fi
}

write_installer_vm_script() { # output
  local out="$1"
  {
    printf '#!/bin/bash\n'
    printf 'exec %q \\\n' "$QEMU_BIN"
    printf '  -machine virt,highmem=on -accel %q -cpu %q -smp %q -m %q \\\n' "$ACCEL" "$CPU_MODEL" "$CPUS" "$MEM"
    printf '  -drive if=pflash,format=raw,readonly=on,file=%q \\\n' "$FW_CODE"
    printf '  -drive if=pflash,format=raw,file=%q \\\n' "$INSTALL_DIR/vars.fd"
    printf '  -drive if=none,id=root,file=%q,format=qcow2 \\\n' "$INSTALL_DIR/disk.qcow2"
    printf '  -device virtio-blk-pci,drive=root,serial=ARCHROOT \\\n'
    printf '  -drive if=none,id=esp,file=%q,format=qcow2 \\\n' "$INSTALL_DIR/efi.qcow2"
    printf '  -device virtio-blk-pci,drive=esp,serial=ARCHESP \\\n'
    printf '  -drive if=none,id=iso,file=%q,format=raw,readonly=on \\\n' "$DL_DIR/$ALPINE_ISO"
    printf '  -device virtio-blk-pci,drive=iso,serial=ALPINEISO,bootindex=0 \\\n'
    printf '  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \\\n'
    printf '  -nographic\n'
  } > "$out"
  chmod 700 "$out"
}

write_guest_script() { # output
  cat > "$1" <<'GUEST_EOF'
#!/bin/sh
# archopen guest installer: runs in the Alpine live environment (busybox ash)
set -eu

step() { echo "ARCHOPEN_STEP: $*"; }
die()  { echo "ARCHOPEN_ERROR: $*"; exit 1; }
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "ARCHOPEN_ERROR: guest script exited with code $rc"' EXIT

: "${ROOT_UUID:?}" "${ESP_ID:?}" "${ESP_UUID:?}" "${FILES_URL:?}" "${TARBALL_SHA256:?}" "${ALPINE_SERIES:?}"
: "${ARCH_HOSTNAME:?}" "${ROOT_PW:?}"
HAS_TERMINFO="${HAS_TERMINFO:-0}"
ESP_OPTS="rw,relatime,fmask=0077,dmask=0077,errors=remount-ro"

step "Installing Alpine tools"
# http: packages are verified by apk signatures; avoids CA/clock issues on the live ISO
printf '%s\n' \
  "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/main" \
  "http://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/community" > /etc/apk/repositories
apk update >/dev/null || die "apk update failed (internet access?)"
apk add -q --no-progress e2fsprogs libarchive-tools curl sfdisk dosfstools || die "apk add failed"
modprobe ext4 2>/dev/null || true
modprobe vfat 2>/dev/null || true

find_disk() {
  for d in /sys/block/vd*; do
    [ -e "$d/serial" ] || continue
    s="$(cat "$d/serial" 2>/dev/null || true)"
    if [ "$s" = "$1" ]; then
      echo "/dev/${d##*/}"
      return 0
    fi
  done
  return 1
}
ROOTDEV="$(find_disk ARCHROOT)" || die "root disk not found"
ESPDEV="$(find_disk ARCHESP)" || die "ESP disk not found"
step "Disks: root=$ROOTDEV  esp=$ESPDEV"

step "Partitioning the ESP (GPT, EFI System) and formatting it as FAT32"
echo 'type=U' | sfdisk --quiet --label gpt "$ESPDEV" >/dev/null
ESPPART="${ESPDEV}1"
i=0
while [ ! -b "$ESPPART" ] && [ "$i" -lt 20 ]; do
  mdev -s 2>/dev/null || true
  sleep 1
  i=$((i + 1))
done
[ -b "$ESPPART" ] || die "$ESPPART did not appear"
mkfs.fat -F32 -n EFI -i "$ESP_ID" "$ESPPART" >/dev/null

step "Formatting the root disk as ext4"
mkfs.ext4 -q -F -L archroot -U "$ROOT_UUID" "$ROOTDEV"
mount "$ROOTDEV" /mnt

step "Fetching the Arch tarball from the Mac and verifying sha256"
curl -fsS -o /tmp/arch.tar.gz "$FILES_URL/arch.tar.gz" || die "could not download the tarball"
echo "$TARBALL_SHA256  /tmp/arch.tar.gz" | sha256sum -c - >/dev/null || die "tarball sha256 mismatch"

step "Extracting the tarball as root with bsdtar (this can take a few minutes)"
if ! bsdtar -xpf /tmp/arch.tar.gz -C /mnt; then
  die "bsdtar failed"
fi
rm -f /tmp/arch.tar.gz
sync
[ -d /mnt/usr ] && [ -d /mnt/boot ] || die "tarball does not have the expected layout"

step "Moving boot files to the ESP"
mkdir -p /tmp/esp
mount -t vfat -o "$ESP_OPTS" "$ESPPART" /tmp/esp
cp -rL /mnt/boot/. /tmp/esp/
sync
umount /tmp/esp
rm -rf /mnt/boot/*

step "Preparing the chroot"
mount --bind /mnt /mnt
mount -t vfat -o "$ESP_OPTS" "$ESPPART" /mnt/boot
mount -t proc proc /mnt/proc -o nosuid,noexec,nodev
mount -t sysfs sys /mnt/sys -o nosuid,noexec,nodev,ro
mount -t devtmpfs udev /mnt/dev -o mode=0755,nosuid
mkdir -p /mnt/dev/pts /mnt/dev/shm
mount -t devpts devpts /mnt/dev/pts -o mode=0620,gid=5,nosuid,noexec
mount -t tmpfs shm /mnt/dev/shm -o mode=1777,nosuid,nodev
mount -t tmpfs run /mnt/run -o nosuid,nodev,mode=0755
mount -t tmpfs tmp /mnt/tmp -o mode=1777,strictatime,nodev,nosuid
# Arch's /etc/resolv.conf points to the systemd-resolved stub; temporary DNS for the chroot
mkdir -p /mnt/run/systemd/resolve
cp /etc/resolv.conf /mnt/run/systemd/resolve/stub-resolv.conf
cp /etc/resolv.conf /mnt/run/systemd/resolve/resolv.conf

cat > /mnt/etc/fstab <<FSTAB_EOF
# Static information about the filesystems.
# See fstab(5) for details.

# <file system> <dir> <type> <options> <dump> <pass>
UUID=${ROOT_UUID}  /      ext4  rw,relatime  0 1
UUID=${ESP_UUID}  /boot  vfat  ${ESP_OPTS}  0 2
FSTAB_EOF

step "Setting the hostname: $ARCH_HOSTNAME"
echo "$ARCH_HOSTNAME" > /mnt/etc/hostname

step "Installing the first-boot wizard and zsh setup"
curl -fsS -o /tmp/archopen-firstboot.sh "$FILES_URL/archopen-firstboot.sh" || die "could not download the first-boot wizard"
curl -fsS -o /tmp/zsh_setup.sh "$FILES_URL/zsh_setup.sh" || die "could not download zsh_setup.sh"
install -D -m 0755 /tmp/archopen-firstboot.sh /mnt/usr/local/sbin/archopen-firstboot
install -D -m 0644 /tmp/zsh_setup.sh /mnt/usr/local/share/archopen/zsh_setup.sh
if [ "$HAS_TERMINFO" = "1" ]; then
  curl -fsS -o /mnt/root/.archopen-terminfo "$FILES_URL/terminfo.src" || die "could not download terminfo"
fi

( umask 077; printf '%s' "$ROOT_PW" > /mnt/root/.archopen-pw )
cat > /mnt/root/archopen-chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
step() { echo "ARCHOPEN_STEP: $*"; }

step "Initialising the pacman keyring"
pacman-key --init
pacman-key --populate archlinuxarm

# The pinned tarball can be older than the repos: refresh the keyring first so
# packages signed by newer keys are accepted.
step "Updating the keyring"
pacman -Sy --noconfirm archlinuxarm-keyring

step "Updating the system and installing packages (pacman -Su)"
pacman -Su --noconfirm --needed sudo zsh git curl wget unzip fontconfig

step "Installing systemd-boot"
bootctl install --esp-path=/boot --no-variables
mkdir -p /boot/loader/entries
cat > /boot/loader/loader.conf <<LOADER_EOF
default arch.conf
timeout 3
console-mode max
editor no
LOADER_EOF
cat > /boot/loader/entries/arch.conf <<ENTRY_EOF
title   Arch Linux ARM
linux   /Image
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw console=ttyAMA0 systemd.tty.term.ttyAMA0=xterm-256color
ENTRY_EOF
systemctl enable systemd-boot-update.service || echo "warning: could not enable systemd-boot-update"

step "Setting the temporary root password"
PW="$(cat /root/.archopen-pw)"
rm -f /root/.archopen-pw
printf 'root:%s\n' "$PW" | chpasswd

if [ -f /root/.archopen-terminfo ]; then
  step "Installing the terminal's terminfo"
  tic -x -o /usr/share/terminfo /root/.archopen-terminfo || echo "warning: tic failed"
  rm -f /root/.archopen-terminfo
fi

gpgconf --homedir /etc/pacman.d/gnupg --kill all >/dev/null 2>&1 || true
CHROOT_EOF

chroot /mnt /usr/bin/env -i HOME=/root TERM=dumb LANG=C \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin \
  ROOT_UUID="$ROOT_UUID" \
  /bin/bash /root/archopen-chroot.sh || die "installation inside the chroot failed"
rm -f /mnt/root/archopen-chroot.sh /mnt/root/.archopen-pw /mnt/root/.archopen-terminfo

step "Checking the installation"
for f in Image initramfs-linux.img EFI/BOOT/BOOTAA64.EFI loader/loader.conf loader/entries/arch.conf; do
  [ -s "/mnt/boot/$f" ] || die "/boot/$f is missing"
done
echo "ARCHOPEN_PKGLIST_BEGIN"
chroot /mnt /usr/bin/pacman -Q
echo "ARCHOPEN_PKGLIST_END"

step "Unmounting"
killall gpg-agent dirmngr keyboxd scdaemon 2>/dev/null || true
sync
for m in /mnt/tmp /mnt/run /mnt/dev/shm /mnt/dev/pts /mnt/dev /mnt/sys /mnt/proc /mnt/boot /mnt /mnt; do
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done
sync
step "Alpine install stage done"
GUEST_EOF
}

write_installer_expect() { # output
  cat > "$1" <<'EXP_EOF'
#!/usr/bin/expect -f
# Drives the Alpine VM over the serial console. Input: environment variables (ARCHOPEN_*)
set timeout 30
match_max 200000
log_user 0
proc wait_info {} {
    if {[catch {wait} r]} { return "could not get exit status" }
    return "pid=[lindex $r 0] os_error=[lindex $r 2] exit_code_or_signal=[lindex $r 3]"
}
log_file -a $env(ARCHOPEN_LOG)

proc die {msg} {
    puts stderr "\nERROR: $msg"
    exit 1
}

spawn $env(ARCHOPEN_VM_SCRIPT)

# 1) Boot and log in
set nudges 0
set logins 0
expect {
    -re {login: $} {
        incr logins
        if {$logins > 3} { die "Alpine login failed" }
        send "root\r"
        exp_continue
    }
    -re {[Pp]assword: $} {
        send "\r"
        exp_continue
    }
    -re {:~# $} { }
    timeout {
        incr nudges
        if {$nudges > $env(ARCHOPEN_BOOT_NUDGES)} { die "Alpine boot timed out (log: $env(ARCHOPEN_LOG))" }
        send "\r"
        exp_continue
    }
    eof { die "QEMU exited unexpectedly - [wait_info] (log: $env(ARCHOPEN_LOG))" }
}

# Runs one command and returns its exit code
proc run {cmd tmo} {
    global timeout
    set timeout $tmo
    send -- "$cmd; echo ARCHOPEN_RC=\$?\r"
    expect {
        -re {ARCHOPEN_RC=([0-9]+)\r} { return $expect_out(1,string) }
        timeout { die "timed out: $cmd" }
        eof { die "QEMU exited - [wait_info]: $cmd" }
    }
}

if {[run "stty cols 250" 30] != 0} { die "stty failed" }
puts "    - Alpine is up, configuring the network"; flush stdout
if {[run "ip link set eth0 up && udhcpc -i eth0 -q -n >/dev/null 2>&1" 120] != 0} { die "Alpine network did not come up (DHCP)" }
if {[run "wget -q -O /tmp/guest.sh http://10.0.2.2:$env(ARCHOPEN_PORT)/guest-install.sh" 60] != 0} { die "could not fetch the guest script from the Mac" }

# 2) The actual installation
set vars "ROOT_UUID=$env(ARCHOPEN_ROOT_UUID) ESP_ID=$env(ARCHOPEN_ESP_ID) ESP_UUID=$env(ARCHOPEN_ESP_UUID)"
append vars " FILES_URL=http://10.0.2.2:$env(ARCHOPEN_PORT) TARBALL_SHA256=$env(ARCHOPEN_TARBALL_SHA256)"
append vars " ALPINE_SERIES=$env(ARCHOPEN_ALPINE_SERIES) ARCH_HOSTNAME=$env(ARCHOPEN_HOSTNAME)"
append vars " HAS_TERMINFO=$env(ARCHOPEN_HAS_TERMINFO) ROOT_PW=$env(ARCHOPEN_ROOT_PW)"
set timeout $env(ARCHOPEN_IDLE_TIMEOUT)
send -- "$vars sh /tmp/guest.sh; echo ARCHOPEN_GUEST_DONE=\$?\r"

set guest_rc -1
set errmsg ""
expect {
    -re {([^\n]*)\n} {
        set line [string trimright $expect_out(1,string) "\r"]
        set cont 1
        if {[regexp {^ARCHOPEN_STEP: (.*)$} $line -> msg]} {
            puts "    - $msg"; flush stdout
        } elseif {[regexp {^ARCHOPEN_ERROR: (.*)$} $line -> msg]} {
            set errmsg $msg
            puts stderr "    x $msg"; flush stderr
        } elseif {[regexp {^ARCHOPEN_GUEST_DONE=([0-9]+)$} $line -> rc]} {
            set guest_rc $rc
            set cont 0
        }
        if {$cont} { exp_continue }
    }
    timeout { die "The installation produced no output for $env(ARCHOPEN_IDLE_TIMEOUT) s (log: $env(ARCHOPEN_LOG))" }
    eof { die "QEMU exited during the installation - [wait_info] (log: $env(ARCHOPEN_LOG))" }
}

if {$guest_rc != 0} {
    die "Installation failed (exit code $guest_rc) $errmsg (log: $env(ARCHOPEN_LOG))"
}

# 3) Clean shutdown
set timeout 180
send -- "sync; poweroff\r"
expect {
    eof { }
    timeout { die "Alpine did not shut down" }
}
catch {wait}
exit 0
EXP_EOF
}

run_installer() {
  log "Installer VM running (driven automatically over the Alpine serial console)"
  echo "    Detailed output: $LOG_FILE"

  local stage="$WORK/stage"
  mkdir -p "$stage"
  write_guest_script "$stage/guest-install.sh"
  ln -s "$DL_DIR/$ARCH_TARBALL" "$stage/arch.tar.gz"
  cp "$WORK/archopen-firstboot.sh" "$stage/archopen-firstboot.sh"
  cp "$WORK/zsh_setup.sh" "$stage/zsh_setup.sh"
  stage_terminfo "$stage/terminfo.src"

  local port
  port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$stage" >"$WORK/http.log" 2>&1 &
  HTTP_PID=$!
  local i=0
  until curl -fsI "http://127.0.0.1:$port/guest-install.sh" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 50 ] || die "The local HTTP server did not start ($WORK/http.log)"
    sleep 0.2
  done

  write_installer_vm_script "$WORK/run-installer-vm.sh"
  write_installer_expect "$WORK/installer.exp"

  ROOT_UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  ESP_ID="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | tr '[:lower:]' '[:upper:]')"
  ESP_UUID="${ESP_ID:0:4}-${ESP_ID:4:4}"

  ARCHOPEN_LOG="$LOG_FILE" \
  ARCHOPEN_VM_SCRIPT="$WORK/run-installer-vm.sh" \
  ARCHOPEN_PORT="$port" \
  ARCHOPEN_ROOT_UUID="$ROOT_UUID" \
  ARCHOPEN_ESP_ID="$ESP_ID" \
  ARCHOPEN_ESP_UUID="$ESP_UUID" \
  ARCHOPEN_TARBALL_SHA256="$ARCH_SHA256" \
  ARCHOPEN_ALPINE_SERIES="$ALPINE_SERIES" \
  ARCHOPEN_HOSTNAME="$ARCH_HOSTNAME" \
  ARCHOPEN_HAS_TERMINFO="$HAS_TERMINFO" \
  ARCHOPEN_ROOT_PW="$TEMP_ROOT_PASSWORD" \
  ARCHOPEN_BOOT_NUDGES="${ARCHOPEN_BOOT_NUDGES:-40}" \
  ARCHOPEN_IDLE_TIMEOUT="${ARCHOPEN_IDLE_TIMEOUT:-1800}" \
    expect -f "$WORK/installer.exp" || die "The installer VM failed. Log: $LOG_FILE"

  kill "$HTTP_PID" >/dev/null 2>&1 || true
  HTTP_PID=""
  ok "Disk ready"
}

###############################################################################
# 3) LAUNCHER, VERIFICATION, ALIASES
###############################################################################
write_start_script() {
  local out="$INSTALL_DIR/start-uefi.sh"
  # The generated script intentionally contains literal $
  # shellcheck disable=SC2016
  {
    printf '#!/bin/bash\n'
    printf '# Arch Linux ARM (QEMU) launcher. Generated by archopen-setup.sh.\n'
    printf '# Quit: `archclose` from another Mac terminal, `poweroff` inside the VM, or Ctrl+A then X.\n'
    printf '# SSH: ssh -p %s <user>@localhost\n' "$SSH_PORT"
    printf 'DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1\n'
    printf 'SSH_PORT="${ARCHOPEN_SSH_PORT:-%s}"\n' "$SSH_PORT"
    printf 'pid="$(cat "$DIR/qemu.pid" 2>/dev/null || true)"\n'
    printf 'if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qF "$DIR/disk.qcow2"; then\n'
    printf '  echo "The Arch VM is already running (pid $pid). Shut it down with: archclose" >&2\n'
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'rm -f "$DIR/qmp.sock"\n'
    printf 'exec %q \\\n' "$QEMU_BIN"
    printf '  -machine virt,highmem=on -accel %q -cpu %q -smp %q -m %q \\\n' "$ACCEL" "$CPU_MODEL" "$CPUS" "$MEM"
    printf '  -drive if=pflash,format=raw,readonly=on,file=%q \\\n' "$FW_CODE"
    printf '  -drive if=pflash,format=raw,file="$DIR/vars.fd" \\\n'
    printf '  -drive if=none,id=root,file="$DIR/disk.qcow2",format=qcow2 \\\n'
    printf '  -device virtio-blk-pci,drive=root \\\n'
    printf '  -drive if=none,id=esp,file="$DIR/efi.qcow2",format=qcow2 \\\n'
    printf '  -device virtio-blk-pci,drive=esp,bootindex=0 \\\n'
    printf '  -device virtio-net-pci,netdev=n0 \\\n'
    printf '  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 \\\n'
    printf '  -qmp "unix:$DIR/qmp.sock,server=on,wait=off" \\\n'
    printf '  -pidfile "$DIR/qemu.pid" \\\n'
    printf '  -nographic\n'
  } > "$out"
  chmod 755 "$out"
}

write_verify_expect() { # output
  cat > "$1" <<'EXP_EOF'
#!/usr/bin/expect -f
# Boots the new system via UEFI, logs in as root, checks a few things, enables
# the first-boot wizard and shuts down.
set timeout 30
match_max 200000
log_user 0
log_file -a $env(ARCHOPEN_LOG)

proc die {msg} {
    puts stderr "\nERROR: $msg"
    exit 1
}

set pw $env(ARCHOPEN_PASSWORD)
spawn $env(ARCHOPEN_START_SCRIPT)

set nudges 0
set logins 0
expect {
    -re {login: $} {
        incr logins
        if {$logins > 3} { die "Arch login failed (password rejected?)" }
        send "root\r"
        exp_continue
    }
    -re {Password: $} {
        send -- "$pw\r"
        exp_continue
    }
    -re {\]# $} { }
    timeout {
        incr nudges
        if {$nudges > $env(ARCHOPEN_BOOT_NUDGES)} { die "Arch boot timed out (log: $env(ARCHOPEN_LOG))" }
        send "\r"
        exp_continue
    }
    eof { die "QEMU exited; the system did not boot (log: $env(ARCHOPEN_LOG))" }
}
puts "    - Logged in"; flush stdout

set timeout 60
# Every field is followed by a fixed delimiter: output can arrive in pieces,
# and an unterminated last group would match a partial value
send -- "echo ARCHOPEN_\$((20+22))_\$(uname -r)_\$(findmnt -n -o SOURCE /boot)_\$(uname -n)_END\r"
expect {
    -re {ARCHOPEN_42_([^_\r\n]+)_(/dev/[a-z0-9]+)_([A-Za-z0-9.-]+)_END} {
        set kver $expect_out(1,string)
        set bootdev $expect_out(2,string)
        set host $expect_out(3,string)
    }
    timeout { die "could not read uname/findmnt output" }
    eof { die "QEMU exited" }
}
puts "    - Kernel: $kver, /boot: $bootdev, hostname: $host"; flush stdout
if {$host ne $env(ARCHOPEN_HOSTNAME)} { die "hostname is '$host', expected '$env(ARCHOPEN_HOSTNAME)'" }

# sshd (key generation on first boot can take a while)
set ssh_ok 0
for {set i 0} {$i < 90} {incr i} {
    set banner ""
    catch {exec python3 -c {import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.settimeout(3)
sys.stdout.write(s.recv(64).decode("ascii", "ignore"))} $env(ARCHOPEN_SSH_PORT)} banner
    if {[string match "SSH-2.0*" $banner]} { set ssh_ok 1; break }
    after 2000
}
if {$ssh_ok} {
    puts "    - sshd is answering (127.0.0.1:$env(ARCHOPEN_SSH_PORT))"
} else {
    puts "    ! sshd did not answer within 3 min (not critical, try again later)"
}
flush stdout

# The wizard starts on the next interactive root login
send -- "/usr/local/sbin/archopen-firstboot --enable; echo ARCHOPEN_EN=\$?\r"
expect {
    -re {ARCHOPEN_EN=([0-9]+)\r} {
        if {$expect_out(1,string) != 0} { die "could not enable the first-boot wizard" }
    }
    timeout { die "could not enable the first-boot wizard (timeout)" }
    eof { die "QEMU exited" }
}
puts "    - First-boot wizard enabled"; flush stdout

set f [open "$env(ARCHOPEN_WORK)/kver" w]
puts $f $kver
close $f

set timeout 180
send -- "sync; poweroff\r"
expect {
    eof { }
    timeout { die "Arch did not shut down" }
}
catch {wait}
exit 0
EXP_EOF
}

verify_boot() {
  log "Booting the new system via UEFI and verifying it"
  # Drop the NVRAM state left by the installer VM, start with a clean vars.fd
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  write_start_script
  write_verify_expect "$WORK/verify.exp"
  ARCHOPEN_LOG="$LOG_FILE" \
  ARCHOPEN_START_SCRIPT="$INSTALL_DIR/start-uefi.sh" \
  ARCHOPEN_PASSWORD="$TEMP_ROOT_PASSWORD" \
  ARCHOPEN_HOSTNAME="$ARCH_HOSTNAME" \
  ARCHOPEN_SSH_PORT="$SSH_PORT" \
  ARCHOPEN_WORK="$WORK" \
  ARCHOPEN_BOOT_NUDGES="${ARCHOPEN_BOOT_NUDGES:-40}" \
    expect -f "$WORK/verify.exp" || die "Verification boot failed. Log: $LOG_FILE"
  # The verification boot may have written to NVRAM as well
  cp "$FW_VARS" "$INSTALL_DIR/vars.fd"
  rm -f "$INSTALL_DIR/qmp.sock" "$INSTALL_DIR/qemu.pid"
  ok "System boots, login works, first-boot wizard armed, clean shutdown"
}

install_commands() {
  install -m 755 "$WORK/archclose.sh" "$INSTALL_DIR/archclose.sh"
  install -m 755 "$WORK/archuninstall.sh" "$INSTALL_DIR/archuninstall.sh"

  local rc="$HOME/.zshrc" begin="# >>> archopen >>>" end="# <<< archopen <<<"
  touch "$rc"
  if [ ! -f "$rc.archopen-backup" ]; then
    cp "$rc" "$rc.archopen-backup"
  fi
  local tmp="$WORK/zshrc.new"
  awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$rc" > "$tmp"
  {
    printf '%s\n' "$begin"
    printf 'alias archopen=%q\n' "$INSTALL_DIR/start-uefi.sh"
    printf 'alias archclose=%q\n' "$INSTALL_DIR/archclose.sh"
    printf 'alias archuninstall=%q\n' "$INSTALL_DIR/archuninstall.sh"
    printf '%s\n' "$end"
  } >> "$tmp"
  cat "$tmp" > "$rc"
  # shellcheck disable=SC2088
  ok "archopen, archclose, archuninstall added to ~/.zshrc (backup: $rc.archopen-backup)"
}

write_lock() {
  local lock="$INSTALL_DIR/versions.lock"
  {
    echo "# Generated by archopen-setup.sh: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "alpine_version=$ALPINE_VERSION"
    echo "alpine_iso_sha256=$ALPINE_ISO_SHA256"
    echo "arch_tarball=$ARCH_TARBALL"
    echo "arch_tarball_sha256=$ARCH_SHA256"
    echo "arch_kernel=$(cat "$WORK/kver" 2>/dev/null || echo unknown)"
    echo "hostname=$ARCH_HOSTNAME"
    echo "qemu=$("$QEMU_BIN" --version | head -n 1)"
    echo "root_uuid=$ROOT_UUID"
    echo "esp_uuid=$ESP_UUID"
    echo
    echo "# Arch packages (pacman -Q)"
    awk '/^ARCHOPEN_PKGLIST_BEGIN/ { on = 1; next } /^ARCHOPEN_PKGLIST_END/ { on = 0 } on { gsub(/\033\[[?0-9;]*[a-zA-Z]/, ""); sub(/\r$/, ""); if ($0 ~ /^[^ ]+ [^ ]+$/) print }' "$LOG_FILE"
  } > "$lock"
  ok "Version record: $lock"
}

###############################################################################
# MAIN
###############################################################################
main() {
  printf '\n\033[1marchopen setup\033[0m: Arch Linux ARM on macOS with QEMU\n'
  check_platform
  check_existing
  log "Checking dependencies"
  ensure_deps
  find_firmware
  confirm_plan
  prepare_dirs
  write_manifest
  fetch_companions
  get_alpine
  get_arch
  create_images
  run_installer
  verify_boot
  install_commands
  write_lock
  rm -f "$INCOMPLETE_MARK"

  printf '\n\033[1;32mInstallation complete.\033[0m\n'
  cat <<EOF

  Open a new terminal (or run: source ~/.zshrc). Commands:

      archopen        start Arch in this terminal
      archclose       shut Arch down cleanly (from another Mac terminal)
      archuninstall   remove what this setup installed, asking item by item

  First login     : user root, password ${TEMP_ROOT_PASSWORD}
                    The first-boot wizard then creates your user, sets up sudo
                    and zsh, and locks the root account.
  SSH (afterwards): ssh -p $SSH_PORT <user>@localhost   (reachable from this Mac only)
  Directory       : $INSTALL_DIR
  Version record  : $INSTALL_DIR/versions.lock

EOF
  if [ "${ARCHOPEN_YES:-0}" != "1" ] && [ -r /dev/tty ]; then
    local ans
    printf 'Start Arch now? [Y/n] ' >/dev/tty
    IFS= read -r ans </dev/tty || ans="n"
    case "$ans" in
      ""|y|Y|yes|Yes)
        cleanup
        trap - EXIT
        exec "$INSTALL_DIR/start-uefi.sh" ;;
    esac
  fi
}

main "$@"
