# The agent boxes

Five scripts that run a coding agent in a VM confined to `$PWD`, so the agent
can have every permission and the VM is the boundary. On a Mac that's Apple's
`container`; on Linux (Arch), a rootless podman container booted as a krun
microVM; on Windows, WSL2 with rootless podman (see
[docs/WSL2.md](../docs/WSL2.md)).

Launched in a git worktree (`git worktree add ../agents/foo`) or submodule,
the box also mounts the main repo's `.git` read-write, since that's where its
objects and refs live.

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

**Windows:** WSL2, set up as in [docs/WSL2.md](../docs/WSL2.md), ideally a
distro just for the boxes. They default to `crun` there, without krun's VM.

## The local server

pi-box, opencode-box and ocr-box take the server's base URL and key from the
environment:

```bash
export LOCAL_LLM_URL=https://example.com/localllm/v1
export LOCAL_LLM_API_KEY=sk-xxx
pi-box                # or: opencode-box
ocr-box review        # or: ocr-box scan; one model per run
```

On first launch (or with `--sync`) they query the server and write the served
models into the box's own config; re-run with `--sync` after preset changes.
pi-box and opencode-box record context limits too; ocr-box writes a `localllm`
provider that `ocr` prefers over any environment, reviewing with
`OCR_BOX_MODEL` (default: the first model the server reports).

## Docker and ssh

`--docker` lets the agent use the host's Docker (podman's API on Linux, so no
BuildKit: `buildx` and `RUN --mount` don't work; point `*_BOX_DOCKER_SOCK` at a
real Docker socket if you need them). `--ssh` forwards your ssh-agent. `--gh`
passes the repo's token from `box-gh-token set`; `--gh=host` passes your own
`gh auth token` for that run only.

