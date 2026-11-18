#!/usr/bin/env bash
#
# archopen-firstboot - first-boot wizard inside the Arch VM
#
# Installed by archopen-setup.sh as /usr/local/sbin/archopen-firstboot. The
# installer has already created your user (wheel, sudo), locked root, removed
# the default `alarm` account and made sudo password-free on the serial
# console. The wizard starts by itself at your first login on the console
# (through sudo) and:
#
#   1) Optionally runs zsh_setup.sh for you (zsh, Oh My Zsh, Powerlevel10k)
#   2) Optionally installs htop, fastfetch with an `info` alias that also
#      runs at every login, and lsd (ls, ll, la, lt use it)
#   3) Optionally installs Cockpit, the web admin panel (https://localhost:9090
#      on the Mac, forwarded by archopen)
#   4) Optionally sets up the ly login screen on the console
#   5) Removes its own login hook
#
# Ctrl+C aborts; it runs again at the next login on the console.
#
# Usage:
#   sudo archopen-firstboot              run the wizard
#   sudo archopen-firstboot --enable     run it at the next login on the console
#   sudo archopen-firstboot --disable    do not run it at login anymore
#   sudo archopen-firstboot --login-screen ly|console
#                                        ly login screen, or the plain console login
#   sudo archopen-firstboot --cockpit-python
#                                        make sure cockpit-bridge loads (run by a pacman hook)
#
set -euo pipefail

HOOK="/etc/profile.d/archopen-firstboot.sh"
CONF="/etc/archopen.conf"
INFO_BEGIN="# >>> archopen info >>>"
INFO_END="# <<< archopen info <<<"
LSD_BEGIN="# >>> archopen lsd >>>"
LSD_END="# <<< archopen lsd <<<"
ZSH_SETUP="/usr/local/share/archopen/zsh_setup.sh"
TEMP_SUDOERS="/etc/sudoers.d/99-archopen-firstboot"
# The serial console the Mac terminal is attached to (console=ttyAMA0)
CONSOLE_TTY="ttyAMA0"
LY_CONFIG="/etc/ly/config.ini"
SHELL_SESSION="/usr/local/bin/archopen-shell-session"
COCKPIT_PKGS=(cockpit cockpit-storaged cockpit-files)
COCKPIT_PYDIR="/usr/local/lib/archopen/cockpit-python"
COCKPIT_PTH="archopen-cockpit.pth"

NEW_USER=""
DO_ZSH=1
DO_HTOP=1
DO_FASTFETCH=1
DO_LSD=1
DO_COCKPIT=1
DO_LY=1

if [ -t 1 ]; then
  C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
log()  { printf '\n%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

# conf_get <key> <default>: a value the installer recorded in /etc/archopen.conf
conf_get() {
  local v=""
  [ -r "$CONF" ] && v="$(awk -F= -v k="$1" '$1 == k { print $2; exit }' "$CONF")"
  printf '%s' "${v:-$2}"
}
SSH_PORT="$(conf_get ARCHOPEN_SSH_PORT 2222)"
COCKPIT_PORT="$(conf_get ARCHOPEN_COCKPIT_PORT 9090)"

# ----------------------------------------------------------------------------
# Login hook: /etc/profile.d is read by bash and (through /etc/zsh/zprofile) zsh
# ----------------------------------------------------------------------------

remove_hook() { rm -f "$HOOK"; }

enable_hook() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  cat > "$HOOK" <<HOOK_EOF
# archopen first-boot wizard: removed by the wizard once it has run.
# Interactive login shells on the serial console only (sudo needs no password there)
case "\$-" in
  *i*)
    if [ "\$(id -u)" -ne 0 ] && [ "\$(tty 2>/dev/null)" = "/dev/$CONSOLE_TTY" ] \\
       && [ -x /usr/local/sbin/archopen-firstboot ]; then
      sudo /usr/local/sbin/archopen-firstboot && exit
    fi
    ;;
esac
HOOK_EOF
  chmod 644 "$HOOK"
}

# ----------------------------------------------------------------------------
# Wizard
# ----------------------------------------------------------------------------

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
  warn "Aborted. The wizard will start again at the next login on the console."
  exit 130
}

# The user the wizard sets things up for: the one the installer created
find_user() {
  NEW_USER="$(conf_get ARCHOPEN_USER "${SUDO_USER:-}")"
  [ -n "$NEW_USER" ] && [ "$NEW_USER" != root ] || die "no user to set up; run it with sudo as your user"
  id "$NEW_USER" >/dev/null 2>&1 || die "user $NEW_USER does not exist"
}

