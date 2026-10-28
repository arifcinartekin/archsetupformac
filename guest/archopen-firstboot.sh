#!/usr/bin/env bash
#
# archopen-firstboot - first-boot wizard inside the Arch VM
#
# Installed by archopen-setup.sh as /usr/local/sbin/archopen-firstboot and
# started automatically on the first interactive root login (root / root):
#
#   1) Creates your user, adds it to wheel and grants sudo
#   2) Optionally runs zsh_setup.sh for that user (zsh, Oh My Zsh, Powerlevel10k)
#   3) Optionally installs htop, and fastfetch with an `info` alias that also
#      runs at every login
#   4) Optionally removes the default `alarm` account (password: alarm)
#   5) LOCKS the root password (passwd -l), only once sudo is verified
#   6) Removes its own login hook
#
# Ctrl+C aborts without changes to the hook; it runs again at the next root login.
#
# Usage:
#   archopen-firstboot              run the wizard
#   archopen-firstboot --enable     run it at the next interactive root login
#   archopen-firstboot --disable    do not run it at login anymore
#
set -euo pipefail

PROFILE="/root/.bash_profile"
HOOK_BEGIN="# >>> archopen firstboot >>>"
HOOK_END="# <<< archopen firstboot <<<"
INFO_BEGIN="# >>> archopen info >>>"
INFO_END="# <<< archopen info <<<"
ZSH_SETUP="/usr/local/share/archopen/zsh_setup.sh"
TEMP_SUDOERS="/etc/sudoers.d/99-archopen-firstboot"
SSH_PORT="${ARCHOPEN_SSH_PORT:-2222}"

NEW_USER=""
DO_ZSH=1
DO_HTOP=1
DO_FASTFETCH=1
REMOVE_ALARM=0

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Login hook
# ----------------------------------------------------------------------------

remove_hook() {
  [ -f "$PROFILE" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v b="$HOOK_BEGIN" -v e="$HOOK_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$PROFILE" > "$tmp"
  cat "$tmp" > "$PROFILE"
  rm -f "$tmp"
}

enable_hook() {
  if [ ! -f "$PROFILE" ]; then
    printf '#\n# ~/.bash_profile\n#\n\n[[ -f ~/.bashrc ]] && . ~/.bashrc\n' > "$PROFILE"
  fi
  remove_hook
  {
    printf '%s\n' "$HOOK_BEGIN"
    printf 'if [ -t 0 ] && [ -x /usr/local/sbin/archopen-firstboot ]; then\n'
    printf '  /usr/local/sbin/archopen-firstboot && logout\n'
    printf 'fi\n'
    printf '%s\n' "$HOOK_END"
  } >> "$PROFILE"
}

# ----------------------------------------------------------------------------
# Wizard
# ----------------------------------------------------------------------------

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; }
pw_status() { passwd -S "$1" 2>/dev/null | awk '{print $2}'; }

ask_yes_no() { # question default(y|n)
  local ans hint="[Y/n]"
  [ "$2" = "n" ] && hint="[y/N]"
  while :; do
    printf '%s %s ' "$1" "$hint"
    IFS= read -r ans || ans=""
    case "${ans:-$2}" in
      y|Y|yes|Yes) return 0 ;;
      n|N|no|No)   return 1 ;;
    esac
  done
}

cleanup() { rm -f "$TEMP_SUDOERS"; }

on_interrupt() {
  printf '\n'
  warn "Aborted. The wizard will start again at the next root login."
  exit 130
}

ask_questions() {
  local name
  while :; do
    printf 'Username for your account [user]: '
    IFS= read -r name || name=""
    name="${name:-user}"
    if [ "$name" = "root" ]; then
      warn "Pick a name other than root."
    elif valid_name "$name"; then
      break
    else
      warn "Invalid username: lowercase letters, digits, - and _ (max 32 characters)."
    fi
  done
  NEW_USER="$name"

  if [ -f "$ZSH_SETUP" ]; then
    ask_yes_no "Set up zsh + Oh My Zsh + Powerlevel10k for $NEW_USER?" y && DO_ZSH=1 || DO_ZSH=0
  else
    DO_ZSH=0
  fi

  ask_yes_no "Install htop (interactive process viewer)?" y && DO_HTOP=1 || DO_HTOP=0
  ask_yes_no "Install fastfetch (system info, 'info' command, shown at every login)?" y && DO_FASTFETCH=1 || DO_FASTFETCH=0

  if [ "$NEW_USER" != "alarm" ] && id alarm >/dev/null 2>&1; then
    ask_yes_no "Remove the default 'alarm' account (its password is 'alarm')?" y && REMOVE_ALARM=1 || REMOVE_ALARM=0
  fi
}

create_user() {
  log "User: $NEW_USER"
  local shell=/bin/bash
  if [ "$DO_ZSH" = 1 ] && [ -x /usr/bin/zsh ]; then
    # With zsh already the login shell, zsh_setup.sh does not need to call chsh
    shell=/usr/bin/zsh
  fi
  getent group wheel >/dev/null 2>&1 || groupadd wheel
  if id "$NEW_USER" >/dev/null 2>&1; then
    usermod -aG wheel -s "$shell" "$NEW_USER"
    ok "user already existed, added to wheel"
  else
    useradd -m -G wheel -s "$shell" "$NEW_USER"
    ok "user created (wheel)"
  fi

  local tries=0
  while [ "$(pw_status "$NEW_USER")" != "P" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 5 ] || die "no valid password was set for $NEW_USER"
    printf 'Set a password for %s:\n' "$NEW_USER"
    passwd "$NEW_USER" || warn "try again"
  done
  ok "password set"
}

