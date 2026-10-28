#!/bin/bash
#
# archuninstall - removes what archopen-setup.sh installed on this Mac
#
# Asks about every item one by one (y/N), shows a summary, and only then
# removes the items you said yes to. You can, for example, keep QEMU or keep
# the virtual disk and remove everything else.
#
#   - Arch virtual disks (disk.qcow2, efi.qcow2, vars.fd): the Arch system and its files
#   - Download cache and logs (Alpine ISO, Arch tarball, install.log, versions.lock)
#   - Shell commands: archopen / archclose / archuninstall in ~/.zshrc (+ its backup)
#   - SSH host key of the VM in ~/.ssh/known_hosts
#   - Homebrew packages qemu and gnupg, then `brew autoremove`
#   - Homebrew itself, only if archopen installed it
#
# Usage:
#   archuninstall          ask item by item
#   archuninstall --all    remove everything without asking
#   bash <(curl -fsSL https://raw.githubusercontent.com/arifcinartekin/archsetupformac/main/mac/archuninstall.sh)
#
# Environment: ARCHOPEN_DIR (default: the directory of this script, else ~/vm/archarm)
#
set -euo pipefail

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

ZSHRC="$HOME/.zshrc"
ALIAS_BEGIN="# >>> archopen >>>"
ALIAS_END="# <<< archopen <<<"
ALL=0

SELF_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "${ARCHOPEN_DIR:-}" ]; then
  INSTALL_DIR="$ARCHOPEN_DIR"
elif [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/start-uefi.sh" ]; then
  INSTALL_DIR="$SELF_DIR"
else
  INSTALL_DIR="$HOME/vm/archarm"
fi
MANIFEST="$INSTALL_DIR/.archopen-manifest"

# Answers, filled in by ask_all
RM_DISKS=0 RM_CACHE=0 RM_ALIASES=0 RM_KNOWN_HOST=0
RM_QEMU=0 RM_GNUPG=0 RM_AUTOREMOVE=0 RM_BREW=0

ask() { # question -> 0 for yes
  local ans
  if [ "$ALL" = 1 ]; then
    printf '%s [y/N] y\n' "$1"
    return 0
  fi
  while :; do
    printf '%s [y/N] ' "$1" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in
      y|Y|yes|Yes) return 0 ;;
      ""|n|N|no|No) return 1 ;;
    esac
  done
}

manifest_get() { # key
  [ -f "$MANIFEST" ] || return 0
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print }' "$MANIFEST"
}

size_of() { du -shc "$@" 2>/dev/null | tail -n 1 | awk '{ print $1 }'; }

has_alias_block() { [ -f "$ZSHRC" ] && grep -qxF "$ALIAS_BEGIN" "$ZSHRC"; }

brew_has() { command -v brew >/dev/null 2>&1 && brew list --versions "$1" >/dev/null 2>&1; }