ask_questions() {
  if [ -f "$ZSH_SETUP" ]; then
    ask_yes_no "Set up zsh + Oh My Zsh + Powerlevel10k for $NEW_USER?" y && DO_ZSH=1 || DO_ZSH=0
  else
    DO_ZSH=0
  fi
  ask_yes_no "Install htop (interactive process viewer)?" y && DO_HTOP=1 || DO_HTOP=0
  ask_yes_no "Install fastfetch (system info, 'info' command, shown at every login)?" y && DO_FASTFETCH=1 || DO_FASTFETCH=0
  ask_yes_no "Install lsd (ls with colors and icons; ls, ll, la, lt use it)?" y && DO_LSD=1 || DO_LSD=0
  ask_yes_no "Install Cockpit (web admin panel, https://localhost:$COCKPIT_PORT on the Mac)?" y && DO_COCKPIT=1 || DO_COCKPIT=0
  ask_yes_no "Use the ly login screen instead of the plain console login?" y && DO_LY=1 || DO_LY=0
}

run_zsh_setup() {
  [ "$DO_ZSH" = 1 ] || return 0
  log "zsh setup for $NEW_USER"
  # With zsh already the login shell, zsh_setup.sh does not need to call chsh
  if [ -x /usr/bin/zsh ]; then
    usermod -s /usr/bin/zsh "$NEW_USER"
  fi
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
  [ "$DO_LSD" = 1 ] && pkgs+=(lsd)
  [ "$DO_COCKPIT" = 1 ] && pkgs+=("${COCKPIT_PKGS[@]}")
  [ "$DO_LY" = 1 ] && pkgs+=(ly)
  [ "${#pkgs[@]}" -gt 0 ] || return 0
  log "Packages: ${pkgs[*]}"
  if pacman -Syu --needed --noconfirm "${pkgs[@]}"; then
    ok "installed: ${pkgs[*]}"
  else
    warn "pacman failed; install them later with: sudo pacman -S ${pkgs[*]}"
  fi
}

# append_block <file> <begin> <end> <text>: replaces that archopen block in a file of the user
append_block() {
  local file="$1" begin="$2" end="$3" tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$file" > "$tmp"
  fi
  printf '%s\n%s\n%s\n' "$begin" "$4" "$end" >> "$tmp"
  install -m 0644 -o "$NEW_USER" -g "$(id -gn "$NEW_USER")" "$tmp" "$file"
  rm -f "$tmp"
}

# user_rc_files: sets USER_RC and USER_PROFILE for the user's login shell
user_rc_files() {
  local home
  home="$(getent passwd "$NEW_USER" | cut -d: -f6)"
  if [ "$(getent passwd "$NEW_USER" | cut -d: -f7)" = /usr/bin/zsh ]; then
    USER_RC="$home/.zshrc"
    # .zprofile runs before .zshrc, so the output does not upset Powerlevel10k's instant prompt
    USER_PROFILE="$home/.zprofile"
  else
    USER_RC="$home/.bashrc"
    USER_PROFILE="$home/.bash_profile"
  fi
}

setup_info() {
  [ "$DO_FASTFETCH" = 1 ] && command -v fastfetch >/dev/null 2>&1 || return 0
  log "'info' command"
  user_rc_files
  append_block "$USER_RC" "$INFO_BEGIN" "$INFO_END" "alias info='fastfetch'"
  append_block "$USER_PROFILE" "$INFO_BEGIN" "$INFO_END" \
    '[ -t 1 ] && command -v fastfetch >/dev/null 2>&1 && fastfetch'
  ok "'info' runs fastfetch; it also runs at every login ($(basename "$USER_PROFILE"))"
}

setup_lsd() {
  [ "$DO_LSD" = 1 ] && command -v lsd >/dev/null 2>&1 || return 0
  log "lsd aliases"
  user_rc_files
  # Appended after zsh_setup has written .zshrc, so these win over Oh My Zsh's ll/la
  append_block "$USER_RC" "$LSD_BEGIN" "$LSD_END" "$(printf '%s\n' \
    "alias ls='lsd'" \
    "alias ll='lsd -l'" \
    "alias la='lsd -la'" \
    "alias lt='lsd --tree'")"
  ok "ls, ll, la, lt use lsd ($(basename "$USER_RC"))"
}

