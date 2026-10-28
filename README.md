<div align="center">

# archopen

**Arch Linux ARM on Apple Silicon Macs, in one command.**

*QEMU + HVF, UEFI boot via systemd-boot, verified downloads, a first-boot wizard, and three commands you'll actually use: `archopen`, `archclose`, `archuninstall`.*

![Platform: macOS Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Guest: Arch Linux ARM aarch64](https://img.shields.io/badge/guest-Arch%20Linux%20ARM-1793d1)
![Shell: bash](https://img.shields.io/badge/shell-bash-blue)

</div>

---

## 🚀 Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/arifcinartekin/archsetupformac/main/archopen-setup.sh)
```

That's it. No checksum to paste and no "latest" that breaks next week: the Arch tarball is pinned and mirrored in this repo's [releases](../../releases).

When it finishes, it offers to start Arch right away. Log in as **`root`** with password **`root`**. The first-boot wizard takes over from there.

> Takes roughly 10–20 minutes, mostly downloads and `pacman -Syu`. You need about 3 GB of free disk space to start; the VM disk grows up to 20 GB as you use it.

---

## 🧰 Commands

| Command | Where | What it does |
|---|---|---|
| `archopen` | Mac | Boots Arch in the current terminal (serial console, no window) |
| `archclose` | Mac | Shuts Arch down cleanly from another terminal: presses the VM's power button, falls back to a hard stop after 90 s. `archclose --force` stops it immediately |
| `archuninstall` | Mac | Removes what the setup installed. Asks about each item separately, so you can keep QEMU or the VM disk and remove the rest |
| `ssh -p 2222 <user>@localhost` | Mac | SSH into the running VM (bound to `127.0.0.1` only) |

Inside the VM, `sudo poweroff` works too, and so does <kbd>Ctrl</kbd>+<kbd>A</kbd> then <kbd>X</kbd> (instant hard stop).

---

## 🪄 What happens

```
Mac                                         VM
───────────────────────────────────────────────────────────────────────────
1. Homebrew, qemu, gnupg (only if missing)
2. Alpine ISO   → sha256 pin + GPG ✓
   Arch tarball → sha256 pin + GPG ✓
3. Boot a throwaway Alpine VM ───────────▶  partition ESP (FAT32) + root (ext4)
   (driven over the serial console          extract the Arch tarball
    with expect, no clicking)               chroot: pacman keyring, pacman -Syu,
                                            sudo/zsh/git…, systemd-boot, fstab,
                                            hostname "arch", terminfo
4. Boot the new disk via UEFI ───────────▶  log in, check kernel / ESP / hostname
                                            / sshd, arm the first-boot wizard
5. Add archopen / archclose / archuninstall
   to ~/.zshrc
```

### First boot wizard

On the first `archopen`, log in as `root` / `root`. A one-time wizard starts and:

1. asks for your **username** (default `user`) and password, and adds you to `wheel` with **sudo**
2. optionally runs [**zsh_setup**](https://github.com/arifcinartekin/zsh_setup) for you: zsh, Oh My Zsh, Powerlevel10k, autosuggestions, syntax highlighting. The p10k configuration wizard runs at the end
3. optionally removes the default `alarm` account (its password is publicly known: `alarm`)
4. **locks the root password**, but only after it has verified that your sudo works, so you can't lock yourself out
5. removes itself and logs you out. From then on, log in as your own user and use `sudo -i` for root.

Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to skip it. It runs again at the next root login.

> 💡 Powerlevel10k icons need a Nerd Font **in your Mac terminal**, e.g. *MesloLGS NF* (Ghostty ships a Nerd Font by default).

---

## 🗑️ Uninstall

```bash
archuninstall
```

It asks about each item (`y/N`), shows a summary, and asks once more before removing anything:

| Item | Notes |
|---|---|
| Arch virtual disks | `disk.qcow2`, `efi.qcow2`, `vars.fd`: the whole Arch system |
| Download cache and logs | Alpine ISO, Arch tarball, `install.log`, `versions.lock` |
| Shell commands | The `archopen` block in `~/.zshrc` and `~/.zshrc.archopen-backup` |
| SSH host key | `[localhost]:2222` in `~/.ssh/known_hosts`, if present |
| QEMU, GnuPG | `brew uninstall`; tells you if they were already there before archopen |
| `brew autoremove` | Only offered if you removed one of the above |
| Homebrew | Only offered if archopen installed it |

A running VM is shut down first. `archuninstall --all` removes everything without asking. If the commands are already gone:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/arifcinartekin/archsetupformac/main/mac/archuninstall.sh)
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
| `ARCHOPEN_SSH_PORT` | `2222` | Host port forwarded to the VM's port 22 |
| `ARCHOPEN_YES=1` | | Do not ask for confirmation |
| `ARCHOPEN_FORCE=1` | | Overwrite an existing install |
| `ARCHOPEN_PIN_BREW=1` | | `brew pin qemu gnupg` |
| `ARCHOPEN_ARCH_TARBALL_URL` + `ARCH_TARBALL_SHA256` | | Use a different tarball (its `.sig` must sit next to it) |

Example:

```bash
ARCHOPEN_MEM=8G ARCHOPEN_ROOT_SIZE=64G bash <(curl -fsSL https://raw.githubusercontent.com/arifcinartekin/archsetupformac/main/archopen-setup.sh)
```

---

## 🔒 Pinned versions and verification

| | Source | Checks |
|---|---|---|
| Alpine `3.24.3` (installer only) | `dl-cdn.alpinelinux.org` | sha256 pinned in the script + GPG signature by fingerprint `0482D840…D9495A` |
| Arch Linux ARM tarball | GitHub release of this repo (unmodified copy) | sha256 pinned in the script + **upstream** GPG signature by fingerprint `68B3537F…BDBE6A6` |
| Companion scripts | this repo | fetched from the same repo and ref as the setup script |

**Why mirror the tarball?** Upstream only publishes `ArchLinuxARM-aarch64-latest.tar.gz`, a moving target. A pinned checksum against it breaks whenever upstream rebuilds. The release asset is the same file, byte for byte, so the original Arch Linux ARM signature still verifies it. The ~830 MB file sits in GitHub Releases rather than in git: release assets can be up to 2 GB and have no bandwidth cap, while git rejects files over 100 MB.

The installed system is not old: `pacman -Syu` runs during setup, so you boot into current packages. The tarball only fixes the starting point.

### Updating the pinned tarball (maintainers)

```bash
tools/publish-tarball.sh            # download upstream latest, verify GPG, upload release, update the script
git commit -am "Pin Arch Linux ARM tarball $(date +%Y%m%d)" && git push
```

Needs `gh` (logged in with push access) and `gpg`. Bump Alpine the same way: edit `ALPINE_VERSION` and `ALPINE_ISO_SHA256`.

---

## 📁 Repository layout

```
archopen-setup.sh                   Mac: the installer (the one-liner runs this)
guest/archopen-firstboot.sh         VM:  first-boot wizard (user, sudo, zsh, root lock)
mac/archclose.sh                    Mac: `archclose`
mac/archuninstall.sh                Mac: `archuninstall`
third_party/zsh_setup/zsh_setup.sh  VM:  unmodified copy of arifcinartekin/zsh_setup
tools/publish-tarball.sh            Maintainers: pin a new Arch tarball
```

Files on your Mac after install (`~/vm/archarm`): `disk.qcow2`, `efi.qcow2`, `vars.fd`, `start-uefi.sh`, `archclose.sh`, `archuninstall.sh`, `downloads/`, `install.log`, `versions.lock` (exact versions and package list), and `.archopen-manifest` (what was installed on the Mac, used by `archuninstall`).

---

## 🩺 Troubleshooting

| Problem | Fix |
|---|---|
| Install failed | Read `~/vm/archarm/install.log` with `less` or `cat -v` (plain `cat` lets your terminal answer the escape sequences recorded in it, which leaves junk at your prompt), then run the setup again. It resumes downloads and redoes the disk |
| `There is already an install` | `archuninstall` first, or `ARCHOPEN_FORCE=1` |
| `The Arch VM is already running` | It's open in another terminal. `archclose` |
| `archclose` says *no QMP socket* | The VM was started by a launcher from an older version: `archclose --force`, or reinstall |
| SSH: `REMOTE HOST IDENTIFICATION HAS CHANGED` | You reinstalled: `ssh-keygen -R "[localhost]:2222"` |
| Locked out of root | `sudo passwd root` as your user |
| Skipped zsh setup | As your user: `sh /usr/local/share/archopen/zsh_setup.sh` |

---

<div align="center">
Made by <a href="https://github.com/arifcinartekin">arifcinartekin</a> · zsh setup from <a href="https://github.com/arifcinartekin/zsh_setup">zsh_setup</a>
</div>