# Prints the pid of this install's QEMU, if it is running
vm_pid() {
  local pid
  pid="$(cat "$INSTALL_DIR/qemu.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && ps -p "$pid" -o command= 2>/dev/null | grep -qF "$INSTALL_DIR/disk.qcow2"; then
    printf '%s\n' "$pid"
    return 0
  fi
  # The installer VM and launchers from older versions have no pid file: match
  # QEMU processes by an absolute path into the install dir or by their cwd
  for pid in $(pgrep -f qemu-system-aarch64 2>/dev/null || true); do
    if ps -p "$pid" -o command= 2>/dev/null | grep -qF "$INSTALL_DIR/" \
       || [ "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$INSTALL_DIR" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

ask_all() {
  local ssh_port by_us note
  ssh_port="$(manifest_get ssh_port)"
  ssh_port="${ssh_port:-2222}"
  by_us=" $(manifest_get installed_formulae) "

  if [ -e "$INSTALL_DIR/disk.qcow2" ] || [ -e "$INSTALL_DIR/efi.qcow2" ]; then
    ask "Delete the Arch virtual disks ($(size_of "$INSTALL_DIR"/*.qcow2) - the Arch system and ALL files in it)?" && RM_DISKS=1
  fi
  if [ -d "$INSTALL_DIR/downloads" ] || [ -f "$INSTALL_DIR/install.log" ]; then
    ask "Delete the download cache and logs ($(size_of "$INSTALL_DIR/downloads") - Alpine ISO, Arch tarball, install.log)?" && RM_CACHE=1
  fi
  if has_alias_block; then
    ask "Remove the archopen / archclose / archuninstall commands from ~/.zshrc?" && RM_ALIASES=1
  fi
  if [ -f "$HOME/.ssh/known_hosts" ] && ssh-keygen -F "[localhost]:$ssh_port" >/dev/null 2>&1; then
    ask "Remove the VM's SSH host key ([localhost]:$ssh_port) from ~/.ssh/known_hosts?" && RM_KNOWN_HOST=1
  fi
  if brew_has qemu; then
    note=""
    case "$by_us" in *" qemu "*) ;; *) note=" (it was already installed before archopen)" ;; esac
    ask "Uninstall QEMU (brew uninstall qemu)$note?" && RM_QEMU=1
  fi
  if brew_has gnupg; then
    note=""
    case "$by_us" in *" gnupg "*) ;; *) note=" (it was already installed before archopen)" ;; esac
    ask "Uninstall GnuPG (brew uninstall gnupg)$note?" && RM_GNUPG=1
  fi
  if [ "$RM_QEMU" = 1 ] || [ "$RM_GNUPG" = 1 ]; then
    ask "Run 'brew autoremove' to drop dependencies nothing needs anymore?" && RM_AUTOREMOVE=1
  fi
  if [ "$(manifest_get installed_homebrew)" = 1 ] && command -v brew >/dev/null 2>&1; then
    ask "Uninstall Homebrew itself (archopen installed it; removes ALL brew packages)?" && RM_BREW=1
  fi
  return 0
}

print_plan() {
  printf '\n%sWill remove:%s\n' "$C_B" "$C_0"
  [ "$RM_DISKS" = 1 ]      && echo "  - virtual disks in $INSTALL_DIR"
  [ "$RM_CACHE" = 1 ]      && echo "  - download cache and logs in $INSTALL_DIR"
  [ "$RM_ALIASES" = 1 ]    && echo "  - archopen / archclose / archuninstall from ~/.zshrc, ~/.zshrc.archopen-backup"
  [ "$RM_KNOWN_HOST" = 1 ] && echo "  - VM SSH host key from ~/.ssh/known_hosts"
  [ "$RM_QEMU" = 1 ]       && echo "  - brew: qemu"
  [ "$RM_GNUPG" = 1 ]      && echo "  - brew: gnupg"
  [ "$RM_AUTOREMOVE" = 1 ] && echo "  - brew autoremove"
  [ "$RM_BREW" = 1 ]       && echo "  - Homebrew"
  printf '\n'
}

stop_leftovers() {
  local pid tries=0
  if [ -S "$INSTALL_DIR/qmp.sock" ] && [ -x "$INSTALL_DIR/archclose.sh" ] && vm_pid >/dev/null; then
    log "Shutting down the running Arch VM"
    "$INSTALL_DIR/archclose.sh" || true
  fi
  # Whatever is still running (older launcher, installer VM): stop it hard
  while pid="$(vm_pid)"; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || { warn "could not stop QEMU (pid $pid)"; break; }
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    ok "stopped QEMU (pid $pid)"
  done
  # Leftover local HTTP server of an interrupted install
  pkill -f "http.server.*/archopen\.[A-Za-z0-9]+/stage" 2>/dev/null && ok "stopped a leftover installer HTTP server" || true
}

remove_alias_block() {
  local tmp
  tmp="$(mktemp)"
  awk -v b="$ALIAS_BEGIN" -v e="$ALIAS_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$ZSHRC" > "$tmp"
  cat "$tmp" > "$ZSHRC"
  rm -f "$tmp"
}

