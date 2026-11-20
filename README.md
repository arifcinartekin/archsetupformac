<div align="center">

# Arch Setup for Mac

**Arch Linux ARM on Apple Silicon Macs, in one command.**

*QEMU + HVF, UEFI boot via systemd-boot, LUKS2-encrypted btrfs, an integrity seal checked before every boot, verified downloads, a first-boot wizard, and the commands you'll actually use: `archopen`, `archclose`, `archuninstall`, `archseal`.*

![Platform: macOS Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Guest: Arch Linux ARM aarch64](https://img.shields.io/badge/guest-Arch%20Linux%20ARM-1793d1)
![Shell: bash](https://img.shields.io/badge/shell-bash-blue)

</div>

---

## 🚀 Install

```bash
bash <(curl -fsSL https://arch.arifcinartekin.me/install)
```

That's it. `/install` is `archopen-setup.sh` from `main`, published by GitHub Pages (the same file is at `raw.githubusercontent.com/arifcinartekin/archsetupformac/main/archopen-setup.sh`). No checksum to paste and no "latest" that breaks next week: the Arch tarball is pinned and mirrored in this repo's [releases](../../releases).

Early on it asks for a **disk passphrase**: the Arch disk is encrypted with LUKS2 and you type this passphrase at every boot. There is no way to recover the data without it.

When it finishes, it offers to start Arch right away. Enter the disk passphrase, then log in as **`user`** with password **`user`**; you pick a new password right away. The first-boot wizard takes over from there. There is no root login at all: root is locked from the install on, and `sudo` needs no password on the serial console (the terminal running `archopen`).

> Takes roughly 10–20 minutes, mostly downloads and `pacman -Syu`. You need about 3 GB of free disk space to start; the VM disk grows up to 20 GB as you use it.

---

## 🧰 Commands

| Command | Where | What it does |
|---|---|---|
| `archopen` | Mac | Checks the VM files against the integrity seal, then boots Arch in the current terminal (serial console, no window). Resizing the terminal window resizes the console inside Arch too. Refuses to boot if a file changed |
| `archclose` | Mac | Shuts Arch down cleanly from another terminal: presses the VM's power button, falls back to a hard stop after 90 s. `archclose --force` stops it immediately |
| `archuninstall` | Mac | Removes what the setup installed. Asks about each item separately, so you can keep QEMU or the VM disk and remove the rest |
| `archseal verify` / `archseal accept` | Mac | Checks the seal by hand / shows what changed and seals the current state after you confirm |
| `ssh -p 2222 user@localhost` | Mac | SSH into the running VM (bound to `127.0.0.1` only) |

Inside the VM, `sudo poweroff` works too, and so does <kbd>Ctrl</kbd>+<kbd>A</kbd> then <kbd>X</kbd> (instant hard stop). <kbd>Ctrl</kbd>+<kbd>C</kbd> goes to the program running inside Arch, as in any terminal; it does not stop the VM.

---

## 🪄 What happens

```
Mac                                         VM
───────────────────────────────────────────────────────────────────────────
1. Homebrew, qemu, gnupg (only if missing)
   ask for the disk passphrase
2. Alpine ISO   → sha256 pin + GPG ✓
   Arch tarball → sha256 pin + GPG ✓
3. Boot a throwaway Alpine VM ───────────▶  ESP (FAT32); root: LUKS2 (argon2id)
   (driven over the serial console          → btrfs, subvolumes @ @home @log @pkg
    with expect, no clicking; the           extract the Arch tarball
    passphrase is typed with echo off)      chroot: pacman keyring, pacman -Syu,
                                            sudo/zsh/git…, initramfs with LUKS
                                            unlock, systemd-boot, fstab,
                                            hostname "arch", terminfo, user
                                            "user" (wheel), alarm removed,
                                            root locked
4. Seal the VM files (Keychain)
   Boot via the launcher: seal check ────▶  unlock the disk, log in as user, check
                                            kernel / ESP / btrfs on LUKS / hostname /
                                            sshd / root locked / sudo password-free
                                            on the console only, arm the first-boot
                                            wizard, expire the temporary password
   seal again after the shutdown
5. Add archopen / archclose / archuninstall
   / archseal to ~/.zshrc
```

### Accounts and sudo

The installer creates your account, **`user`** (`ARCHOPEN_USER` to pick another name), in `wheel`, removes the tarball's default `alarm` account (its password is publicly known) and **locks root**: no root login on the console, none over SSH. Use `sudo -i` for a root shell.

`sudo` needs **no password on the serial console**, the terminal running `archopen`: that terminal already sits behind your Mac login, the integrity seal and the disk passphrase. Everywhere else (SSH, another terminal) it asks for your password. A PAM rule in `/etc/pam.d/sudo` does this by matching the terminal (`ttyAMA0`); the verification boot checks both sides.

The temporary password `user` expires once the install has checked everything: the first login asks for it once more and then for a new one.

### First boot wizard

At your first login on the console a one-time wizard starts (through `sudo`) and asks, `y/n` each:

1. [**zsh_setup**](https://github.com/arifcinartekin/zsh_setup) for you: zsh, Oh My Zsh, Powerlevel10k, autosuggestions, syntax highlighting. The p10k configuration wizard runs at the end
2. **htop**, **fastfetch** with an `info` command, and [**lsd**](https://github.com/lsd-rs/lsd) (`ls` with colors and icons). fastfetch also runs at every login, so you see the system info each time you `archopen`. With lsd, `ls`, `ll`, `la` and `lt` (tree) use it
3. [**ly**](https://github.com/fairyglade/ly) as the login screen on the console (big clock, user and session picker; <kbd>F1</kbd> shuts down, <kbd>F2</kbd> reboots)

Then it removes itself and logs you out, onto the ly login screen if you chose it. Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to skip it; it runs again at the next login on the console.

> 💡 Powerlevel10k icons need a Nerd Font **in your Mac terminal**, e.g. *MesloLGS NF* (Ghostty ships a Nerd Font by default).

---

## 🔐 Encryption and the integrity seal

**The disk.** The Arch root sits on a LUKS2 volume (aes-xts, argon2id) with btrfs inside it (`@` → `/`, `@home`, `@log` → `/var/log`, `@pkg` → `/var/cache/pacman/pkg`, zstd compression). The initramfs asks for the passphrase on the serial console at every boot. Without the passphrase, `disk.qcow2` is unreadable, whoever copies it.

**The problem LUKS does not solve.** The boot chain cannot be encrypted: the UEFI firmware, its variables, the ESP with systemd-boot, the kernel and the initramfs are plain files in `~/vm/archarm`. Anyone who can change `efi.qcow2` can put in an initramfs that records your passphrase the next time you type it, and LUKS then protects nothing.

**The seal.** `archopen` checks every file in the install directory before it starts QEMU:

- each file's sha256, size and mode: `efi.qcow2`, `disk.qcow2`, `vars.fd`, `efi-code.fd` (a private copy of the UEFI firmware), `start-uefi.sh`, `archclose.sh`, `archuninstall.sh`, `archseal.sh`. A file that was **added** or **removed** counts as a change too
- the digest of that list is kept in your **macOS login Keychain**, not next to the files. Replacing `efi.qcow2` together with the list next to it is not enough to get through the check
- one changed file and **QEMU is not started**: the passphrase prompt never appears. `archopen` names what changed

```
INTEGRITY CHECK FAILED: the VM files are not what they were when it last shut down.
  changed: efi.qcow2

  The VM was NOT started, so nothing has asked for your disk passphrase.
```

When the VM shuts down, the launcher seals the new state: the session itself changed `disk.qcow2`, and a kernel update rewrites the ESP. The UEFI variables (`vars.fd`) don't change: every boot runs on a throwaway copy. Hashing runs at about 2 GB/s, so a few seconds per boot for a well-filled disk.

If the last session did not end normally (Mac crashed, the launcher was killed), its changes were never sealed and the next `archopen` refuses to boot, with a note that says so. If that is what happened, run `archseal accept`: it shows what changed and seals after you confirm.

**What the seal does not protect against.** For this VM, your Mac is the hardware. Code that runs as your macOS user can also edit the launcher, your `~/.zshrc` or QEMU itself, and it can update the Keychain item with the same `security` tool the launcher uses. A real TPM does not protect against a compromised firmware either. The seal catches changes made to the VM files while you weren't running them: by another account or app that can write to the folder, a sync or backup tool that restored or overwrote a file, a guest that changed its own ESP, or a damaged file. Against someone with your Mac's disk in their hands, FileVault is what protects you. Keep it on.

---

## 🗑️ Uninstall

```bash
archuninstall
```

It asks about each item (`y/N`), shows a summary, and asks once more before removing anything:

| Item | Notes |
|---|---|
| Arch virtual disks | `disk.qcow2`, `efi.qcow2`, `vars.fd`, `efi-code.fd`: the whole Arch system, plus its seal in the Keychain |
| Download cache and logs | Alpine ISO, Arch tarball, `install.log`, `versions.lock` |
| Shell commands | The `archopen` block in `~/.zshrc` (all four commands) and `~/.zshrc.archopen-backup` |
| SSH host key | `[localhost]:2222` in `~/.ssh/known_hosts`, if present |
| QEMU, GnuPG | `brew uninstall`; tells you if they were already there before the setup |
| `brew autoremove` | Only offered if you removed one of the above |
| Homebrew | Only offered if the setup installed it |

A running VM is shut down first. Once nothing of the install is left, `~/vm/archarm` is removed, and so is `~/vm` if nothing else is in it. `archuninstall --all` removes everything without asking. If the commands are already gone:

```bash
bash <(curl -fsSL https://arch.arifcinartekin.me/uninstall)
```

Nothing inside the VM needs cleaning up: zsh_setup and everything else ran inside Arch and is deleted with the disk.

---

## ⚙️ Configuration

All optional, set as environment variables in front of the install command:

| Variable | Default | |
|---|---|---|
| `ARCHOPEN_DIR` | `~/vm/archarm` | Install directory (keep the path short: the QMP socket path has a limit of ~100 characters) |
| `ARCHOPEN_HOSTNAME` | `arch` | Hostname inside the VM |
| `ARCHOPEN_CPUS` / `ARCHOPEN_MEM` | `4` / `4G` | VM resources |
| `ARCHOPEN_ROOT_SIZE` / `ARCHOPEN_ESP_SIZE` | `20G` / `1G` | Disk sizes (thin-provisioned qcow2) |
| `ARCHOPEN_USER` | `user` | Your account inside the VM (wheel, sudo) |
| `ARCHOPEN_SSH_PORT` | `2222` | Host port forwarded to the VM's port 22 |
| `ARCHOPEN_LUKS_PASSPHRASE` | | Disk passphrase, instead of asking for it (needed for an install without a terminal) |
| `ARCHOPEN_YES=1` | | Do not ask for confirmation |
| `ARCHOPEN_FORCE=1` | | Overwrite an existing install |
| `ARCHOPEN_PIN_BREW=1` | | `brew pin qemu gnupg` |
| `ARCHOPEN_ARCH_TARBALL_URL` + `ARCH_TARBALL_SHA256` | | Use a different tarball (its `.sig` must sit next to it) |

Example:

```bash
ARCHOPEN_MEM=8G ARCHOPEN_ROOT_SIZE=64G bash <(curl -fsSL https://arch.arifcinartekin.me/install)
```

---

## 🔒 Pinned versions and verification

| | Source | Checks |
|---|---|---|
| Alpine `3.24.3` (installer only) | [GitHub release `alpine-3.24.3`](https://github.com/arifcinartekin/archsetupformac/releases/tag/alpine-3.24.3) of this repo (unmodified copy), then `dl-cdn.alpinelinux.org` | sha256 pinned in the script + GPG signature by fingerprint `0482D840…D9495A` |
| Arch Linux ARM tarball | GitHub release of this repo (unmodified copy) | sha256 pinned in the script + **upstream** GPG signature by fingerprint `68B3537F…BDBE6A6` |
| Companion scripts | this repo | fetched from the same repo and ref as the setup script |

**Why mirror the tarball?** Upstream only publishes `ArchLinuxARM-aarch64-latest.tar.gz`, a moving target. A pinned checksum against it breaks whenever upstream rebuilds. The release asset is the same file, byte for byte, so the original Arch Linux ARM signature still verifies it. The ~830 MB file sits in GitHub Releases rather than in git: release assets can be up to 2 GB and have no bandwidth cap, while git rejects files over 100 MB.

The installed system is not old: `pacman -Syu` runs during setup, so you boot into current packages. The tarball only fixes the starting point.

The Alpine ISO is mirrored the same way (with its upstream `.sha256`, `.asc` and the signing key), so an install does not depend on Alpine's CDN keeping 3.24.3 around. The `.sha256`, signature and key are still fetched from Alpine first. The packages the installer VM adds with `apk` (cryptsetup, btrfs-progs, …) still come from Alpine's repositories.

### Updating the pinned tarball (maintainers)

```bash
tools/publish-tarball.sh            # download upstream latest, verify GPG, upload release, update the script
git commit -am "Pin Arch Linux ARM tarball $(date +%Y%m%d)" && git push
```

Needs `gh` (logged in with push access) and `gpg`. To bump Alpine, edit `ALPINE_VERSION` and `ALPINE_ISO_SHA256` and publish the mirror:

```bash
gh release create alpine-<version> --latest=false --title "Alpine <version> aarch64 (installer environment)" \
  alpine-virt-<version>-aarch64.iso{,.sha256,.asc} ncopa.asc
```

---

## 📁 Repository layout

```
archopen-setup.sh                   Mac: the installer (the one-liner runs this)
guest/archopen-firstboot.sh         VM:  first-boot wizard (zsh, tools, login screen)
guest/archopen-winsize.sh           VM:  applies the Mac terminal's size to the serial console
mac/archclose.sh                    Mac: `archclose`
mac/archuninstall.sh                Mac: `archuninstall`
mac/archseal.sh                     Mac: `archseal`, the integrity seal `archopen` checks
third_party/zsh_setup/zsh_setup.sh  VM:  unmodified copy of arifcinartekin/zsh_setup
tools/publish-tarball.sh            Maintainers: pin a new Arch tarball
site/index.html                     arch.arifcinartekin.me landing page
.github/workflows/pages.yml         Publishes /install and /uninstall on arch.arifcinartekin.me
```

Files on your Mac after install (`~/vm/archarm`): `disk.qcow2`, `efi.qcow2`, `vars.fd`, `efi-code.fd`, `start-uefi.sh`, `archclose.sh`, `archuninstall.sh`, `archseal.sh`, `downloads/`, `install.log`, `versions.lock` (exact versions and package list), `.archopen-manifest` (what was installed on the Mac, used by `archuninstall`) and `.archopen-seal` (the sealed file list, used to name what changed). Outside of it: one `archopen-seal` item in the login Keychain.

---

## 🩺 Troubleshooting

| Problem | Fix |
|---|---|
| Install failed | Read `~/vm/archarm/install.log` with `less` or `cat -v` (plain `cat` lets your terminal answer the escape sequences recorded in it, which leaves junk at your prompt), then run the setup again. It resumes downloads and redoes the disk |
| `There is already an install` | `archuninstall` first, or `ARCHOPEN_FORCE=1` |
| `INTEGRITY CHECK FAILED` | Something changed a VM file while Arch was off. If you know why (the last session crashed, you restored a backup), `archseal accept`. If you don't, don't boot it |
| `no seal ... in the Keychain` | You moved the install directory or the Keychain item is gone: check the files, then `archseal accept` |
| Change the disk passphrase | Inside the VM: `sudo cryptsetup luksChangeKey /dev/disk/by-label/archcrypt` |
| Forgot the disk passphrase | The data can't be recovered. `archuninstall` and install again |
| `The Arch VM is already running` | It's open in another terminal. `archclose` |
| `archclose` says *no QMP socket* | The VM was started by a launcher from an older version: `archclose --force`, or reinstall |
| SSH: `REMOTE HOST IDENTIFICATION HAS CHANGED` | You reinstalled: `ssh-keygen -R "[localhost]:2222"` |
| Plain console login instead of ly (or back) | `sudo archopen-firstboot --login-screen console` (or `ly`) |
| Text stays at the old size after resizing the window | The VM was started by a launcher from an older version: reinstall. Inside Arch, `systemctl status archopen-winsize` shows whether the size helper runs |
| Root password wanted | root is locked on purpose: `sudo -i`. To give it a password anyway: `sudo passwd root` |
| Skipped zsh setup | As your user: `sh /usr/local/share/archopen/zsh_setup.sh` |
| Plain `ls` instead of lsd | Remove the `archopen lsd` block from `~/.zshrc` (bash: `~/.bashrc`), or run `\ls` once |
| No fastfetch at login | Remove the `archopen info` block from `~/.zprofile` (bash: `~/.bash_profile`). The `info` alias is in `~/.zshrc` (bash: `~/.bashrc`) |

---

<div align="center">
Made by <a href="https://github.com/arifcinartekin">arifcinartekin</a> · zsh setup from <a href="https://github.com/arifcinartekin/zsh_setup">zsh_setup</a>
</div>
