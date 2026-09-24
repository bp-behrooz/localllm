# The agent boxes

Four scripts that run a coding agent inside an Apple `container` VM confined to
`$PWD`, so the agent can be given every permission and the VM is the boundary:

| script | agent |
|---|---|
| [`claude-box`](claude-box) | Claude Code (talks to Anthropic; unrelated to this repo's server) |
| [`pi-box`](pi-box) | the pi coding agent, against [the local LLM server](../README.md) |
| [`opencode-box`](opencode-box) | OpenCode, against [the local LLM server](../README.md) |
| [`ocr-box`](ocr-box) | Open Code Review (`ocr`), against [the local LLM server](../README.md) — reviews a diff or scans whole files; not an interactive agent, so `ocr-box review`, `ocr-box scan`, … |

[`agent-box-lib.bash`](agent-box-lib.bash) is the half they share — image
lifecycle, the Mac-loopback DNS domain, the Docker bridge, the common
`container run` flags. It is a library, not a program: each script sources the
copy sitting next to it, so keep the two together when you copy a box
somewhere.

Requires Apple Silicon, macOS 26 and `brew install container`.

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
`PI_BOX_` for pi-box, `OC_BOX_` for opencode-box, `OCR_BOX_` for ocr-box:

| knob | does |
|---|---|
| `*_BOX_HOME` | where the box's `/root` lives on the Mac |
| `*_BOX_VERSION` | npm version/tag of the agent itself |
| `*_BOX_CPUS`, `*_BOX_MEMORY` | VM sizing (default 4 / 4G) |
| `*_BOX_SSH` | forward your ssh-agent in, and pass `gh auth token` along |
| `*_BOX_PROFILE` | read the box home's `.env.<name>` (lines like `export SOME_VAR=SOME_VAL`) and pass its variables in |
| `*_BOX_DOCKER` | let the agent drive the Mac's Docker engine |
| `*_BOX_DOCKER_SOCK` | which Docker socket (auto-detected; colima first) |
| `*_BOX_HOST_ALIAS`, `*_BOX_HOST_ALIAS_IP` | the localhost DNS domain used for that |

Each script's header documents its own knobs on top of these — model defaults
and provider hiding for pi-box and opencode-box, the review model for ocr-box,
renderer and mouse handling for claude-box.

Two knobs carry no prefix, because they name this repo's server rather than a
box: `LOCAL_LLM_URL` (the OpenAI-compatible base URL) and `LOCAL_LLM_API_KEY`.
pi-box, opencode-box and ocr-box all read the same pair — export them once.
Point one box elsewhere with `LOCAL_LLM_URL=… ./tools/pi-box`.

### 4. System packages: the image

Adding an apt package, or anything else that lives outside `$HOME`, means
editing `box_dockerfile_base` in [`agent-box-lib.bash`](agent-box-lib.bash) —
there is no per-user config file for this yet, so the change is shared by all
four boxes. Then
rebuild each box you want it in:

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

## Flags

Shared by all four: `--rebuild`, `--build-only`, `--ssh`, `--profile=NAME`,
`--clean`, `--clean-all`. pi-box and opencode-box add `--sync` and `--sync-only`,
which re-read the served model list from the LLM server; ocr-box has no model
list to sync — it reviews with one model, `OCR_BOX_MODEL`, defaulting to the
first one the server reports. Everything else is passed through to the agent.

`--profile=NAME` reads `$<box home>/.env.NAME` — a shell file of
`export SOME_VAR=SOME_VAL` lines — and passes every variable it defines into
the box, so a per-project or per-task set of credentials and endpoints is one
flag away without exporting anything in your own shell.
