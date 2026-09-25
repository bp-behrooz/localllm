# The agent boxes

Five scripts that run a coding agent inside a container confined to `$PWD`, so
the agent can be given every permission and the container is the boundary. On a
Mac that's Apple's `container` VM; on a Linux host (Arch) the same image runs
as a rootless podman container — no VM, and none of the Mac-only machinery
(socat bridge, pf/DNS domain, per-boot sudo) applies:

| script | agent |
|---|---|
| [`claude-box`](claude-box) | Claude Code (talks to Anthropic; unrelated to this repo's server) |
| [`agy-box`](agy-box) | Antigravity CLI (`agy`, talks to Google; unrelated to this repo's server). The successor to Gemini CLI for Google AI Pro / Ultra / free accounts |
| [`pi-box`](pi-box) | the pi coding agent, against [the local LLM server](../README.md) |
| [`opencode-box`](opencode-box) | OpenCode, against [the local LLM server](../README.md) |
| [`ocr-box`](ocr-box) | Open Code Review (`ocr`), against [the local LLM server](../README.md) — reviews a diff or scans whole files; not an interactive agent, so `ocr-box review`, `ocr-box scan`, … |

[`agent-box-lib.bash`](agent-box-lib.bash) is the half they share — image
lifecycle, the Mac-loopback DNS domain, the Docker bridge, the common
`container run` flags. It is a library, not a program: each script sources the
copy sitting next to it, so keep the two together when you copy a box
somewhere.

Requires Apple Silicon, macOS 26 and `brew install container`, or Linux with
rootless podman (see [below](#linux-rootless-podman)). On the Linux host
podman's Docker-compatible socket and, with `--ssh`, your ssh-agent
bind-mount straight into the box.

The two that talk to a vendor sign in on first launch. claude-box logs in as
usual. agy-box's box has no browser, so it prints a URL: open it on the host,
sign in, paste the code back. Both logins land in the box's home and
survive `--clean`.

### Linux: rootless podman

The box runs as root and bind-mounts `$PWD` and its home. Under a rootful
runtime everything the agent writes would be root-owned on the host: the next
launch's config sync fails, `--clean` fails, and git in the box refuses the
repo ("dubious ownership"). Rootless podman maps the box's root to your own
uid, so what the agent writes stays yours, and there is no daemon. The boxes
refuse to start if podman isn't rootless. On Arch:

```sh
sudo pacman -S podman
grep -q "^$USER:" /etc/subuid ||
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate     # only if podman ran before the subuid range existed
systemctl --user enable --now podman.socket   # only for *_BOX_DOCKER
```

With `*_BOX_DOCKER` the agent's `docker` CLI talks to podman's Docker API.
`docker run`, `docker compose` and classic `docker build` work; BuildKit-only
features (`buildx`, `RUN --mount`) don't, since the box pins
`DOCKER_BUILDKIT=0`. Point `*_BOX_DOCKER_SOCK` at a real Docker socket if you
need those.

One caveat: a file created inside the box by a uid other than root (say
`nobody`) maps to your subuid range on the host (100000 and up), not to you.
The agents all run as root, so that is rare.

## Customizing a box

There are four places to change what a box can do, from cheapest to most
invasive. Reach for the first one that fits.

### 1. Language runtimes: mise

Every box ships [mise](https://mise.jdx.dev), and its shim directory is on
`PATH` — not `mise activate`, which only hooks an interactive shell's prompt and
would silently do nothing for the non-interactive `bash -c` an agent runs every
command through.

A project's own `mise.toml` is picked up automatically. The box passes
`MISE_TRUSTED_CONFIG_PATHS=$PWD`, so mise trusts it without the prompt no agent
could answer, and `not_found_auto_install` means a pinned-but-missing version
installs itself the first time something calls it:

```toml
# mise.toml, committed with the project
[tools]
ruby = "4.0.2"
node = "24"
```

For tools you want in *every* project of a box, install them globally from
inside it — this writes to the box's persisted home, so it survives:

```bash
mise use -g shellcheck@latest jq@1.7.1
```

One caveat worth knowing: if a shim can't resolve its version, mise falls back
to the same-named system binary rather than failing. The image ships `python3`
and `node`, so a failed install of a pinned Python can silently give you
Ubuntu's. Set `MISE_NOT_FOUND_SYSTEM_FALLBACK=0` in the box if you'd rather that
be an error.

### 2. Anything else you install into `$HOME`

The box's home directory on the Mac is mounted as the container's entire
`/root`, so whatever lands in `$HOME` outlives the container:

| box | host dir | keeps |
|---|---|---|
| `claude-box` | `~/.claude-box` | `.claude/` — login, settings, `CLAUDE.md`, history |
| `agy-box` | `~/.agy-box` | `.gemini/` — login, settings, plugins, conversations |
| `pi-box` | `~/.pi-box` | `.pi/` — config, models, sessions |
| `opencode-box` | `~/.opencode-box` | `.config/opencode/`, `.local/share/opencode/` |
| `ocr-box` | `~/.ocr-box` | `.opencodereview/` — config, `rule.json`, review sessions |

So mise runtimes (`~/.local/share/mise`), gems installed into them, `~/.npm`,
`~/.cargo`, `~/.gitconfig`, `~/.bashrc` and shell history all persist.
`mise use ruby@4.0.2 && bundle install` is a one-off, not a per-launch cost.

**`apt install` is not covered** — it writes to `/usr`, which is thrown away
with the container. System packages belong in the image (below).

### 3. Per-launch behavior: env knobs

Every box reads the same knobs under its own prefix — `CL_BOX_` for claude-box,
`AGY_BOX_` for agy-box, `PI_BOX_` for pi-box, `OC_BOX_` for opencode-box,
`OCR_BOX_` for ocr-box:

| knob | does |
|---|---|
| `*_BOX_HOME` | where the box's `/root` lives on the Mac |
| `*_BOX_VERSION` | npm version/tag of the agent itself (not agy-box: its installer always fetches the latest, so `--rebuild` to update) |
| `*_BOX_CPUS`, `*_BOX_MEMORY` | VM sizing (default 4 / 4G) |
| `*_BOX_SSH` | forward your ssh-agent in, and pass `gh auth token` along |
| `*_BOX_PROFILE` | read the box home's `.env.<name>` (lines like `export SOME_VAR=SOME_VAL`) and pass its variables in |
| `*_BOX_DOCKER` | let the agent drive the host's Docker engine |
| `*_BOX_DOCKER_SOCK` | which Docker socket (auto-detected: colima first on a Mac, your podman socket on Linux) |
| `*_BOX_HOST_ALIAS`, `*_BOX_HOST_ALIAS_IP` | the localhost DNS domain used for that |

Each script's header documents its own knobs on top of these — model defaults
and provider hiding for pi-box and opencode-box, the review model for ocr-box,
renderer and mouse handling for claude-box, approval prompts for claude-box and
agy-box (both off by default; the VM is the boundary). agy-box also trusts
`$PWD` up front and installs its default plugins (ponytail) on first launch.

Two knobs carry no prefix, because they name this repo's server rather than a
box: `LOCAL_LLM_URL` (the OpenAI-compatible base URL) and `LOCAL_LLM_API_KEY`.
pi-box, opencode-box and ocr-box all read the same pair — export them once.
Point one box elsewhere with `LOCAL_LLM_URL=… ./tools/pi-box`.

### 4. System packages: the image

Adding an apt package, or anything else that lives outside `$HOME`, means
editing `box_dockerfile_base` in [`agent-box-lib.bash`](agent-box-lib.bash) —
there is no per-user config file for this yet, so the change is shared by all
the boxes. Then rebuild each box you want it in:

```bash
./tools/claude-box --build-only   # reuses cached layers above the change
./tools/claude-box --rebuild      # deletes the image first, builds from scratch
```

A plain launch will *not* pick the edit up: the image is built only when its tag
is missing, so `--build-only` (or `--rebuild`) is what applies a changed base.

## Cleaning up

A persisted home grows — runtimes, package caches, build artifacts.

```bash
./tools/claude-box --clean       # drop runtimes and caches, stay logged in
./tools/claude-box --clean-all   # delete the whole home (asks first)
```

`--clean` keeps only the paths in the table above, so you lose the mise
installs, `~/.npm`, `~/.cargo` and friends, but not your login or history. Both
print the directory's size before they touch it.

## The once-per-boot sudo

macOS only — on a Linux host there is no host-side setup at all.

The first launch after a boot sets up the Mac-loopback DNS domain
(`*_BOX_HOST_ALIAS`) — an `/etc/resolver` file plus a `pf` rule — which needs
`sudo`. It is tracked by kernel boot time and shared by all the boxes, so only
the first box of a boot prompts; the rest reuse it. If that one prompt bugs
you, allow the exact reload command without a password:

```sh
echo "$USER ALL=(root) NOPASSWD: /sbin/pfctl -a com.apple/container -f /etc/pf.anchors/com.apple.container" | sudo tee /etc/sudoers.d/container-pfctl
sudo visudo -c -f /etc/sudoers.d/container-pfctl
```

The second line validates the syntax (if it errors, `sudo rm
/etc/sudoers.d/container-pfctl`). The entry matches only that one command with
those exact args — it does not grant passwordless `pfctl` in general. The rare
first-ever `container system dns` setup still prompts.

## Flags

Shared by all of them: `--rebuild`, `--build-only`, `--ssh`, `--profile=NAME`,
`--clean`, `--clean-all`. The boxes that use this repo's server (pi-box,
opencode-box, ocr-box) add `--sync` and `--sync-only`, which re-read the served
model list from the LLM server and rewrite the box's config —
pi-box and opencode-box record context limits too, ocr-box writes a `localllm`
provider (reviewing with `OCR_BOX_MODEL`, default: the first model the server
reports). Everything else is passed through to the agent.

`--profile=NAME` reads `$<box home>/.env.NAME` — a shell file of
`export SOME_VAR=SOME_VAL` lines — and passes every variable it defines into
the box, so a per-project or per-task set of credentials and endpoints is one
flag away without exporting anything in your own shell.

## Resuming a session

Each agent prints its own resume hint as it exits — `pi --session <id>`,
`claude --resume <id>`, `opencode -s <id>`, `agy --conversation=<id>` — naming a command that doesn't
exist on the Mac, because only the `*-box` wrappers do. Give the wrappers those
names and every hint an agent ever prints becomes copy-pasteable, for any
session and any flag:

```bash
alias pi=pi-box claude=claude-box opencode=opencode-box agy=agy-box   # in your shell rc
ln -s /path/to/tools/pi-box ~/bin/pi                                  # or on PATH instead
```

Aliases apply to your interactive shell, which is exactly where you paste the
hint. They do shadow a natively installed agent of the same name — if you run
both, alias to something else (`alias pibox=pi-box`); the hint is only wrong
about the one word you can complete yourself.
