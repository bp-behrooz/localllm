# The agent boxes

Five scripts that run a coding agent in a VM confined to `$PWD`, so the agent
can have every permission and the VM is the boundary. On a Mac that's Apple's
`container`; on Linux (Arch), a rootless podman container booted as a krun
microVM.

| script | agent |
|---|---|
| [`claude-box`](claude-box) | Claude Code (talks to Anthropic) |
| [`agy-box`](agy-box) | Antigravity CLI (`agy`, talks to Google), Gemini CLI's successor |
| [`pi-box`](pi-box) | pi, against [the local LLM server](../README.md) |
| [`opencode-box`](opencode-box) | OpenCode, against the local LLM server |
| [`ocr-box`](ocr-box) | Open Code Review (`ocr review`, `ocr scan`, ...), against the local LLM server |

[`agent-box-lib.bash`](agent-box-lib.bash) is the shared half (image, run
flags, Docker/ssh bridging). Each script sources the copy next to it, so keep
them together.

claude-box and agy-box sign in on first launch (agy prints a URL; paste the
code back). Logins survive `--clean`.

## Setup

**Mac:** Apple Silicon, macOS 26, `brew install container socat`.

**Linux (Arch):**

```sh
sudo pacman -S podman krun socat
grep -q "^$USER:" /etc/subuid ||
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate                         # only if podman ran before that
systemctl --user enable --now podman.socket   # only for --docker
```

You also need read/write on `/dev/kvm` (the `kvm` group). podman must be
rootless, so what the agent writes stays owned by you; the boxes refuse to
start otherwise. `*_BOX_RUNTIME=crun` runs a plain container instead of the VM.

Files created in the box by a non-root uid land in your subuid range on the
host. The agents run as root, so that's rare.

## Docker and ssh

`--docker` lets the agent use the host's Docker (podman's API on Linux, so no
BuildKit: `buildx` and `RUN --mount` don't work; point `*_BOX_DOCKER_SOCK` at a
real Docker socket if you need them). `--ssh` forwards your ssh-agent and your
`gh` token.

A Unix socket can't cross a VM boundary, so `socat` serves each one on a free
host-loopback port (24100-24199) for the session. The box reaches it at
`169.254.1.3`, which pasta maps to host loopback (a plain container just
bind-mounts the sockets). Two consequences:

- With either flag on, the box can reach **every** port on host `127.0.0.1`.
- Any local user can connect to the bridge ports while the box runs. To keep
  other users out, allow only your uid and your subuid range (podman's pasta
  connects as `nobody` in your user namespace, i.e. a subuid):

```sh
subuids=$(awk -F: -v u="$USER" '$1 == u { print $2 "-" $2 + $3 - 1 }' /etc/subuid)
sudo tee /etc/agentbox.nft >/dev/null <<EOF
table inet agentbox
delete table inet agentbox
table inet agentbox {
  chain output {
    type filter hook output priority 0; policy accept;
    oif lo tcp dport 24100-24199 ct state new meta skuid != { $(id -u), $subuids } reject
  }
}
EOF
sudo nft -f /etc/agentbox.nft
```

