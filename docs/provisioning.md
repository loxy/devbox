# Provisioning a devbox

How a devbox VM is created, what the automation does, what stays manual, and the
problems that come back if you skip a step. Each gotcha below cost real debugging
time on a working setup.

## The model

A devbox is an **Ubuntu LTS VM under [Multipass](https://multipass.run)** that holds
the repos, Docker, the language toolchains, and a coding agent (Claude Code). You
work in it over SSH: from a terminal, or from a JetBrains/VS Code client whose
backend runs inside the VM.

Two rules keep it disposable:

1. **Everything rebuilds from git.** Code lives in repos; secrets live encrypted in
   repos (or are re-created per machine). Nothing on the VM is precious, so you can
   delete it and create a fresh one instead of nursing it.
2. **The VM is the dev environment; the host is only a client.** Toolchains,
   indexing and builds run in the VM. The host needs Multipass, an SSH key and an IDE client.

## Quickstart

On the host:

```bash
git clone https://github.com/loxy/devbox.git && cd devbox
host/create-vm.sh                    # defaults: name dev, 8 CPU, 32G RAM, 60G disk
ssh devbox-dev                       # or: multipass shell dev
devbox-doctor                        # lists what is still missing
```

`host/create-vm.sh --help` shows the options; `--print` renders the cloud-init
without launching anything.

## What runs where

| Stage | Where | What | File |
|---|---|---|---|
| Launch | host | Creates a host→VM SSH key if missing, renders cloud-init, `multipass launch`, waits for first boot, writes a `Host devbox-NAME` entry to `~/.ssh/config` | `host/create-vm.sh` |
| First boot | VM, root | NTP on, apt upgrade, base packages, clones this repo, clock fix, Docker CE, runs bootstrap | `cloud-init.yaml`, `system/chrony-setup.sh` |
| Bootstrap | VM, user | Volta + Node, mise + Go, Claude Code, `~/.profile` PATH, links `bin/*` into `~/.local/bin` | `bootstrap.sh` |
| Check | VM, user | Read-only health check; prints the exact command for each missing piece | `bin/devbox-doctor` |

`bootstrap.sh` is idempotent: re-run it after pulling devbox, or to repair a
broken toolchain. Override versions in `~/.config/devbox/bootstrap.conf`:

```bash
NODE_VERSION=24        # default: lts
GO_VERSION=1.26.1      # default: latest
GIT_NAME="Your Name"
GIT_EMAIL="you@users.noreply.github.com"
```

## What stays manual (and why)

These steps involve secrets or interactive logins and are deliberately not
automated. `devbox-doctor` checks each one:

| Step | Command |
|---|---|
| VM → GitHub SSH key (one per VM: revocable on its own) | `ssh-keygen -t ed25519 -C "$(hostname)"`, add `~/.ssh/id_ed25519.pub` at github.com/settings/keys, verify `ssh -T git@github.com` |
| Git identity (unless set via `bootstrap.conf`) | `git config --global user.name …` / `user.email …` |
| Claude Code login | `claude` |
| Log out and in once | so the `docker` group applies to your shell |
| Project secrets | each project's own docs (e.g. decrypt an age/SOPS vault, copy `.env` files) |

Then clone your repos into `~/dev`. Per repo: Go → `mise install`; JS/TS → Volta
picks the pinned Node automatically, then `npm install`.

## Sizing

| Resource | Default | Why |
|---|---|---|
| Disk | 60G | A working VM settles around 30 GB of tools and repos; the rest is room for caches, which `vm-cleanup` keeps in check. The size is a cap, not a reservation: Multipass images are thin-provisioned, so the host only pays for data actually written, which usually doesn't shrink back after deletions inside the VM. Start small: disks can grow later (`multipass stop dev && multipass set local.dev.disk=80G`) but never shrink. Grow when `devbox-doctor` keeps warning despite cleanups. |
| RAM | 32G | An IDE backend per open project, plus Docker, plus builds |
| CPUs | 8 | Indexing and builds run in the VM, not on the host |

## Clock

A VM clock that is wrong breaks TLS: apt, git, and Claude Code (`SSL certificate is
not yet valid`). There are two separate problems, and cloud-init handles both.

**At first boot** the clock is often wrong, and apt rejects "not yet valid" repo
signatures. cloud-init turns NTP on and waits for sync before installing packages.

**After the host sleeps**, the hypervisor pauses the VM and its clock stops. On wake
the guest is behind by the length of the nap. The guest gets no signal about the
suspend: no kvm-clock, no `/dev/ptp0`, and Multipass doesn't push time on resume.
Until the clock is corrected, everything using TLS fails. How long that takes
depends on the time service:

| Time service | Recovery after the host sleeps |
|---|---|
| `systemd-timesyncd` (Ubuntu 24.04 default) | It does step large offsets, but only at its next poll, which can be up to **~34 minutes** away |
| chrony, Ubuntu default config (`makestep 1 3`) | It notices the jump (`Forward time jump detected!` in the journal), but steps only in the first three updates after startup. After that it slews, which absorbs seconds but never days, so it **effectively never recovers**. |
| chrony + `makestep 1 -1` | It steps at its next measurements, **within a few minutes**. In a test, a 2-minute jump was stepped after ~2½ minutes (two 64 s polls). |

So devbox installs chrony and tells it to step unconditionally: `makestep 1 -1`.
cloud-init runs `system/chrony-setup.sh` on new VMs. On an existing VM run:

```bash
sudo ~/dev/devbox/system/chrony-setup.sh   # idempotent; devbox-doctor checks the result
```

**Why the script edits `chrony.conf` instead of adding a `conf.d` drop-in.** The
drop-in is the usual pattern, but here it silently does nothing:
- Ubuntu's `chrony.conf` includes `conf.d` near the top (`confdir`, line 5).
- The stock `makestep 1 3` comes later (line 57).
- For a directive that appears more than once, chrony uses **the last one**.

So the script comments out the stock line and appends ours at the very end of the
file, keeping a `.devbox-backup` copy. `chrony.conf` is a package config file: if a
future chrony update ships a changed version, apt asks whether to keep yours. Keep
it. If you replace it anyway, `devbox-doctor` flags it and re-running the script
restores the fix.

Notes:
- Installing chrony removes `systemd-timesyncd`: the two packages conflict, so only
  one time service ever runs. `timedatectl` keeps working.
- Never leave the VM on `timedatectl set-ntp false`. That stops chrony, and with it
  the only recovery after a sleep.
- Always-on hosts rarely sleep, so the failure stays hidden until a long idle
  weekend. Apply the fix everywhere.

If outbound UDP/123 is blocked (`chronyc sources` stays at `Reach 0`), set the clock
over HTTPS as a stopgap. If the clock is so far off that HTTPS itself fails, set a
rough time first:

```bash
sudo timedatectl set-time "2026-01-01 12:00:00"     # only if way off
sudo date -s "$(curl -sI https://cloudflare.com | sed -n 's/^[Dd]ate: //p')"
sudo hwclock --systohc
```

## IDE: JetBrains Gateway / Remote Development

The IDE **backend** runs in the VM and the host runs only the UI client.
`create-vm.sh` already wrote the SSH entry:

1. JetBrains Gateway, or IntelliJ → *Remote Development* → SSH → host `devbox-dev`.
2. Pick the IDE. The **backend downloads into the VM, about 4 GB** under
   `~/.cache/JetBrains/RemoteDev/dist`. It lives in a cache folder but it is the IDE
   itself, so cleanup must never delete it (see [maintenance](maintenance.md)).
3. Open a project under `/home/ubuntu/dev/...`.

Multipass can assign a new IP after a host reboot. When `ssh devbox-dev` stops
connecting, run `host/update-ssh-config.sh dev` on the host.

Plugins with a separate client part (e.g. *Go for JetBrains Client*) can log
compatibility warnings in the client. If the language features work, the warning is
cosmetic.

## Snapshots

Snapshots are taken with the VM stopped:

```bash
multipass stop dev && multipass snapshot dev --name baseline && multipass start dev
multipass restore dev.baseline
```

Two caveats:
- A snapshot contains **decrypted secrets, the Claude credentials and SSH private
  keys**. Treat it as sensitive.
- It is a rollback point on this host, not a backup: it can't move to another
  machine. Off-host, rebuild from git (the model above) or `tar` the home folder.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| apt: "Release file … is not valid yet" | wrong clock at first boot | `sudo timedatectl set-ntp true`, check `timedatectl` |
| "SSL certificate is not yet valid" after the host slept | guest clock paused while the host slept | `sudo chronyc makestep` now; `devbox-doctor` checks the permanent fix |
| `docker`: permission denied on `docker.sock` | `docker` group not yet active in this shell | log out and in (or `newgrp docker`) |
| `claude` / `go` / `mise`: command not found | `~/.local/bin` or the mise shims not on PATH | `bash ~/dev/devbox/bootstrap.sh`, then a new login shell |
| An `npx`-launched MCP server is missing, the others work | no Node / `npx` | `volta install node`, then **restart Claude Code** (MCP servers inherit PATH at launch) |
| `ssh devbox-dev` times out after a host reboot | VM got a new IP | `host/update-ssh-config.sh dev` |
| VM sluggish while the IDE is open | backend indexing in the VM | expected; one warm backend per open project |
| Disk filling up | caches | `vm-cleanup -i`, see [maintenance](maintenance.md) |
| cloud-init failed | network, apt, or an installer | `multipass exec dev -- sudo tail -50 /var/log/cloud-init-output.log`; fix, then re-run `bootstrap.sh` |
