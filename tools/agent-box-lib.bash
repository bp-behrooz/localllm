# shellcheck shell=bash
# agent-box-lib.bash: the half of every *-box script that isn't about the agent —
# image lifecycle, the Mac-loopback DNS domain, the Docker bridge, and the
# `container run` flags they all pass.
#
# A library, not a program: it has no shebang, isn't executable, and each *-box
# script sources the copy sitting next to it.
#
# The sourcing script sets three variables first:
#
#   BOX_IMAGE        image tag to build and run       (e.g. "claude-box")
#   BOX_NAME_PREFIX  prefix for container names       (e.g. "cl")
#   BOX_ENV_PREFIX   its user-facing env-knob prefix  (e.g. "CL_BOX")
#   BOX_HOME         host dir mounted as the box's /root
#   BOX_KEEP         paths under BOX_HOME that `--clean` preserves, relative
#                    (e.g. (.claude) — the logins and settings, not the runtimes)
#
# BOX_ENV_PREFIX is how the shared knobs stay named after their own tool:
# everything below reads ${BOX_ENV_PREFIX}_DOCKER, _DOCKER_SOCK, _HOST_ALIAS,
# _HOST_ALIAS_IP, _SSH, _CPUS and _MEMORY, and names that same variable when it
# has to complain about it.
#
# ...and defines one function:
#
#   box_dockerfile_agent   writes the agent-specific Dockerfile tail (its
#                          `npm install -g`, any ENV, the ENTRYPOINT) to stdout;
#                          box_build_image appends it to the shared base.

[[ ${BASH_SOURCE[0]} != "$0" ]] || {
  echo "error: agent-box-lib.bash is a library; source it from a *-box script." >&2
  exit 1
}

# Read one of the shared knobs under the sourcing script's own prefix:
# box_knob CPUS 4  ->  $CL_BOX_CPUS, or 4. Split in two steps so it behaves the
# same on macOS's bash 3.2 as on a modern one.
box_knob() {
  local var="${BOX_ENV_PREFIX}_$1" val
  val="${!var-}"
  printf '%s' "${val:-${2-}}"
}

# --------------------------------------------------------------- runtime -----
box_require_runtime() {
  if ! command -v container >/dev/null 2>&1; then
    echo "error: 'container' CLI not found. Install with: brew install container" >&2
    exit 1
  fi

  if ! container system status >/dev/null 2>&1; then
    echo "==> starting container runtime" >&2
    container system start
  fi
}

# ----------------------------------------------------------------- image -----
box_have_image() {
  container image inspect "$BOX_IMAGE" >/dev/null 2>&1
}

box_remove_images() {
  local ids
  ids=$(container list --all --format json 2>/dev/null |
    grep -o "\"name\":\"$BOX_NAME_PREFIX-[^\"]*\"" | cut -d'"' -f4 || true)
  for c in $ids; do
    container delete --force "$c" >/dev/null 2>&1 || true
  done
  if box_have_image; then
    echo "==> removing image $BOX_IMAGE" >&2
    container image delete "$BOX_IMAGE" >/dev/null
  fi
  container image prune >/dev/null 2>&1 || true
}

# The base every box shares. Written from a quoted heredoc, so it lands in the
# Dockerfile verbatim — no doubled backslashes, no escaped $(...).
box_dockerfile_base() {
  cat <<'EOF'
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive

# Node 22 ships in 26.04's repos, so no NodeSource needed
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep fd-find jq make openssh-client \
      python3 unzip less nodejs npm \
      docker.io docker-compose-v2 docker-buildx \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI: Ubuntu's own package lags years behind, so use GitHub's repo
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# mise manages the language runtimes (ruby, go, python, ...) a project asks for.
# It goes in /usr/local so the binary survives a --clean; what it installs lands
# in /root/.local/share/mise, which is the persisted home.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Shims, not `mise activate`: activation hooks an interactive shell's prompt,
# and an agent runs every command through a non-interactive `bash -c`, where it
# would silently do nothing. The shim dir works for both.
ENV PATH=/root/.local/share/mise/shims:$PATH

EOF
}

# box_build_image [note]   note is shown in the build banner, e.g. "pi@latest"
box_build_image() {
  # Cleaned up by hand rather than with a RETURN trap: bash leaves such a trap
  # registered after the function returns, and it would fire again — with $ctx
  # long gone — when box_ensure_image returns.
  local ctx note="${1-}" rc=0
  ctx=$(mktemp -d)

  {
    box_dockerfile_base
    box_dockerfile_agent
  } >"$ctx/Dockerfile"

  echo "==> building image $BOX_IMAGE${note:+ ($note)}" >&2
  container build --tag "$BOX_IMAGE" "$ctx" || rc=$?
  rm -rf "$ctx"
  return "$rc"
}

