# shellcheck shell=bash
# agent-box-lib.bash: the half of every *-box script that isn't about the agent —
# image lifecycle, the Mac-loopback DNS domain, the Docker bridge, and the
# `container run` flags they all pass.
#
# Two hosts run the same image: a Mac, through Apple's `container` CLI (a VM),
# and Linux (Arch), through rootless podman — no VM, and the Mac-only machinery
# (socat bridge, pf/DNS-domain, per-boot sudo) is skipped there. Everything
# host-specific below branches on BOX_CTR.
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
# _HOST_ALIAS_IP, _SSH, _CPUS, _MEMORY and _PROFILE, and names that same
# variable when it has to complain about it.
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

# The host runtime: Apple's `container` CLI on a Mac, rootless podman on Linux
# (setup in tools/README.md).
if [[ $(uname -s) == Linux ]]; then
  BOX_CTR=(podman)
else
  BOX_CTR=(container)
fi

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
  if [[ ${BOX_CTR[0]} == podman ]]; then
    command -v podman >/dev/null 2>&1 || {
      echo "error: podman not found. Install with: sudo pacman -S podman" >&2
      exit 1
    }
    # Rootful (sudo podman) would make everything the box writes root-owned on
    # the host, which breaks the next launch's config sync and git inside the
    # box. Rootless maps the box's root to your own uid.
    local rootless
    # stderr stays out: podman warns there (cgroup manager etc.) even when fine
    rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" || {
      echo "error: podman is not usable here; run \`podman info\` to see why" >&2
      exit 1
    }
    [[ $rootless == true ]] || {
      echo "error: podman is not rootless here; run the box as your own user (see tools/README.md)" >&2
      exit 1
    }
    return 0
  fi

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
  "${BOX_CTR[@]}" image inspect "$BOX_IMAGE" >/dev/null 2>&1
}

