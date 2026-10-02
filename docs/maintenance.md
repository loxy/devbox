# Maintenance: disk space

A dev VM fills up with caches that every tool keeps on its own: package managers,
Docker build caches, IDE indexes, old toolchain versions. `vm-cleanup` removes them
without touching anything that would cost you more than a re-download, and knows
which look-alike folders it must never delete.

## Usage

```bash
vm-cleanup                  # dry run: what would go, with sizes
vm-cleanup -i               # checklist; safe steps pre-ticked
vm-cleanup --apply          # safe tier
vm-cleanup --apply --deep   # + deep tier
```

Every real run ends with a **health check**: `node`, `npm` and `go` still start,
and the images listed in `KEEP_IMAGES` still exist. The script exits 1 if a step or
the health check failed, and appends a line to `~/.local/state/vm-cleanup.log`. That
log shows how fast the disk fills up again.

To find what else is big: `ncdu ~` or `sudo ncdu -x /`. Use the arrow keys to move,
`d` to delete (it asks first) and `q` to quit.

## What it cleans

| Tier | Step | Cost of the deletion |
|---|---|---|
| safe | npm/npx caches (including the legacy `~/.npm/content-v2` that `npm cache clean` ignores) | re-download on next install |
| safe | BuildKit cache older than 7 days (default builder) | slower first rebuild |
| safe | extra buildx builder capped at 2 GB (if `CROSSBUILDER` is set) | slower first rebuild |
| safe | untagged Docker images | none |
| safe | Go build/test cache | slower first build |
| safe | JVM crash dumps in `~` (`java_error_in_*.hprof`: IDE out-of-memory heap dumps, several GB each) | none |
| deep | JetBrains indexes, caches, logs | re-index on next open |
| deep | old JetBrains backends (keeps the newest per product, and any running one) | none |
| deep | caches and plugins of previous IDE versions (never the version the backend uses) | none |
| deep | Go module cache | modules re-download |
| deep | mise tool versions no tracked config uses | re-install on demand |
| deep | Volta Node versions nothing pins | re-download on demand |
| deep | unused anonymous Docker volumes | data in volumes no container references |

The JetBrains index step and the old-backend step are skipped while an IDE backend
is running, including when it connects while the `-i` checklist is still open.

## What it never deletes, and why

These look like caches but aren't. Each was learned the hard way.

| Path / thing | Why it stays |
|---|---|
| `~/.cache/JetBrains/RemoteDev/dist/<current>` | It is the **IDE backend itself** (about 4 GB). A blanket `rm -rf ~/.cache/JetBrains/*` forces a full re-download on the next connect. |
| `~/.cache/JetBrains/*/LocalHistory` | your local edit history |
| `~/.config/JetBrains` | IDE settings |
| `~/.volta/tools/inventory/node/node-v*-npm` | small metadata files Volta needs to *start* Node. Deleting them gives `Volta error: Could not read default npm version`. |
| tagged Docker images | `docker image prune -a` / `system prune -a` delete every image without a running container. Throwaway-container toolboxes and locally built images (which can't be re-pulled) are always in that set. |
| named Docker volumes | may hold service data |

## Safety rules built into the script

- **Dry run by default.** Nothing is deleted without `--apply` or the `-i` confirmation.
- Refuses to run as root: under `sudo`, `$HOME` can point at `/root`.
- **Node pins:** each `package.json` under `PROJECT_ROOT` is read separately. If any
  file can't be read, or Volta reports no default Node, the Volta step is skipped
  rather than guessing.
- **IDE versions:** "newest" isn't the same as "in use". The version folder named in
  the backend's `product-info.json` is always kept, even when a newer preview folder exists.
- Paths are shell-quoted, so names with spaces are safe.

## Per-machine config

`~/.config/devbox/vm-cleanup.conf` (optional; plain bash):

```bash
# images the health check must find after a cleanup
KEEP_IMAGES=(my-toolbox:latest some-mcp:local)
# a docker-container buildx builder (multi-arch builds) to cap
CROSSBUILDER=crossbuilder
CROSSBUILDER_MAX=2gb
BUILDKIT_KEEP_DAYS=7
PROJECT_ROOT=$HOME/dev
```

## When cleaning isn't enough

A working VM settles around **30 GB**: OS and Docker images (~9 GB), repos with
`node_modules` (~7 GB), the IDE backend and data (~6 GB), and toolchains (~5 GB).
Below that you are deleting tools you'll re-download within a week.

**10–15 GB free is healthy.** If you keep dropping below that, grow the disk rather
than cleaning harder:

```bash
multipass stop dev && multipass set local.dev.disk=80G && multipass start dev
```

The size can only grow. The guest filesystem expands automatically on boot.
