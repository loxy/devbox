# devbox

A reproducible Ubuntu dev VM on [Multipass](https://multipass.run), built for working
with coding agents (Claude Code) and remote IDEs (JetBrains Gateway). One command on
the host creates it. One command in the VM tells you what is still missing. One
command keeps the disk in check.

```bash
# on the host (macOS or Linux, Multipass installed)
git clone https://github.com/loxy/devbox.git && cd devbox
host/create-vm.sh

# in the VM
ssh devbox-dev
devbox-doctor
```

## Why a VM

- **Disposable.** Everything rebuilds from git, so a broken or full VM gets replaced,
  not repaired.
- **Isolated.** The agent runs with broad permissions inside the VM, not on your laptop.
- **Same everywhere.** Any host with Multipass runs the same box. The host only
  needs an SSH key and an IDE client.

## What you get

| Location                    | Description                                                                               |
|-----------------------------|-------------------------------------------------------------------------------------------|
| `host/create-vm.sh`         | Launches the VM with cloud-init and writes an `ssh devbox-NAME` alias                     |
| `host/update-ssh-config.sh` | Refreshes that alias when Multipass hands out a new IP                                    |
| `cloud-init.yaml`           | First boot: clock fixes, packages, Docker CE, clones this repo, runs bootstrap            |
| `system/chrony-setup.sh`    | Makes the clock recover within minutes after the host sleeps (root, safe to re-run)       |
| `bootstrap.sh`              | Volta/Node, mise/Go, Claude Code, PATH, links `bin/` into `~/.local/bin`. Safe to re-run. |
| `bin/devbox-doctor`         | Read-only health check; prints the fix for each problem                                   |
| `bin/vm-cleanup`            | Frees disk space safely: dry run by default, `-i` checklist, health check after           |

## Docs

- [Provisioning](docs/provisioning.md): the model, what is automated, the manual
  steps, sizing, the clock problems, IDE setup, snapshots, troubleshooting
- [Maintenance](docs/maintenance.md): disk cleanup, what is never deleted and why,
  when to grow the disk instead

## Adapting it

It is opinionated (Ubuntu LTS, Volta, mise, Claude Code, JetBrains) but small. Fork
it, or override via:
- `create-vm.sh` flags (`--repo` for your fork)
- `~/.config/devbox/bootstrap.conf`
- `~/.config/devbox/vm-cleanup.conf`

## License

MIT