box_remove_images() {
  local ids
  if [[ ${BOX_CTR[0]} == podman ]]; then
    ids=$(podman ps -a --format '{{.Names}}' 2>/dev/null |
      grep "^$BOX_NAME_PREFIX-" || true)
    for c in $ids; do
      podman rm -f "$c" >/dev/null 2>&1 || true
    done
    if box_have_image; then
      echo "==> removing image $BOX_IMAGE" >&2
      podman image rm -f "$BOX_IMAGE" >/dev/null
    fi
    podman image prune -f >/dev/null 2>&1 || true
    return 0
  fi
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
# fully qualified: podman won't guess a registry for a short name
FROM docker.io/library/ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive

# Node 22 ships in 26.04's repos, so no NodeSource needed
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git ripgrep fd-find jq openssh-client \
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
  "${BOX_CTR[@]}" build --tag "$BOX_IMAGE" "$ctx" || rc=$?
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
  # macOS-only: on Linux the podman socket bind-mounts straight into the box
  # (see box_docker_bridge), so there is no loopback domain to set up.
  [[ ${BOX_CTR[0]} == container ]] || return 0

  # A "localhost domain" is two host-side things: /etc/resolver/containerization.<domain>
  # and a pf rdr rule in the com.apple/container anchor. The resolver file survives a
  # reboot, the pf rule doesn't — hence the once-per-boot check, tracked by kernel boot
  # time and shared by all the *-box scripts. Neither touches the container runtime, so
  # there is nothing to restart and other boxes keep running.
  local alias="$1" ip resolver anchor
  ip="$(box_knob HOST_ALIAS_IP 203.0.113.113)"
  resolver="/etc/resolver/containerization.$alias"
  anchor="/etc/pf.anchors/com.apple.container"
  local stamp="${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/host-alias.boot" boot
  boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*{ sec = \([0-9]*\).*/\1/')

  # `dns create --localhost <ip>` writes "options localhost:<ip>" into the resolver
  # file, so that line means the domain is configured for the IP we want — the same
  # predicate gates both the fast path and the reload-vs-setup choice below, so a
  # changed ${BOX_ENV_PREFIX}_HOST_ALIAS_IP can't be missed within a boot.
  local configured=0
  if [[ -f "$resolver" && -f "$anchor" ]] && grep -qF "localhost:$ip" "$resolver"; then
    configured=1
  fi

  if [[ $configured -eq 1 && -f "$stamp" && "$(cat "$stamp")" == "$boot" ]]; then
    return 0
  fi

  if [[ $configured -eq 1 ]]; then
    # Only the pf rule can be stale. Reload it — `dns delete`+`create` would tear the
    # domain down and HUP mDNSResponder, a DNS blip for everything else on the Mac.
    echo "==> reloading the '$alias' pf rule (sudo, once per boot)" >&2
    sudo /sbin/pfctl -a com.apple/container -f "$anchor"
  else
    echo "==> setting up '$alias' -> Mac loopback (sudo, once per boot)" >&2
    sudo container system dns delete "$alias" >/dev/null 2>&1 || true
    sudo container system dns create "$alias" --localhost "$ip"
  fi
  # Only reached if the sudo above succeeded: every box script runs with `set -e`,
  # so a failure aborts before the stamp is written and the next launch retries.
  mkdir -p "$(dirname "$stamp")"
  printf '%s' "$boot" >"$stamp"
}

# ---------------------------------------------------------------- docker -----
box_docker_bridge() {
  # Expose the host's Docker to the box. On a Mac, Unix sockets can't be
  # bind-mounted into the VM, and containers can't reach the Mac at the bridge
  # gateway IP by default. Apple's supported route is a "localhost" DNS domain:
  # it installs a pf rule that redirects a chosen IP to the Mac's loopback, so
  # we listen on 127.0.0.1 with socat and let the box connect by name. On Linux
  # none of that exists: podman's Docker-compatible socket mounts straight in,
  # no socat, no sudo.
  #
  # NOTE: whatever the daemon can reach on the host (colima: its mount list), the
  # agent can reach through docker.
  BOX_DOCKER_ENV=()
  [[ "$(box_knob DOCKER 0)" == "1" ]] || return 0
  local sock

  if [[ ${BOX_CTR[0]} == podman ]]; then
    sock="$(box_knob DOCKER_SOCK)"
    if [[ -z "$sock" ]]; then
      # the user's podman API socket, socket-activated by systemd
      sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
      [[ -S "$sock" ]] || systemctl --user start podman.socket 2>/dev/null || true
    fi
    # podman's Docker API has no BuildKit; the box's docker CLI would reach for
    # buildx and fail, so pin `docker build` to the classic builder.
    [[ $(basename "$sock") == podman.sock ]] && BOX_DOCKER_ENV=(--env DOCKER_BUILDKIT=0)
    [[ -S "$sock" ]] || {
      echo "error: no Docker socket found at $sock" >&2
      echo "       systemctl --user enable --now podman.socket, or set ${BOX_ENV_PREFIX}_DOCKER_SOCK" >&2
      exit 1
    }
    # The image's docker CLI already defaults to unix:///var/run/docker.sock.
    BOX_DOCKER_ENV+=(--volume "$sock:/var/run/docker.sock")
    echo "==> docker: $sock -> /var/run/docker.sock (this session only)" >&2
    return 0
  fi

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

  command -v socat >/dev/null || {
    echo "error: ${BOX_ENV_PREFIX}_DOCKER needs socat (brew install socat)" >&2
    exit 1
  }

  local alias
  alias="$(box_knob HOST_ALIAS host.container.internal)"
  box_ensure_host_alias "$alias"

  local port=$((20000 + RANDOM % 20000))
  socat "TCP-LISTEN:$port,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$sock" &
  BOX_SOCAT_PID=$!
  trap 'kill -9 "$BOX_SOCAT_PID" 2>/dev/null' EXIT   # -9: SIGTERM makes socat log "exiting on signal 15" over the agent's last words
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

# _box_profile: if the script's flag set *_BOX_PROFILE, read
# $BOX_HOME/.env.<name> (shell lines, e.g. `export SOME_VAR=SOME_VAL`) and
# pass each variable into the box by name only, so the value stays out of the
# host's process list.
_box_profile() {
  local name file line n=0
  name="$(box_knob PROFILE "")"
  [[ -n $name ]] || return 0
  file="$BOX_HOME/.env.$name"
  [[ -f $file ]] || {
    echo "error: profile '$name' not found: $file" >&2
    exit 1
  }
  BOX_PROFILE_ENV=()
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line#export }"
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    # export, not just assign: --env NAME inherits from the environment, so a
    # bare shell variable would pass nothing.
    eval "export $line"
    BOX_PROFILE_ENV+=(--env "${BASH_REMATCH[1]}")
    n=$((n + 1))
  done <"$file"
  echo "==> profile $name: $n var(s) passed" >&2
}

# Fills BOX_RUN_ARGS with the flags every box passes: the project mounted at its
# own Mac path (so bind-mount paths the agent hands to docker mean the same
# thing to the Mac's daemon), BOX_HOME as the box's whole /root, VM sizing, the
# docker bridge, git identity, gh token, the ssh-agent and the profile's vars.
# Call box_docker_bridge first. The per-agent --env flags stay in the calling
# script.
box_run_args() {
  _box_git_env
  _box_gh_env
  _box_profile

  mkdir -p "$BOX_HOME"
  BOX_RUN_ARGS=(
    -it --rm
    # trailing '-' so GNU tr doesn't read "_.-\n" as a (reversed) range
    --name "$BOX_NAME_PREFIX-$(basename "$PWD" | tr -c 'a-zA-Z0-9_.\n-' '-')-$$"
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
  # The VM does not inherit the host terminal. Agents then think they are on a
  # dumb tty (Gemini warns "256-color support not detected"). Escape codes are
  # rendered by the host, so advertise a 256-color/truecolor terminal.
  local term="${TERM:-xterm-256color}"
  [[ $term == *256color* || $term == *direct* ]] || term=xterm-256color
  BOX_RUN_ARGS+=(--env "TERM=$term" --env "COLORTERM=${COLORTERM:-truecolor}")
  BOX_RUN_ARGS+=(
    ${BOX_DOCKER_ENV[@]+"${BOX_DOCKER_ENV[@]}"}
    ${BOX_GIT_ENV[@]+"${BOX_GIT_ENV[@]}"}
    ${BOX_GH_ENV[@]+"${BOX_GH_ENV[@]}"}
    ${BOX_PROFILE_ENV[@]+"${BOX_PROFILE_ENV[@]}"}
  )
  if [[ -n "$(box_knob SSH)" ]]; then
    if [[ ${BOX_CTR[0]} == podman ]]; then
      # podman has no --ssh; mount the agent socket at a fixed path instead.
      [[ -S "${SSH_AUTH_SOCK:-}" ]] || {
        echo "error: --ssh needs a running ssh-agent (SSH_AUTH_SOCK)" >&2
        exit 1
      }
      BOX_RUN_ARGS+=(--volume "$SSH_AUTH_SOCK:/ssh-agent.sock"
        --env SSH_AUTH_SOCK=/ssh-agent.sock)
    else
      BOX_RUN_ARGS+=(--ssh)
    fi
  fi
}

# Launch the image under whatever runtime the host has. Everything else about
# the invocation is host-independent, so the *-box scripts call this instead of
# naming the CLI.
box_run() {
  "${BOX_CTR[@]}" run "$@"
}
