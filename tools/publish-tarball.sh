#!/bin/bash
#
# tools/publish-tarball.sh - pins a new Arch Linux ARM tarball (maintainers only)
#
# 1) Downloads the current upstream ArchLinuxARM-aarch64-latest.tar.gz and its .sig
#    (or uses a tarball you already have)
# 2) Verifies the upstream GPG signature (pinned fingerprint)
# 3) Uploads both, unchanged, as assets of a GitHub release of this repo
# 4) Updates ARCH_RELEASE_TAG / ARCH_TARBALL / ARCH_TARBALL_SHA256 in archopen-setup.sh
#
# Then test an install, commit and push.
#
# Usage:
#   tools/publish-tarball.sh [--expect-sha256 SHA] [--tarball FILE --sig FILE] [--date YYYYMMDD]
#
# Requires: gh (logged in, with push access), gpg, curl
#
set -euo pipefail

UPSTREAM="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ARCH_KEY_FPR="68B3537F39A313B3E574D06777193F152BDBE6A6"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/archopen-setup.sh"

EXPECT_SHA=""
TARBALL=""
SIG=""
DATE=""

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-sha256) EXPECT_SHA="$2"; shift 2 ;;
    --tarball)       TARBALL="$2"; shift 2 ;;
    --sig)           SIG="$2"; shift 2 ;;
    --date)          DATE="$2"; shift 2 ;;
    -h|--help)       sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown option: $1" ;;
  esac
done

for t in gh gpg curl shasum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
REPO="$(cd "$ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner)" || die "gh cannot see this repo (gh auth login?)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/archopen-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$TARBALL" ]; then
  if [ -z "$DATE" ]; then
    lm="$(curl -fsSIL "$UPSTREAM" | awk -F': ' 'tolower($1) == "last-modified" { v = $2 } END { print v }' | tr -d '\r')"
    [ -n "$lm" ] || die "could not read Last-Modified of the upstream tarball"
    DATE="$(LC_ALL=C date -j -u -f '%a, %d %b %Y %H:%M:%S GMT' "$lm" '+%Y%m%d')"
  fi
  log "Downloading the upstream tarball ($DATE)"
  TARBALL="$WORK/upstream.tar.gz"
  SIG="$WORK/upstream.tar.gz.sig"
  curl -fL --progress-bar -o "$TARBALL" "$UPSTREAM"
  curl -fsSL -o "$SIG" "$UPSTREAM.sig"
fi
[ -f "$TARBALL" ] && [ -f "$SIG" ] || die "--tarball and --sig are both needed"
[ -n "$DATE" ] || die "--date YYYYMMDD is needed with --tarball"

log "Verifying the GPG signature"
GNUPGHOME="$WORK/gnupg"; export GNUPGHOME
mkdir -m 700 "$GNUPGHOME"
curl -fsSL -o "$WORK/key.asc" "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${ARCH_KEY_FPR}"
gpg --batch --quiet --import "$WORK/key.asc" 2>/dev/null
gpg --batch --status-fd 1 --verify "$SIG" "$TARBALL" 2>/dev/null \
  | awk -v f="$ARCH_KEY_FPR" '$2 == "VALIDSIG" && ($3 == f || $NF == f) { ok = 1 } END { exit ok ? 0 : 1 }' \
  || die "GPG signature could not be verified"
gpgconf --kill all >/dev/null 2>&1 || true

SHA="$(shasum -a 256 "$TARBALL" | awk '{ print $1 }')"
if [ -n "$EXPECT_SHA" ] && [ "$SHA" != "$EXPECT_SHA" ]; then
  die "sha256 is $SHA, expected $EXPECT_SHA"
fi

TAG="alarm-$DATE"
NAME="ArchLinuxARM-aarch64-$DATE.tar.gz"
cp "$TARBALL" "$WORK/$NAME"
cp "$SIG" "$WORK/$NAME.sig"

log "Uploading to $REPO release $TAG"
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --title "Arch Linux ARM aarch64 $DATE" --notes "Unmodified mirror of the upstream Arch Linux ARM aarch64 tarball (with its upstream GPG signature), pinned by archopen-setup.sh.

sha256: \`$SHA\`
upstream: $UPSTREAM"
fi
gh release upload "$TAG" --repo "$REPO" --clobber "$WORK/$NAME" "$WORK/$NAME.sig"

log "Updating archopen-setup.sh"
sed -i '' \
  -e "s|^ARCH_RELEASE_TAG=\".*\"|ARCH_RELEASE_TAG=\"$TAG\"|" \
  -e "s|^ARCH_TARBALL=\".*\"|ARCH_TARBALL=\"$NAME\"|" \
  -e "s|^ARCH_TARBALL_SHA256=\"\${ARCH_TARBALL_SHA256:-[0-9a-f]*}\"|ARCH_TARBALL_SHA256=\"\${ARCH_TARBALL_SHA256:-$SHA}\"|" \
  "$SETUP"
grep -E '^ARCH_(RELEASE_TAG|TARBALL|TARBALL_SHA256)=' "$SETUP"
printf '\nDone. Test an install, then commit and push archopen-setup.sh.\n'