# box_ensure_image $REBUILD $BUILD_ONLY [note]
box_ensure_image() {
  local rebuild="$1" build_only="$2" note="${3-}"
  if [[ $rebuild -eq 1 ]]; then
    box_remove_images
    box_build_image "$note"
  elif [[ $build_only -eq 1 ]] || ! box_have_image; then
    box_build_image "$note"
  fi
}

# ----------------------------------------------------------------- clean -----
# box_clean keep   drop everything in BOX_HOME except BOX_KEEP (runtimes, caches
#                  and package downloads go; the box stays logged in)
# box_clean all    delete BOX_HOME outright, after asking
box_clean() {
  local mode="$1" home="$BOX_HOME" tmp rel reply
  [[ -n $home && $home != "/" && $home != "$HOME" ]] || {
    echo "error: refusing to clean '$home'" >&2
    exit 1
  }
  [[ -d $home ]] || {
    echo "==> $home does not exist; nothing to clean" >&2
    return 0
  }
  echo "==> $home is $(du -sh "$home" 2>/dev/null | cut -f1)" >&2

  if [[ $mode == all ]]; then
    printf 'Delete it all, including this box'"'"'s logins? [y/N] ' >&2
    read -r reply </dev/tty || reply=""
    [[ $reply == [yY]* ]] || {
      echo "==> cancelled" >&2
      return 0
    }
    rm -rf "${home:?}"
    echo "==> removed $home" >&2
    return 0
  fi

  # Move what we keep aside, drop the rest, move it back. Handles nested keeps
  # (.local/share/opencode) without having to walk around them, and the temp dir
  # is a sibling so the moves stay on one filesystem.
  tmp="$(mktemp -d "${home%/}.clean.XXXXXX")"
  for rel in ${BOX_KEEP[@]+"${BOX_KEEP[@]}"}; do
    [[ -e "$home/$rel" ]] || continue
    mkdir -p "$tmp/$(dirname "$rel")"
    mv "$home/$rel" "$tmp/$rel"
  done
  rm -rf "${home:?}"
  mv "$tmp" "$home"
  echo "==> cleaned $home, now $(du -sh "$home" 2>/dev/null | cut -f1); kept ${BOX_KEEP[*]}" >&2
}