do_remove() {
  if [ "$RM_DISKS" = 1 ] || [ "$RM_QEMU" = 1 ] || [ "$RM_BREW" = 1 ]; then
    stop_leftovers
  fi

  if [ "$RM_DISKS" = 1 ]; then
    rm -f "$INSTALL_DIR/disk.qcow2" "$INSTALL_DIR/efi.qcow2" "$INSTALL_DIR/vars.fd" \
          "$INSTALL_DIR/qmp.sock" "$INSTALL_DIR/qemu.pid" "$INSTALL_DIR/.archopen-incomplete"
    ok "virtual disks deleted"
  fi
  if [ "$RM_CACHE" = 1 ]; then
    rm -rf "$INSTALL_DIR/downloads"
    rm -f "$INSTALL_DIR/install.log" "$INSTALL_DIR/versions.lock"
    ok "download cache and logs deleted"
  fi
  if [ "$RM_ALIASES" = 1 ]; then
    remove_alias_block
    rm -f "$ZSHRC.archopen-backup"
    ok "commands removed from ~/.zshrc"
  fi
  if [ "$RM_KNOWN_HOST" = 1 ]; then
    ssh-keygen -R "[localhost]:$(manifest_get ssh_port | grep . || echo 2222)" >/dev/null 2>&1 || true
    ok "SSH host key removed"
  fi

  local f
  for f in qemu gnupg; do
    if { [ "$f" = qemu ] && [ "$RM_QEMU" = 1 ]; } || { [ "$f" = gnupg ] && [ "$RM_GNUPG" = 1 ]; }; then
      brew unpin "$f" >/dev/null 2>&1 || true
      if brew uninstall "$f"; then
        ok "$f uninstalled"
      else
        warn "brew uninstall $f failed (another package may depend on it)"
      fi
    fi
  done
  if [ "$RM_AUTOREMOVE" = 1 ]; then
    brew autoremove || warn "brew autoremove failed"
  fi
  if [ "$RM_BREW" = 1 ]; then
    log "Uninstalling Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" \
      || warn "Homebrew uninstall did not finish"
  fi

  # With disks, cache and commands gone, nothing of the install is left: remove the directory
  if [ "$RM_DISKS" = 1 ] && [ "$RM_CACHE" = 1 ] && { [ "$RM_ALIASES" = 1 ] || ! has_alias_block; }; then
    rm -rf "$INSTALL_DIR"
    rmdir "$(dirname "$INSTALL_DIR")" 2>/dev/null || true
    ok "$INSTALL_DIR removed"
  elif [ "$RM_DISKS" = 1 ] && [ "$RM_ALIASES" != 1 ]; then
    warn "the disks are gone, so 'archopen' will not work until you run the setup again"
  elif [ "$RM_DISKS" != 1 ] && [ "$RM_ALIASES" = 1 ]; then
    echo "  The VM is kept. Start it with: $INSTALL_DIR/start-uefi.sh"
  fi
}

main() {
  case "${1:-}" in
    "")        ;;
    --all|-y)  ALL=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown option: $1 (help: --help)" ;;
  esac
  [ "$(uname -s)" = "Darwin" ] || die "archuninstall runs on macOS."
  if [ "$ALL" != 1 ] && [ ! -r /dev/tty ]; then
    die "no terminal to ask questions on; use --all to remove everything"
  fi
  if command -v brew >/dev/null 2>&1; then
    :
  elif [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  printf '\n%sarchuninstall%s: removing archopen from this Mac (%s)\n\n' "$C_B" "$C_0" "$INSTALL_DIR"
  ask_all
  if [ "$RM_DISKS$RM_CACHE$RM_ALIASES$RM_KNOWN_HOST$RM_QEMU$RM_GNUPG$RM_AUTOREMOVE$RM_BREW" = "00000000" ]; then
    echo "Nothing selected, nothing removed."
    exit 0
  fi
  print_plan
  if [ "$ALL" != 1 ]; then
    ask "Proceed?" || { echo "Cancelled, nothing removed."; exit 0; }
  fi
  do_remove

  printf '\n%sDone.%s\n' "$C_B" "$C_0"
  if [ "$RM_ALIASES" = 1 ]; then
    echo "Open a new terminal (or run: unalias archopen archclose archuninstall) so the commands disappear from this one."
  fi
}

# main is called last: the whole file is read before this script may delete itself
main "$@"