setup_sudo() {
  log "sudo for wheel"
  if ! command -v sudo >/dev/null 2>&1; then
    pacman -S --needed --noconfirm sudo
  fi
  grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
    || die "/etc/sudoers does not include sudoers.d; fix it by hand (visudo)"
  local tmp
  tmp="$(mktemp)"
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "invalid sudoers file"; }
  install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/10-wheel
  rm -f "$tmp"
  visudo -c >/dev/null || die "sudoers could not be validated"

  if sudo -l -U "$NEW_USER" 2>/dev/null | grep -Eq '\(ALL *: *ALL\) +ALL'; then
    SUDO_OK=1
    ok "$NEW_USER can use sudo"
  else
    SUDO_OK=0
    warn "sudo access for $NEW_USER could not be verified"
  fi
}

run_zsh_setup() {
  [ "$DO_ZSH" = 1 ] || return 0
  log "zsh setup for $NEW_USER"
  # zsh_setup.sh calls sudo for pacman; no password prompts while it runs
  local tmp
  tmp="$(mktemp)"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$tmp"
  if visudo -cf "$tmp" >/dev/null; then
    install -m 0440 -o root -g root "$tmp" "$TEMP_SUDOERS"
  fi
  rm -f "$tmp"

  # The serial console reports vt220; the Mac terminal behind it handles more
  case "${TERM:-}" in
    ""|dumb|vt100|vt220|linux) export TERM=xterm-256color ;;
  esac
  echo "  The Powerlevel10k configuration wizard starts at the end."
  if su -l "$NEW_USER" -c "sh $ZSH_SETUP"; then
    ok "zsh setup finished"
  else
    warn "zsh setup did not finish; run it later as $NEW_USER: sh $ZSH_SETUP"
  fi
  rm -f "$TEMP_SUDOERS"
}

install_tools() {
  local pkgs=()
  [ "$DO_HTOP" = 1 ] && pkgs+=(htop)
  [ "$DO_FASTFETCH" = 1 ] && pkgs+=(fastfetch)
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  log "Packages: ${pkgs[*]}"
  if pacman -Syu --needed --noconfirm "${pkgs[@]}"; then
    ok "installed: ${pkgs[*]}"
  else
    warn "pacman failed; install them later with: sudo pacman -S ${pkgs[*]}"
  fi
}

# append_block <file> <text>: replaces the archopen info block in a file of the new user
append_block() {
  local file="$1" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v b="$INFO_BEGIN" -v e="$INFO_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$file" > "$tmp"
  fi
  printf '%s\n%s\n%s\n' "$INFO_BEGIN" "$2" "$INFO_END" >> "$tmp"
  install -m 0644 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$tmp" "$file"
  rm -f "$tmp"
}

setup_info() {
  [ "$DO_FASTFETCH" = 1 ] && command -v fastfetch >/dev/null 2>&1 || return 0
  log "'info' command"
  local home rc profile
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  if [ "$(getent passwd "$NEW_USER" | cut -d: -f7)" = /usr/bin/zsh ]; then
    rc="$home/.zshrc"
    # .zprofile runs before .zshrc, so the output does not upset Powerlevel10k's instant prompt
    profile="$home/.zprofile"
  else
    rc="$home/.bashrc"
    profile="$home/.bash_profile"
  fi
  append_block "$rc" "alias info='fastfetch'"
  append_block "$profile" '[ -t 1 ] && command -v fastfetch >/dev/null 2>&1 && fastfetch'
  ok "'info' runs fastfetch; it also runs at every login ($(basename "$profile"))"
}

remove_alarm() {
  [ "$REMOVE_ALARM" = 1 ] || return 0
  log "Default 'alarm' account"
  pkill -KILL -u alarm 2>/dev/null || true
  if userdel -r alarm 2>/dev/null; then
    ok "alarm removed"
  else
    warn "alarm could not be removed (remove it later: sudo userdel -r alarm)"
  fi
}

lock_root() {
  log "root account"
  if [ "$(pw_status root)" = "L" ]; then
    ok "root is already locked"
  elif [ "$SUDO_OK" = 1 ] && [ "$(pw_status "$NEW_USER")" = "P" ]; then
    passwd -l root >/dev/null
    ok "root password locked (use sudo -i from now on; undo: sudo passwd root)"
  else
    warn "root was NOT locked: sudo has to work first, so you do not lock yourself out"
  fi
}

run_wizard() {
  [ "$(id -u)" -eq 0 ] || die "run as root"
  command -v useradd >/dev/null 2>&1 || die "useradd not found; this script is for the Arch VM"
  [ -t 0 ] || die "a terminal is required"

  trap cleanup EXIT
  trap on_interrupt INT TERM

  printf '\n%sWelcome to Arch Linux ARM (%s)%s\n' "$C_B" "$(uname -n)" "$C_0"
  printf 'This one-time setup creates your own account and then locks root.\n'
  printf 'Press Ctrl+C to skip it for now.\n\n'

  SUDO_OK=0
  ask_questions
  create_user
  setup_sudo
  install_tools
  run_zsh_setup
  setup_info
  remove_alarm
  lock_root
  remove_hook

  printf '\n%sDone.%s Log in as %s%s%s from now on.\n' "$C_B" "$C_0" "$C_B" "$NEW_USER" "$C_0"
  printf '  SSH from the Mac : ssh -p %s %s@localhost\n' "$SSH_PORT" "$NEW_USER"
  printf '  Shut down       : archclose (on the Mac) or sudo poweroff\n\n'
  printf 'Press Enter to log out. '
  IFS= read -r _ || true
}

case "${1:-}" in
  --enable)  enable_hook ;;
  --disable) remove_hook ;;
  "")        run_wizard ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)         die "unknown option: $1 (help: --help)" ;;
esac