# The Arch Linux ARM cockpit package can lag behind a Python update: built for
# python3.13 while python is 3.14, cockpit-bridge then dies with "No module named
# 'cockpit'" and every login fails. If so, the package's own module is made
# visible to the current Python through a .pth file and a symlink in /usr/local,
# nothing pacman owns. Once a rebuilt package is importable on its own, the
# shim is removed. A pacman hook runs this after every cockpit or python update.
cockpit_python() {
  pacman -Q cockpit >/dev/null 2>&1 || return 0
  rm -f /usr/lib/python3*/site-packages/"$COCKPIT_PTH"
  if python3 -c 'import cockpit.bridge' >/dev/null 2>&1; then
    rm -rf "$COCKPIT_PYDIR"
    return 0
  fi
  local src site
  src="$(pacman -Qlq cockpit | grep -m1 -E '^/usr/lib/python3\.[0-9]+/site-packages/cockpit/$' || true)"
  src="${src%/}"
  site="$(python3 -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || true)"
  if [ -z "$src" ] || [ ! -d "$src" ] || [ ! -d "$site" ]; then
    warn "cockpit's Python module was not found; Cockpit logins will fail"
    return 1
  fi
  mkdir -p "$COCKPIT_PYDIR"
  ln -sfn "$src" "$COCKPIT_PYDIR/cockpit"
  printf '%s\n' "$COCKPIT_PYDIR" > "$site/$COCKPIT_PTH"
  if python3 -c 'import cockpit.bridge' >/dev/null 2>&1; then
    ok "cockpit's module ($src) made visible to $(python3 --version 2>&1) until the package is rebuilt"
  else
    warn "cockpit's module could not be loaded by $(python3 --version 2>&1); Cockpit logins will fail"
    return 1
  fi
}

install_cockpit_hook() {
  mkdir -p /etc/pacman.d/hooks
  cat > /etc/pacman.d/hooks/90-archopen-cockpit-python.hook <<'PACHOOK_EOF'
# archopen: keeps cockpit-bridge loadable when python and cockpit are out of step
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = cockpit
Target = python

[Action]
Description = Checking that Cockpit's Python module loads (archopen)...
When = PostTransaction
Exec = /usr/local/sbin/archopen-firstboot --cockpit-python
PACHOOK_EOF
}

setup_cockpit() {
  [ "$DO_COCKPIT" = 1 ] || return 0
  log "Cockpit"
  if ! pacman -Q cockpit >/dev/null 2>&1; then
    warn "cockpit is not installed; later: sudo pacman -S ${COCKPIT_PKGS[*]} && sudo systemctl enable --now cockpit.socket"
    return 0
  fi
  install_cockpit_hook
  cockpit_python || true
  # Socket activation: cockpit-ws only runs while the panel is in use
  if systemctl enable --now cockpit.socket >/dev/null 2>&1; then
    COCKPIT_OK=1
    ok "https://localhost:$COCKPIT_PORT on the Mac, log in as $NEW_USER (self-signed certificate: the browser warns once)"
  else
    warn "cockpit.socket could not be started (sudo systemctl status cockpit.socket)"
  fi
}

# ----------------------------------------------------------------------------
# Login screen (ly on the serial console)
# ----------------------------------------------------------------------------

# ly_set <option> <value>: one option of ly's config.ini
ly_set() {
  if grep -q "^$1 = " "$LY_CONFIG"; then
    sed -i "s|^$1 = .*|$1 = $2|" "$LY_CONFIG"
  else
    warn "ly has no option '$1' (newer version?), skipped"
  fi
}

configure_ly() {
  [ -f "$LY_CONFIG" ] || { warn "$LY_CONFIG not found, is ly installed?"; return 1; }
  # A serial line has no keyboard LEDs and no backlight; there is no X server
  ly_set hide_keyboard_locks true
  ly_set brightness_down_key null
  ly_set brightness_up_key null
  ly_set xinitrc null
  ly_set clock '%a %d %b  %H:%M'
  ly_set bigclock en
  # ly would send the shell's output to this log instead of the terminal
  ly_set session_log null

  # The session to log into: your login shell, in this terminal
  cat > "$SHELL_SESSION" <<'SESSION_EOF'
#!/bin/sh
# Shell session for ly on the serial console (archopen). ly sends a session's
# output to a log file, which suits graphical sessions; a shell needs the terminal.
exec >/dev/tty 2>&1
printf '\033[H\033[2J'
exec "${SHELL:-/bin/bash}" -l
SESSION_EOF
  chmod 755 "$SHELL_SESSION"
  mkdir -p /etc/ly/custom-sessions
  cat > /etc/ly/custom-sessions/shell.desktop <<SESSION_EOF
[Desktop Entry]
Name=Shell
Comment=Your login shell in this terminal
Exec=$SHELL_SESSION
Type=Application
SESSION_EOF
}