A Unix socket can't cross a VM boundary, so under krun and on a Mac `socat`
serves each one on a free port (24100-24199) for the session, forwarded to
that box alone the way `--host-port` forwards a port (see [Reaching the
host](#reaching-the-host)); a plain container just bind-mounts the sockets.
Neither flag gives the box the rest of the host's loopback.

On Linux the bridge ports sit on host loopback, where any local user can
connect to them while the box runs. To keep other users out, allow only your
uid and your subuid range (podman's pasta connects as `nobody` in your user
namespace, i.e. a subuid):

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

## Reaching the host

`--host-port <port>` (env: `<BOX>_HOST_PORT`) lets the box reach services on
the host's loopback — e.g. a Postgres and a Redis next to the pool — and only
those ports:

```sh
pi-box --host-port=5432 --host-port=6379
# or: pi-box --host-port=5432,6379
```

The agent connects to `127.0.0.1:5432` as if Postgres ran in the box, and
nothing else on the host's loopback is reachable. Under podman, pasta forwards
each listed port; on a Mac, socat does, on a free port of the VM network's
gateway (`192.168.64.1`, or `<BOX>_HOST_GATEWAY`) that accepts only this
box's IP, which needs `brew install socat` and a current image (the box says
when it needs `--build-only`). There the forwards start a moment after the box
does, and a forwarded port whose service is down accepts a connection and then
closes it rather than refusing it. A service in the box can't listen on a
forwarded port. socat logs out of the agent's way, to
`~/.local/state/agent-box/socat-<pid>.log` on the host (one per launch, the
10 newest kept) and to `/tmp/box-entry-socat.log` in the box, with each
forward's share of a log capped at 1 MiB.

### A database without its password

A profile can bring its own host side, started for each launch and stopped
when it exits, so `claude-box --profile db` is the whole command:

- `BOX_LAUNCH_PORT=VAR` (or `VAR1,VAR2`), a line in `~/.box.db.env`: each `VAR`
  gets a free host port of its own for this launch, forwarded to this box
  alone and passed into it. Lines after it can use `$VAR`.
- `~/.box.db.up` runs in bash on the host before the box starts, with the
  profile's variables set. If it fails, the box doesn't start.
- `~/.box.db.down` runs when the launch exits (Ctrl-C and a closed terminal
  too), even if `.up` failed halfway.

Both get `$BOX_HOOK_DIR`, a private directory for this launch, deleted after
`.down`. Keep a hook's secrets in the host keychain with `box-secret set
NAME` (`get`, `show`, `remove`); `box-secret get NAME` prints it only into
`$(...)` or a pipe, never to a terminal. For example, a PgBouncer per launch
holding a password stored with `box-secret set db`:

```sh
# ~/.box.db.env
BOX_LAUNCH_PORT=PGPORT
PGHOST=127.0.0.1
PGDATABASE=<db>
```

```sh
# ~/.box.db.up
pw=$(box-secret get db) || exit 1
cat >"$BOX_HOOK_DIR/pgbouncer.ini" <<EOF
[databases]
<db> = host=<rds-host> port=5432 dbname=<db> user=<read-only-role> password=$pw

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = $PGPORT
unix_socket_dir =
auth_type = any
pidfile = $BOX_HOOK_DIR/pgbouncer.pid
logfile = $BOX_HOOK_DIR/pgbouncer.log
server_tls_sslmode = verify-full
server_tls_ca_file = $HOME/path/to/global-bundle.pem
EOF
pgbouncer -d "$BOX_HOOK_DIR/pgbouncer.ini"
```

```sh
# ~/.box.db.down: also runs after a failed .up, when there may be no pid file
pid=$BOX_HOOK_DIR/pgbouncer.pid
[ ! -f "$pid" ] || kill "$(cat "$pid")"
```

In the box a bare `psql` connects (`PGHOST`, `PGPORT` and `PGDATABASE` are
set). `auth_type = any` lets anyone who reaches the port in, as the role on the
`[databases]` line; only this box and the host's own processes reach it. A
launch killed with `kill -9` skips `.down`, leaving PgBouncer and its config
behind. Hiding the password doesn't limit what the connection can do, so give
it a read-only role.

On a Mac, `--docker` used to reach the Mac through a pf rule that gave every
box all of the Mac's loopback until a reboot. While one set up this boot is
still loaded, every launch offers to take it down (sudo) and won't start
without an answer. Taking it down restarts the container system, which stops
every running box.

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
| `*_BOX_HOST_PORT` | same as `--host-port` |
| `*_BOX_RUNTIME` | Linux: podman runtime (default `krun`, `crun` on WSL2; `crun` for no VM) |
| `*_BOX_PROJECT` | name the project for persisted service data (default: git worktree or `$PWD`) |
| `*_BOX_DOCKER_SOCK` | Docker socket (default: colima etc. on a Mac, your podman socket on Linux) |
| `*_BOX_HOST_GATEWAY` | Mac: the VM network's gateway the forwards listen on (default `192.168.64.1`) |

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

Shared: `--rebuild`, `--build-only`, `--ssh`, `--gh[=host]`, `--docker`,
`--host-port <port>`, `--search`, `--profile NAME`, `--clean`, `--clean-all`,
`--clean-data`, `--shell`. pi-box, opencode-box and ocr-box add `--sync` /
`--sync-only` to refresh the model list from the server. Everything else goes
to the agent.

- `--host-port <port>` lets the box reach just that port on the host's loopback;
  see [Reaching the host](#reaching-the-host).
- `--profile NAME` passes the variables from `~/.box.NAME.env` (lines like
  `export FOO=bar`) into the box. `~/.box.default.env` is always read if it
  exists, with `NAME` on top. Profiles are shared by every box and kept out of
  the box home, so the agent can't read or change them. Each line is evaluated
  on the host at launch, so `export TOKEN=$(some-cli print-token)` mints a fresh
  value every time. A profile can also start and stop host services per launch;
  see [A database without its password](#a-database-without-its-password).
- `--rebuild` rebuilds only the image you launch, so with a profile that has
  its own Dockerfile, pass `--profile` too. A launch warns when the image's
  agent is behind npm (checked in the background, at most once a day; not
  agy-box).
- `--shell` runs bash instead of the agent, same everything else:
  `pi-box --shell -c 'uname -a'`.
- `--clean` drops runtimes and caches but keeps the login; `--clean-all`
  deletes the whole home (asks first); `--clean-data` deletes this profile and
  project's service data (asks first). A bare clean is the whole command; with
  `--rebuild` or `--build-only` the clean runs first and the build follows, so an
  agent's own major version bump (OpenCode 1.x → 2.0 changed the plugin and
  config formats) is one command — `opencode-box --clean-all --rebuild`, which
  seeds a fresh config on the way up.

## Two boxes at once

`opencode-box` launches its agent with `--standalone`: a server of its own
rather than OpenCode 2.0's background service, which is one per `$HOME` and
registers itself in the home the boxes share. Two TUIs on a plain host attach to
that one service; two containers can't (each has its own loopback and its own
PIDs), so each box gets its own server and they run side by side, sharing the
home's config, models and sessions. `--shell` and subcommands like
`opencode-box session list` are passed through untouched; `--server` is refused,
since that server lives behind the VM's loopback.

## Network chatter

Each box turns off what its agent does online besides talking to the model:
telemetry, update checks (the version lives in the image) and catalog fetches.

| box | sets |
|---|---|
| `claude-box` | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` |
| `agy-box` | `AGY_CLI_DISABLE_AUTO_UPDATE=true`; telemetry is an account setting, turn it off in `/config` |
| `pi-box` | `PI_OFFLINE=1`; its packages are baked into the image (see below) |
| `opencode-box` | `OPENCODE_DISABLE_MODELS_FETCH=1`, `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_LSP_DOWNLOAD=1` |
| `ocr-box` | `OCR_NO_UPDATE=1` |

pi's packages live in the image under `/opt/pi-packages` and load as local
paths. Model catalogs come with the pi and opencode builds, so `--rebuild`
brings new packages, models and agent versions together.

## Resuming a session

Agents print resume hints like `pi --session <id>` or `claude --resume <id>`.
Alias the wrappers so those paste as-is:

```bash
alias pi=pi-box claude=claude-box opencode=opencode-box agy=agy-box
```

(Pick other names if you also have the agents installed natively.)

## Tests

```sh
mise install                                   # bats
bats tools/tests/agent-box.bats                # seconds; stubbed runtimes
BOX_IT=1 bats tools/tests/integration.bats     # Linux: builds and runs a real box
```

The stubbed tests pretend to be Linux, WSL2 or a Mac and check what each box
would pass to `podman run` / `container run`. CI
([`agent-box.yml`](../.github/workflows/agent-box.yml)) runs them on Linux and
macOS, plus the integration tests under rootless podman with crun. A real Mac
(Apple's `container`) or WSL2 box needs nested virtualization, which GitHub's
runners lack, so check those by hand: `claude-box --shell -c 'git status'`.