# ------------------------------------------------------------ host alias -----
box_ensure_host_alias() {
  # Apple's localhost domain installs a pf rule that does not survive a reboot,
  # while `dns list` keeps showing the domain. So: redo the setup (needs sudo)
  # once per boot, tracked by kernel boot time.
  local alias="$1" ip
  ip="$(box_knob HOST_ALIAS_IP 203.0.113.113)"
  # Shared between all the *-box scripts so only one of them does this per boot.
  local stamp="${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/host-alias.boot" boot
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*{ sec = \([0-9]*\).*/\1/')
  if [[ -f "$stamp" && "$(cat "$stamp")" == "$boot" ]] &&
    container system dns list 2>/dev/null | grep -q "^$alias\b"; then
    return 0
  fi

  echo "==> setting up '$alias' -> Mac loopback (sudo, once per boot)" >&2
  sudo container system dns delete "$alias" >/dev/null 2>&1 || true
  sudo container system dns create "$alias" --localhost "$ip"

  # The runtime needs a restart to pick up the change. Don't yank it out from
  # under running containers (ours or anyone else's).
  if [[ -n "$(container list --quiet 2>/dev/null)" ]]; then
    echo "error: containers are running, so the runtime can't be restarted to pick up the change." >&2
    echo "       When they're done:  container system stop && container system start" >&2
    echo "       then relaunch." >&2
    exit 1
  else
    container system stop >/dev/null 2>&1 || true
    container system start
  fi
  mkdir -p "$(dirname "$stamp")"
  printf '%s' "$boot" >"$stamp"
}

# ---------------------------------------------------------------- docker -----
box_docker_bridge() {
  # Expose the Mac's Docker socket to the box. Unix sockets can't be bind-mounted
  # into the VM, and containers can't reach the Mac at the bridge gateway IP by
  # default. Apple's supported route is a "localhost" DNS domain: it installs a
  # pf rule that redirects a chosen IP to the Mac's loopback, so we listen on
  # 127.0.0.1 with socat and let the box connect by name.
  #
  # NOTE: whatever the daemon can reach on the Mac (colima: its mount list), the
  # agent can reach through docker.
  BOX_DOCKER_ENV=()
  [[ "$(box_knob DOCKER 0)" == "1" ]] || return 0
  command -v socat >/dev/null || {
    echo "error: ${BOX_ENV_PREFIX}_DOCKER needs socat (brew install socat)" >&2
    exit 1
  }

  local alias
  alias="$(box_knob HOST_ALIAS host.container.internal)"
  box_ensure_host_alias "$alias"

  local sock
  sock="$(box_knob DOCKER_SOCK)"
  if [[ -z "$sock" ]]; then
    for c in "$HOME/.colima/default/docker.sock" "$HOME/.docker/run/docker.sock" \
      "$HOME/.orbstack/run/docker.sock" /var/run/docker.sock; do
      [[ -S "$c" ]] && {
        sock="$c"
        break
      }
    done
  fi
  [[ -S "${sock:-}" ]] || {
    echo "error: no Docker socket found; set ${BOX_ENV_PREFIX}_DOCKER_SOCK" >&2
    exit 1
  }

  local port=$((20000 + RANDOM % 20000))
  socat "TCP-LISTEN:$port,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$sock" &
  BOX_SOCAT_PID=$!
  trap 'kill "$BOX_SOCAT_PID" 2>/dev/null' EXIT
  BOX_DOCKER_ENV=(--env "DOCKER_HOST=tcp://$alias:$port")
  echo "==> docker: $sock -> tcp://$alias:$port (this session only)" >&2
}

# ------------------------------------------------------------- run flags -----
_box_git_env() {
  # The box never sees the host's ~/.gitconfig; pass the git identity (if the
  # host has one) so the agent's commits are authored by you.
  BOX_GIT_ENV=()
  local name email
  if name=$(git config user.name 2>/dev/null) && email=$(git config user.email 2>/dev/null) &&
    [[ -n $name && -n $email ]]; then
    BOX_GIT_ENV=(--env "GIT_AUTHOR_NAME=$name" --env "GIT_AUTHOR_EMAIL=$email"
      --env "GIT_COMMITTER_NAME=$name" --env "GIT_COMMITTER_EMAIL=$email")
  fi
}

_box_gh_env() {
  # The agent socket authenticates git over ssh, but GitHub's API only takes a
  # token, so `gh pr view`/`gh api` stay locked out. Hand the box the host's gh
  # token alongside the agent. Exported rather than passed by value: `--env NAME`
  # inherits it, keeping the token out of the host's process list.
  BOX_GH_ENV=()
  [[ -n "$(box_knob SSH)" ]] || return 0
  if GH_TOKEN=$(gh auth token 2>/dev/null) && [[ -n $GH_TOKEN ]]; then
    export GH_TOKEN
    BOX_GH_ENV=(--env GH_TOKEN)
  else
    echo "==> --ssh: no gh token on the host (run \`gh auth login\`); gh stays logged out in the box" >&2
  fi
}

# Fills BOX_RUN_ARGS with the flags every box passes: the project mounted at its
# own Mac path (so bind-mount paths the agent hands to docker mean the same
# thing to the Mac's daemon), BOX_HOME as the box's whole /root, VM sizing, the
# docker bridge, git identity, gh token and the ssh-agent. Call
# box_docker_bridge first. The per-agent --env flags stay in the calling script.
box_run_args() {
  _box_git_env
  _box_gh_env

  mkdir -p "$BOX_HOME"
  BOX_RUN_ARGS=(
    -it --rm
    --name "$BOX_NAME_PREFIX-$(basename "$PWD" | tr -c 'a-zA-Z0-9_.-\n' '-')-$$"
    --volume "$PWD:$PWD"
    --workdir "$PWD"
    --volume "$BOX_HOME:/root"
    --tmpfs /tmp
    --cpus "$(box_knob CPUS 4)"
    --memory "$(box_knob MEMORY 4G)"
    # mise refuses to read a project's mise.toml until it's trusted, and would
    # sit on a prompt no agent can answer. The box only ever sees $PWD.
    --env "MISE_TRUSTED_CONFIG_PATHS=$PWD"
    --env MISE_YES=1
  )
  BOX_RUN_ARGS+=(
    ${BOX_DOCKER_ENV[@]+"${BOX_DOCKER_ENV[@]}"}
    ${BOX_GIT_ENV[@]+"${BOX_GIT_ENV[@]}"}
    ${BOX_GH_ENV[@]+"${BOX_GH_ENV[@]}"}
  )
  if [[ -n "$(box_knob SSH)" ]]; then
    BOX_RUN_ARGS+=(--ssh)
  fi
}