# login_screen ly|console: what greets you on the console from the next boot on
login_screen() {
  case "$1" in
    ly)
      command -v ly-dm >/dev/null 2>&1 || pacman -S --needed --noconfirm ly
      configure_ly || return 1
      # The console getty comes from a generator (console=ttyAMA0): mask, not disable
      systemctl enable "ly@$CONSOLE_TTY.service" >/dev/null 2>&1 || return 1
      systemctl mask "serial-getty@$CONSOLE_TTY.service" >/dev/null 2>&1 \
        || { systemctl disable "ly@$CONSOLE_TTY.service" >/dev/null 2>&1; return 1; }
      ;;
    console)
      systemctl disable "ly@$CONSOLE_TTY.service" >/dev/null 2>&1 || true
      systemctl unmask "serial-getty@$CONSOLE_TTY.service" >/dev/null 2>&1 || die "could not unmask serial-getty@$CONSOLE_TTY"
      ;;
    *) die "usage: sudo archopen-firstboot --login-screen ly|console" ;;
  esac
}

# Swaps the console over right away. This ends the session on the console, so
# it runs outside it, from systemd
switch_console() { # ly|console
  local stop="ly@$CONSOLE_TTY.service" start="serial-getty@$CONSOLE_TTY.service"
  if [ "$1" = ly ]; then
    stop="serial-getty@$CONSOLE_TTY.service" start="ly@$CONSOLE_TTY.service"
  fi
  systemd-run --quiet --no-block --collect /bin/sh -c "sleep 1; systemctl stop $stop; systemctl start $start" >/dev/null
}

setup_login_screen() {
  [ "$DO_LY" = 1 ] || return 0
  log "Login screen"
  if login_screen ly; then
    LY_OK=1
    ok "ly greets you on the console from now on (back to the plain login: sudo archopen-firstboot --login-screen console)"
  else
    warn "ly could not be set up; the plain console login stays"
  fi
}

set_login_screen() { # ly|console, from the command line
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  login_screen "$1"
  if [ -t 0 ] && [ "$(tty 2>/dev/null)" = "/dev/$CONSOLE_TTY" ]; then
    echo "Login screen: $1, from the next boot on."
    ask_yes_no "Switch the console now? This ends this console session." n && switch_console "$1"
  else
    switch_console "$1"
    echo "Login screen: $1. The console has switched over."
  fi
}

run_wizard() {
  [ "$(id -u)" -eq 0 ] || die "run it with sudo: sudo archopen-firstboot"
  [ -t 0 ] || die "a terminal is required"
  find_user

  trap cleanup EXIT
  trap on_interrupt INT TERM

  printf '\n%sWelcome to Arch Linux ARM (%s), %s%s\n' "$C_B" "$(uname -n)" "$NEW_USER" "$C_0"
  printf 'This one-time setup installs a few optional tools.\n'
  printf 'Press Ctrl+C to skip it for now.\n\n'

  LY_OK=0
  COCKPIT_OK=0
  ask_questions
  install_tools
  run_zsh_setup
  setup_info
  setup_lsd
  setup_cockpit
  setup_login_screen
  remove_hook

  printf '\n%sDone.%s\n' "$C_B" "$C_0"
  printf '  SSH from the Mac    : ssh -p %s %s@localhost\n' "$SSH_PORT" "$NEW_USER"
  if [ "$COCKPIT_OK" = 1 ]; then
    printf '  Cockpit on the Mac  : https://localhost:%s  (log in as %s)\n' "$COCKPIT_PORT" "$NEW_USER"
  fi
  printf '  root                : locked; sudo works without a password on this console only\n'
  printf '  Shut down           : archclose (on the Mac) or sudo poweroff\n\n'
  if [ "$LY_OK" = 1 ]; then
    printf 'Press Enter to go to the login screen. '
    IFS= read -r _ || true
    switch_console ly
  else
    printf 'Press Enter to log out. '
    IFS= read -r _ || true
  fi
}

case "${1:-}" in
  --enable)  enable_hook ;;
  --disable) [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; remove_hook ;;
  --login-screen) set_login_screen "${2:-}" ;;
  --cockpit-python) [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; cockpit_python ;;
  "")        run_wizard ;;
  -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)         die "unknown option: $1 (help: --help)" ;;
esac
