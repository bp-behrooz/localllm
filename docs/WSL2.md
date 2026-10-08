# The agent boxes on WSL2

The boxes ([`tools/`](../tools/README.md)) run on Windows under WSL2, through
rootless podman, the same as on Linux. This page sets that up in a distro of
its own.

## Why a separate distro

On WSL2 the boxes default to `crun`: a plain container, without a VM of its
own (krun would need nested KVM, and Ubuntu doesn't package it). An agent that
escapes the container lands in the distro you launched it from. In your
everyday distro, that's your home, your ssh keys and cloud logins, and, unless
`/etc/wsl.conf` turns them off:

- **Windows drives** at `/mnt/c`: every file your Windows user can read.
- **Interop**: running `powershell.exe` or `cmd.exe` as your Windows user. This
  is the bigger of the two.

A distro just for the boxes, with both turned off, holds nothing but the
projects you clone into it. What's left: all WSL2 distros share one VM and one
kernel, so a kernel exploit could still reach the others. Escaping the
container is the realistic case, and this covers it.

The boxes read `/etc/wsl.conf` at launch and say which of the two are still
open.

## 1. Create the distro

In PowerShell, pick an Ubuntu from `wsl --list --online` (the newest gets the
newest podman) and give it its own name:

```powershell
wsl --update
wsl --install Ubuntu-26.04 --name agentbox
```

It asks for a Linux user and password on first start. An older WSL without
`--name` can copy an installed distro instead:

```powershell
wsl --export Ubuntu-26.04 $env:TEMP\ubuntu.tar
wsl --import agentbox $env:USERPROFILE\wsl\agentbox $env:TEMP\ubuntu.tar
```

An imported distro starts as root: create your user (`useradd -m -G sudo -s
/bin/bash you && passwd you`) and set it as the default in step 2.

## 2. Lock it down

In the distro, write `/etc/wsl.conf`:

```ini
[boot]
# rootless podman wants a systemd user session
systemd = true

[automount]
# no /mnt/c, and no Windows drives from /etc/fstab either
enabled = false
mountFsTab = false

[interop]
# no Windows programs from Linux
enabled = false
appendWindowsPath = false

[user]
default = you
```

Then restart it from PowerShell, `wsl --terminate agentbox`, and open it
again. `ls /mnt/c` should find nothing and `powershell.exe` should be unknown.

You lose starting Windows programs from inside it (`explorer.exe .`,
`code .`). Windows can still open the distro's files at `\\wsl$\agentbox`.

## 3. Podman

```sh
sudo apt update
sudo apt install -y podman uidmap socat git python3
grep -q "^$USER:" /etc/subuid ||
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
systemctl --user enable --now podman.socket   # only for --docker
```

## 4. Keys, projects and the boxes

Everything lives in the distro: clone this repo and your projects there (it's
also much faster than working on `/mnt/c`).

For `--ssh`, give the distro a key of its own, so it can be revoked on its own:

```sh
ssh-keygen -t ed25519 -C "agentbox on $(hostname)"
eval "$(ssh-agent)" && ssh-add
gh auth login          # optional: --ssh passes its token too
```

Then, from a project:

```sh
~/localllm/tools/claude-box --shell -c 'git status'   # a quick check
~/localllm/tools/claude-box
```

## krun instead

If your CPU and Windows pass virtualization through (`ls -l /dev/kvm` in the
distro), the boxes can boot real microVMs here too. Install krun (Ubuntu doesn't
package it; Fedora does), join the `kvm` group, and set `*_BOX_RUNTIME=krun`.
The WSL2 note goes quiet then, since the VM is the boundary again.