To load it at boot (not via `nftables.service`: Arch's default config flushes
the whole ruleset, ufw's included):

```sh
sudo tee /etc/systemd/system/agentbox-nft.service >/dev/null <<'EOF'
[Unit]
Description=Keep other users off the agent-box bridge ports

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nft -f /etc/agentbox.nft

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now agentbox-nft
```

## Customizing a box

Cheapest first:

**1. Runtimes: mise.** A project's `mise.toml` is trusted and used
automatically, and missing versions install on first use. For tools in every
project, run `mise use -g <tool>` inside the box. If a pinned version fails to
install, mise silently falls back to the image's `python3`/`node`; set
`MISE_NOT_FOUND_SYSTEM_FALLBACK=0` to make that an error.

**2. Anything in `$HOME`.** The box's home is a host dir mounted as `/root`, so
runtimes, `~/.npm`, `~/.cargo`, dotfiles and history persist. `apt install`
does not (it writes to `/usr`).

| box | home | `--clean` keeps |
|---|---|---|
| `claude-box` | `~/.claude-box` | `.claude/` |
| `agy-box` | `~/.agy-box` | `.gemini/` |
| `pi-box` | `~/.pi-box` | `.pi/` |
| `opencode-box` | `~/.opencode-box` | `.config/opencode/`, `.local/share/opencode/`, `.local/state/opencode/` |
| `ocr-box` | `~/.ocr-box` | `.opencodereview/` |

**3. Env knobs.** Prefixed per box: `CL_BOX_`, `AGY_BOX_`, `PI_BOX_`,
`OC_BOX_`, `OCR_BOX_`.

| knob | does |
|---|---|
| `*_BOX_HOME` | the box's home on the host |
| `*_BOX_VERSION` | npm version of the agent (not agy-box; `--rebuild` updates it) |
| `*_BOX_CPUS`, `*_BOX_MEMORY` | VM size (default 4 / 4G; krun wants `M` or `G`) |
| `*_BOX_SSH`, `*_BOX_DOCKER`, `*_BOX_SEARCH`, `*_BOX_PROFILE` | same as the flags |
| `*_BOX_RUNTIME` | Linux: podman runtime (default `krun`; `crun` for no VM) |
| `*_BOX_PROJECT` | name the project for persisted service data (default: git worktree or `$PWD`) |
| `*_BOX_DOCKER_SOCK` | Docker socket (default: colima etc. on a Mac, your podman socket on Linux) |
| `*_BOX_HOST_ALIAS`, `*_BOX_HOST_ALIAS_IP` | Mac: the host-loopback DNS name and IP |

Each script's header lists its own extras (models, approval prompts, ...).
pi-box, opencode-box and ocr-box also read `LOCAL_LLM_URL` and
`LOCAL_LLM_API_KEY`, unprefixed.

**4. The image.** For apt packages or anything outside `$HOME`, add
Dockerfile lines to `~/.box.default.dockerfile` (every box) and/or
`~/.box.<profile>.dockerfile` (with `--profile <profile>`, which then gets its
own image, e.g. `pi-box-work`). Both are appended, in that order, after the
box's own steps. Use `RUN`/`ENV`, not `COPY` (the build context is empty). The
next launch rebuilds when either changes.

Executables in `/etc/box-entry.d/` run before the agent starts, so a profile
can bring its own services. For example, `~/.box.data.dockerfile` for
`--profile data`, with Redis, PostgreSQL and MongoDB inside the box:

```dockerfile
# Redis from Ubuntu; PostgreSQL (a chosen major) and MongoDB from their own repos
ARG PG=17
RUN apt-get update \
 && apt-get install -y --no-install-recommends gnupg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg \
 && . /etc/os-release \
 && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" \
      >/etc/apt/sources.list.d/pgdg.list \
 && curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
      | gpg --dearmor -o /usr/share/keyrings/mongodb.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
      >/etc/apt/sources.list.d/mongodb.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends redis-server postgresql-$PG mongodb-org-server \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/scram-sha-256$/trust/' /etc/postgresql/$PG/main/pg_hba.conf \
 && mkdir -p /var/lib/redis /var/lib/mongodb

# Started before the agent, stopped cleanly after it.
RUN printf '%s\n' '#!/bin/sh' 'set -e' \
      'redis-server --daemonize yes --dir /var/lib/redis >/dev/null' \
      "pg_ctlcluster $PG main start" \
      'mongod --fork --dbpath /var/lib/mongodb --logpath /var/log/mongod.log >/dev/null' \
      >/etc/box-entry.d/10-services \
 && printf '%s\n' '#!/bin/sh' \
      'redis-cli shutdown save >/dev/null' \
      "pg_ctlcluster $PG main stop" \
      'mongod --shutdown --dbpath /var/lib/mongodb >/dev/null' \
      >/etc/box-exit.d/10-services \
 && chmod +x /etc/box-entry.d/10-services /etc/box-exit.d/10-services

# Keep the data between launches. Last, as later RUNs can't change these paths.
VOLUME /var/lib/postgresql /var/lib/redis /var/lib/mongodb
```

Each `VOLUME` path persists in a named volume, one set per profile and
project; an empty one starts with what the image had there. The project is the
git worktree you launch in (each worktree gets its own databases), or `$PWD`
outside git; `*_BOX_PROJECT=name` picks one by name instead. Only one box at a
time can use a set, and `--clean-data` deletes it. Hooks in `/etc/box-exit.d/`
run after the agent exits, so the services shut down cleanly. A failing
`box-entry.d` hook stops the box before the agent starts.

Change `PG` to pick the PostgreSQL major (the boxes pass no `--build-arg`, so
edit it here); PGDG builds each one for the image's own Ubuntu release.
MongoDB's 26.04 repo is still empty, so it comes from 24.04's (`noble`), whose
server package needs nothing 26.04 lacks. The agent reaches the databases on
`localhost` (`psql -h localhost -U postgres`, `redis-cli`, `mongosh` if you add
it). Mind `*_BOX_MEMORY`: three databases and an agent want more than the
default 4G.

To change the shared base for everyone, edit `box_dockerfile_base` in
[`agent-box-lib.bash`](agent-box-lib.bash), then `--build-only` (cached) or
`--rebuild` (from scratch).

## Flags

Shared: `--rebuild`, `--build-only`, `--ssh`, `--docker`, `--search`,
`--profile NAME`, `--clean`, `--clean-all`, `--clean-data`, `--shell`. pi-box, opencode-box
and ocr-box add `--sync` / `--sync-only` to refresh the model list from the
server. Everything else goes to the agent.

- `--profile NAME` passes the variables from `~/.box.NAME.env` (lines like
  `export FOO=bar`) into the box. `~/.box.default.env` is always read if it
  exists, with `NAME` on top. Profiles are shared by every box and kept out of
  the box home, so the agent can't read or change them.
- `--shell` runs bash instead of the agent, same everything else:
  `pi-box --shell -c 'uname -a'`.
- `--clean` drops runtimes and caches but keeps the login; `--clean-all`
  deletes the whole home (asks first); `--clean-data` deletes this profile and
  project's service data (asks first).

## Mac: the once-per-boot sudo

The first launch after a boot sets up the host-loopback DNS name (an
`/etc/resolver` file and a `pf` rule), which needs `sudo`. To skip the prompt:

```sh
echo "$USER ALL=(root) NOPASSWD: /sbin/pfctl -a com.apple/container -f /etc/pf.anchors/com.apple.container" | sudo tee /etc/sudoers.d/container-pfctl
sudo visudo -c -f /etc/sudoers.d/container-pfctl   # if it errors, rm the file
```

## Resuming a session

Agents print resume hints like `pi --session <id>` or `claude --resume <id>`.
Alias the wrappers so those paste as-is:

```bash
alias pi=pi-box claude=claude-box opencode=opencode-box agy=agy-box
```

(Pick other names if you also have the agents installed natively.)
