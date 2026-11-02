#!/bin/bash
#
# archopen-winsize - keeps the serial console the size of the Mac terminal
#
# A serial line has no way to tell the guest that the terminal window was
# resized. The Mac launcher (start-uefi.sh) sends "<rows> <cols>" lines over a
# virtio-serial port whenever the window changes (and every few seconds, so a
# reboot inside the VM picks the size up again). This applies them to the
# console with stty, and the kernel then sends SIGWINCH to the program running
# there (shell, htop, vim, the login screen), which redraws at the new size.
#
# Installed by archopen-setup.sh as /usr/local/sbin/archopen-winsize and started
# by udev (archopen-winsize.service) when the port shows up.
#
set -uo pipefail

PORT="/dev/virtio-ports/org.archopen.winsize"
TTY="${ARCHOPEN_WINSIZE_TTY:-/dev/ttyAMA0}"

[ -e "$PORT" ] || { echo "archopen-winsize: $PORT not found" >&2; exit 0; }
exec 3<"$PORT" || exit 1

valid() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]]; }

while IFS=' ' read -r -u 3 rows cols; do
  # Sizes that queued up while nothing was reading (e.g. during boot): only the last counts
  while IFS=' ' read -r -t 0.05 -u 3 r c; do
    rows="$r" cols="$c"
  done
  if ! valid "$rows" || ! valid "$cols"; then continue; fi
  [ "$(stty -F "$TTY" size 2>/dev/null)" = "$rows $cols" ] && continue
  stty -F "$TTY" rows "$rows" cols "$cols" 2>/dev/null || true
done
