# shellcheck shell=bash
# agent-box-lib.bash: the half of every *-box script that isn't about the agent —
# image lifecycle, the per-port forwards to the host, the Docker bridge, and the
# `container run` flags they all pass.
#
# Two hosts run the same image: a Mac, through Apple's `container` CLI (a VM),
# and Linux (Arch), through rootless podman — no VM, and the Mac-only machinery
# (the gateway forwards) is skipped there. Everything
# host-specific below branches on BOX_CTR.
#
# A library, not a program: it has no shebang, isn't executable, and each *-box
# script sources the copy sitting next to it.
#
# The sourcing script sets these variables first:
#
#   BOX_IMAGE        image tag to build and run       (e.g. "claude-box")
#   BOX_NAME_PREFIX  prefix for container names       (e.g. "cl")
#   BOX_ENV_PREFIX   its user-facing env-knob prefix  (e.g. "CL_BOX")
#   BOX_HOME         host dir mounted as the box's /root
#   BOX_KEEP         paths under BOX_HOME that `--clean` preserves, relative
#                    (e.g. (.claude) — the logins and settings, not the runtimes)
#   BOX_CAN_SYNC     optional: 1 if the box adds --sync / --sync-only (default 0)
#   BOX_NPM_PKG      optional: the agent's npm package, and BOX_NPM_TAG the
#                    version or tag it installs; a launch then warns when the
#                    image is behind what the tag points to now
#
# BOX_ENV_PREFIX is how the shared knobs stay named after their own tool:
# everything below reads ${BOX_ENV_PREFIX}_DOCKER, _DOCKER_SOCK, _HOST_PORT,
# _HOST_GATEWAY, _SSH, _SEARCH, _CPUS, _MEMORY, _PROFILE and _RUNTIME, and names that same
# variable when it has to complain about it.
#
# ...and defines one function:
#
#   box_dockerfile_agent   writes the agent-specific Dockerfile tail (its
#                          `npm install -g`, any ENV, the ENTRYPOINT) to stdout;
#                          box_build_image appends it to the shared base,
#                          followed by ~/.box.default.dockerfile and ~/.box.<profile>.dockerfile.

[[ ${BASH_SOURCE[0]} != "$0" ]] || {
  echo "error: agent-box-lib.bash is a library; source it from a *-box script." >&2
  exit 1
}

# The tools next to this lib (box-gh-token, box-secret). The scripts source it
# by its resolved path, so this is the real directory.
BOX_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# _box_port N: success (0) when N is a TCP port, failure (1) otherwise. A leading
# zero would read as octal in arithmetic, so read the value as decimal.
_box_port() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# _box_ports LIST: append each comma-separated port in LIST to BOX_HOST_PORTS,
# skipping repeats. Returns 1 (appending nothing) if any part is not a port.
_box_ports() {
  local list="$1" p q _box_ports_arr
  [[ -n $list ]] || return 0
  local IFS=,
  read -ra _box_ports_arr <<<"$list"
  for p in "${_box_ports_arr[@]}"; do
    _box_port "$p" || return 1
  done
  for p in "${_box_ports_arr[@]}"; do
    p=$((10#$p))
    for q in ${BOX_HOST_PORTS[@]+"${BOX_HOST_PORTS[@]}"}; do
      [[ $q == "$p" ]] && continue 2
    done
    BOX_HOST_PORTS+=("$p")
  done
  return 0
}

# ----------------------------------------------------------------- flags -----
# Parses common flags shared by all boxes:
#   --rebuild, --build-only, --clean, --clean-all, --clean-data, --ssh, --gh[=host], --docker, --search,
#   --host-port <port>, --profile[=NAME], --shell
# plus (--sync, --sync-only) when BOX_CAN_SYNC=1. A --clean flag on its own is
# the whole command; with --rebuild or --build-only it runs first and the build
# follows (see box_clean_or_exit). --host-port takes a port or a comma-separated
# list, repeatable, into BOX_HOST_PORTS (see _box_host_port_args).
# Remaining arguments are left in BOX_ARGS; caller typically runs:
#   box_parse_args "$@"
#   set -- ${BOX_ARGS[@]+"${BOX_ARGS[@]}"}
box_parse_args() {
  REBUILD=0
  BUILD_ONLY=0
  CLEAN=
  SYNC=0
  SYNC_ONLY=0
  BOX_SHELL=0
  BOX_HOST_PORTS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --rebuild)
      REBUILD=1
      shift
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --clean)
      CLEAN=keep
      shift
      ;;
    --clean-all)
      CLEAN=all
      shift
      ;;
    --clean-data)
      CLEAN=data
      shift
      ;;
    --ssh)
      printf -v "${BOX_ENV_PREFIX}_SSH" '%s' 1
      shift
      ;;
    --gh)
      printf -v "${BOX_ENV_PREFIX}_GH" '%s' 1
      shift
      ;;
    --gh=host)
      printf -v "${BOX_ENV_PREFIX}_GH" '%s' host
      shift
      ;;
    --docker)
      printf -v "${BOX_ENV_PREFIX}_DOCKER" '%s' 1
      shift
      ;;
    --host-port)
      [[ $# -ge 2 ]] || {
        echo "error: --host-port requires a port" >&2
        exit 1
      }
      [[ -n $2 ]] && _box_ports "$2" || {
        echo "error: --host-port '$2': not a port" >&2
        exit 1
      }
      shift 2
      ;;
    --host-port=*)
      [[ -n ${1#--host-port=} ]] && _box_ports "${1#--host-port=}" || {
        echo "error: --host-port '${1#--host-port=}': not a port" >&2
        exit 1
      }
      shift
      ;;
    --search)
      printf -v "${BOX_ENV_PREFIX}_SEARCH" '%s' 1
      shift
      ;;
    --profile)
      [[ $# -ge 2 ]] || {
        echo "error: --profile requires an argument" >&2
        exit 1
      }
      printf -v "${BOX_ENV_PREFIX}_PROFILE" '%s' "$2"
      shift 2
      ;;
    --shell)
      BOX_SHELL=1
      shift
      ;;
    --profile=*)
      printf -v "${BOX_ENV_PREFIX}_PROFILE" '%s' "${1#--profile=}"
      shift
      ;;
    --sync)
      [[ ${BOX_CAN_SYNC:-0} -eq 1 ]] || break
      SYNC=1
      shift
      ;;
    --sync-only)
      [[ ${BOX_CAN_SYNC:-0} -eq 1 ]] || break
      SYNC_ONLY=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
    esac
  done

  BOX_ARGS=("$@")

  # These names become part of file paths (~/.box.NAME.env, ~/.box.NAME.dockerfile),
  # image tags and volume names, so keep them to a plain word.
  local knob val
  for knob in PROFILE PROJECT; do
    val="$(box_knob "$knob")"
    [[ -z $val || $val =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || {
      echo "error: ${BOX_ENV_PREFIX}_$knob '$val': use letters, digits, '_', '.' and '-'" >&2
      exit 1
    }
  done

  # The flag wins over ${BOX_ENV_PREFIX}_HOST_PORT (same syntax).
  if [[ -z ${BOX_HOST_PORTS[*]-} ]]; then
    val="$(box_knob HOST_PORT)"
    _box_ports "$val" || {
      echo "error: ${BOX_ENV_PREFIX}_HOST_PORT '$val': not a port" >&2
      exit 1
    }
  fi
}

# --------------------------------------------------------------- runtime -----
# podman's OCI runtime for `run`: krun (a microVM) unless ${BOX_ENV_PREFIX}_RUNTIME
# names another, e.g. crun for a plain container. Under WSL2, crun: krun there
# needs nested KVM, and Ubuntu doesn't package it. On a Mac only what was set.
box_runtime() {
  if [[ ${BOX_CTR[0]} != podman ]]; then
    box_knob RUNTIME
  elif _box_is_wsl; then
    box_knob RUNTIME crun
  else
    box_knob RUNTIME krun
  fi
}

# WSL2's kernel names itself, e.g. 6.6.87.2-microsoft-standard-WSL2.
_box_is_wsl() {
  [[ ${BOX_CTR[0]} == podman && "$(uname -r)" == *[Mm]icrosoft* ]]
}

# WSL2 is a VM, but your distro lives in it too: an escape from crun lands
# there, next to your files and, unless /etc/wsl.conf turns them off, the
# Windows drives (/mnt/c) and Windows programs (interop). Say which are open.
BOX_WSL_CONF=/etc/wsl.conf
_box_wsl_note() {
  _box_is_wsl && [[ "$(box_runtime)" != krun ]] || return 0
  local open=()
  [[ "$(_box_wsl_conf automount enabled)" == false ]] || open+=("Windows drives (/mnt/c)")
  [[ "$(_box_wsl_conf interop enabled)" == false ]] || open+=("Windows programs (interop)")
  [[ ${#open[@]} -gt 0 ]] || return 0
  echo "==> WSL2: no VM of its own (crun); an escape lands in this distro, with" >&2
  if [[ ${#open[@]} -eq 2 ]]; then
    echo "    ${open[0]} and ${open[1]} reachable. See docs/WSL2.md" >&2
  else
    echo "    ${open[0]} reachable. See docs/WSL2.md" >&2
  fi
}

# _box_wsl_conf SECTION KEY: the value in BOX_WSL_CONF, lowercased; empty if unset.
_box_wsl_conf() {
  [[ -r $BOX_WSL_CONF ]] || return 0
  awk -v s="[$1]" -v k="$2=" '
    { sub(/[#;].*/, ""); gsub(/[ \t\r]/, ""); $0 = tolower($0) }
    /^\[/ { sec = ($0 == s); next }
    sec && index($0, k) == 1 { v = substr($0, length(k) + 1) }
    END { print v }' "$BOX_WSL_CONF"
}

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
    _box_wsl_note
    # krun boots each container as a libkrun microVM over KVM: the agent gets
    # its own kernel instead of sharing the host's, much like the Mac's VM.
    # It is the default, so say how to opt out rather than quietly drop the VM.
    if [[ "$(box_runtime)" == krun ]]; then
      command -v krun >/dev/null 2>&1 || {
        echo "error: the box runs under krun, which isn't installed: sudo pacman -S krun" >&2
        echo "       (or ${BOX_ENV_PREFIX}_RUNTIME=crun for a plain container, no VM)" >&2
        exit 1
      }
      [[ -r /dev/kvm && -w /dev/kvm ]] || {
        echo "error: the box runs under krun, which needs read/write on /dev/kvm (the kvm group)" >&2
        echo "       (or ${BOX_ENV_PREFIX}_RUNTIME=crun for a plain container, no VM)" >&2
        exit 1
      }
    fi
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
  # Before the build, not after: a box that won't start shouldn't wait for one.
  # --build-only starts no box, so it has nothing to ask.
  [[ ${BUILD_ONLY:-0} -eq 1 ]] || _box_old_alias_down
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
# Ubuntu's mirrors over https: their port 80 has stopped answering. The base image
# has no CA bundle yet, so this first run skips peer verification; apt checks
# every package against the archive's GPG signatures, not TLS, so that is no
# weaker than the http it replaces. Later apt runs verify, ca-certificates being in.
RUN sed -i 's|http://|https://|' /etc/apt/sources.list.d/ubuntu.sources \
 && apt-get -o Acquire::https::Verify-Peer=false update \
 && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
      build-essential ca-certificates curl git ripgrep fd-find jq openssh-client \
      python3 unzip less nodejs npm socat \
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

# box-entry runs ahead of the agent (box_build_image puts it in front of the
# agent's ENTRYPOINT). Under krun the ssh-agent arrives as a TCP port on the
# host, since a bind-mounted Unix socket doesn't cross the VM boundary; turn it
# back into the socket ssh expects. On a Mac, each --host-port port arrives at
# its own port on the VM network's gateway (BOX_HOST_PORTS holds port:gateway
# port pairs); relay it from the box's own 127.0.0.1. Fill any empty
# VOLUME from the copy taken at build time (podman fills a new volume itself;
# Apple's container doesn't, and hands over a fresh ext4 with only
# lost+found). A failing hook stops the box:
# an agent without the services it expects is worse than an error.
# Then run the hooks in /etc/box-entry.d (a profile's Dockerfile can start
# services there) and hand over. With hooks in
# /etc/box-exit.d it stays around instead, and runs them once the agent exits,
# so services stop cleanly before the box is torn down. The relays' socat logs
# to /tmp/box-entry-socat.log, not the agent's terminal, each relay's share
# capped at 1 MiB (the box's /tmp is RAM); `cap` keeps reading past it, so
# socat never blocks. The label tells the host which box-entry this image has.
RUN mkdir -p /etc/box-entry.d /etc/box-exit.d \
 && printf '%s\n' '#!/bin/sh' \
      'cap() { awk -v max=1048576 "{ n += length(\$0) + 1 } n <= max { print; fflush(); next } !c { print \"(log capped at 1 MiB; the rest dropped)\"; fflush(); c = 1 }" >>/tmp/box-entry-socat.log; }' \
      'if [ -n "$BOX_SSH_AGENT_TCP" ]; then' \
      '  socat "UNIX-LISTEN:$SSH_AUTH_SOCK,fork,unlink-early,mode=600" "TCP:$BOX_SSH_AGENT_TCP" 2>&1 | cap &' \
      '  i=0; while [ ! -S "$SSH_AUTH_SOCK" ] && [ $i -lt 50 ]; do sleep 0.05; i=$((i + 1)); done' \
      'fi' \
      'for m in $BOX_HOST_PORTS; do' \
      '  p=${m%%:*}' \
      '  socat "TCP-LISTEN:$p,bind=127.0.0.1,reuseaddr,fork" "TCP:$BOX_HOST_GATEWAY:${m#*:}" 2>&1 | cap &' \
      '  i=0; while ! grep -q ":$(printf %04X "$p") 00000000:0000 0A" /proc/net/tcp && [ $i -lt 50 ]; do sleep 0.05; i=$((i + 1)); done' \
      'done' \
      'if [ -f /etc/box-volumes ]; then while read -r p; do' \
      '  s="/usr/local/share/box-seed$p"' \
      '  [ -z "$(ls -A "$p" 2>/dev/null | grep -vx lost+found)" ] || continue' \
      '  cp -a "$s/." "$p/" && chown "$(stat -c %u:%g "$s")" "$p" && chmod "$(stat -c %a "$s")" "$p"' \
      'done </etc/box-volumes; fi' \
      'for f in /etc/box-entry.d/*; do' \
      '  [ -x "$f" ] || continue' \
      '  "$f" || { echo "box-entry: $f failed; not starting the agent" >&2; exit 1; }' \
      'done' \
      '[ -n "$(ls /etc/box-exit.d)" ] || exec "$@"' \
      '"$@"; rc=$?' \
      'for f in /etc/box-exit.d/*; do [ -x "$f" ] && "$f"; done' \
      'exit $rc' >/usr/local/bin/box-entry \
 && chmod +x /usr/local/bin/box-entry
LABEL agent-box.entry=8

EOF
}

# Your own additions to the image, appended after the agent's tail:
# ~/.box.default.dockerfile for every image, then ~/.box.<profile>.dockerfile
# for the profile *_BOX_PROFILE names, as with ~/.box.default.env and
# ~/.box.<profile>.env.
# The build context is empty, so RUN/ENV, not COPY.
_box_profile_dockerfile() {
  local name
  name="$(box_knob PROFILE "")"
  [[ -n $name && $name != default ]] || return 0
  printf '%s' "$HOME/.box.$name.dockerfile"
}

_box_dockerfile_custom() {
  local f
  for f in "$HOME/.box.default.dockerfile" "$(_box_profile_dockerfile)"; do
    [[ -n $f && -f $f ]] || continue
    printf '\n# ---- %s\n' "$f"
    cat "$f"
  done
}

# The VOLUME paths the additions declare, from either form (VOLUME /a /b or
# VOLUME ["/a", "/b"]). The image is rebuilt whenever the additions change, so
# this is what the image has, without asking the runtime.
_box_volume_paths() {
  _box_dockerfile_custom | sed -n 's/^[[:space:]]*VOLUME[[:space:]][[:space:]]*//p' |
    tr -d '[],"' | tr ' \t' '\n\n' | grep '^/' || true
}

# Copies each VOLUME path's built contents aside, for box-entry to fill an
# empty volume from, and lists the paths in /etc/box-volumes. Reading a VOLUME
# path after its VOLUME line is fine; only changes to it would be dropped.
_box_dockerfile_seed() {
  local paths
  paths="$(_box_volume_paths | tr '\n' ' ')"
  [[ -n ${paths// /} ]] || return 0
  printf '\n# ---- seed for the VOLUME paths (see box-entry)\n'
  printf 'RUN for p in %s; do mkdir -p "$p" "/usr/local/share/box-seed$p" && cp -a "$p/." "/usr/local/share/box-seed$p/" && echo "$p" >>/etc/box-volumes; done\n' "$paths"
}

# A profile with its own Dockerfile gets its own image (pi-box-work), so
# switching profiles doesn't rebuild every time. Called before anything uses
# BOX_IMAGE; BOX_IMAGE_BASE keeps the script's own name so a second call
# doesn't stack tags.
_box_profile_image() {
  local f
  BOX_IMAGE="${BOX_IMAGE_BASE:=$BOX_IMAGE}"
  f="$(_box_profile_dockerfile)"
  [[ -n $f && -f $f ]] || return 0
  BOX_IMAGE="$BOX_IMAGE_BASE-$(box_knob PROFILE | tr 'A-Z' 'a-z')"
}

# Where the checksum of the additions an image was built with is kept, so a
# launch can tell they changed. Missing means none.
_box_custom_stamp() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/$BOX_IMAGE.custom"
}

# box_build_image [note]   note is shown in the build banner, e.g. "pi@latest"
box_build_image() {
  # Cleaned up by hand rather than with a RETURN trap: bash leaves such a trap
  # registered after the function returns, and it would fire again — with $ctx
  # long gone — when box_ensure_image returns.
  local ctx note="${1-}" rc=0 nocache=() tail
  # --rebuild: skip the layer cache, else `npm install ...@latest` is reused stale
  [[ ${2-0} -eq 1 ]] && nocache=(--no-cache)
  # box-entry goes in front of the agent. Only the exec form can be rewritten,
  # and a tail that slipped through would pass box_run's label check (the label
  # is in the base) while skipping the ssh bridge and hooks, so insist on it.
  tail="$(box_dockerfile_agent | sed 's|^ENTRYPOINT \["|ENTRYPOINT ["/usr/local/bin/box-entry", "|')"
  [[ $tail == *'ENTRYPOINT ["/usr/local/bin/box-entry", '* ]] || {
    echo "error: $BOX_IMAGE's Dockerfile tail needs an exec-form ENTRYPOINT [\"...\"]" >&2
    return 1
  }
  ctx=$(mktemp -d)

  {
    box_dockerfile_base
    printf '%s\n' "$tail"
    _box_dockerfile_custom
    _box_dockerfile_seed
  } >"$ctx/Dockerfile"

  echo "==> building image $BOX_IMAGE${note:+ ($note)}" >&2
  "${BOX_CTR[@]}" build ${nocache[@]+"${nocache[@]}"} --tag "$BOX_IMAGE" "$ctx" || rc=$?
  rm -rf "$ctx"
  if [[ $rc -eq 0 ]]; then
    mkdir -p "$(dirname "$(_box_custom_stamp)")"
    _box_dockerfile_custom | cksum >"$(_box_custom_stamp)"
    [[ -z ${BOX_NPM_PKG-} ]] || _box_image_version >"$(_box_version_stamp)"
  fi
  return "$rc"
}

# True when the Dockerfile additions differ from what the image was built with.
_box_custom_changed() {
  local built
  built="$(cat "$(_box_custom_stamp)" 2>/dev/null || printf '' | cksum)"
  [[ "$(_box_dockerfile_custom | cksum)" != "$built" ]]
}

# The agent version in the image, read once per build and kept here, so a
# launch doesn't have to start a container to know it. Empty if npm didn't say.
_box_version_stamp() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/$BOX_IMAGE.version"
}

_box_image_version() {
  "${BOX_CTR[@]}" run --rm --entrypoint npm "$BOX_IMAGE" ls -g --depth=0 "$BOX_NPM_PKG" 2>/dev/null |
    sed -n "s|.*$BOX_NPM_PKG@\([^ ]*\).*|\1|p" | head -1 || true
}

# What the registry has under BOX_NPM_TAG, as of the last lookup (empty if
# none worked). Every box image of this agent shares it.
_box_npm_cache() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/npm-$(printf '%s' "$BOX_NPM_PKG@$BOX_NPM_TAG" | tr / _)"
}

# Looks it up again, at most once a day (failures included, so being offline
# costs nothing).
_box_npm_refresh() {
  local cache v
  cache="$(_box_npm_cache)"
  [[ -z $(find "$cache" -mmin -1440 2>/dev/null) ]] || return 0
  touch "$cache"
  v="$(curl -fsS --max-time 10 "https://registry.npmjs.org/$BOX_NPM_PKG/$BOX_NPM_TAG" 2>/dev/null |
    grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)" || true
  [[ -z $v ]] || printf '%s\n' "$v" >"$cache"
}

# Warn when the image's agent isn't what BOX_NPM_TAG now points to.
# Nothing else notices a new release, and a profile's image only rebuilds with
# its own --profile, so it can fall far behind. The lookup runs in the
# background, so this launch compares against the previous one's answer.
_box_check_version() {
  [[ -n ${BOX_NPM_PKG-} ]] || return 0
  local stamp have want profile
  stamp="$(_box_version_stamp)"
  mkdir -p "$(dirname "$stamp")"
  # an image built before this check: ask it once
  [[ -f $stamp ]] || _box_image_version >"$stamp"
  (_box_npm_refresh) </dev/null >/dev/null 2>&1 &
  have="$(cat "$stamp")"
  want="$(cat "$(_box_npm_cache)" 2>/dev/null || true)"
  [[ -n $have && -n $want && $have != "$want" ]] || return 0
  profile="$(box_knob PROFILE)"
  echo "==> $BOX_IMAGE has $BOX_NPM_PKG $have, $BOX_NPM_TAG is $want;" \
    "update with: ${0##*/}${profile:+ --profile=$profile} --rebuild" >&2
}

# box_ensure_image $REBUILD $BUILD_ONLY [note]
box_ensure_image() {
  local rebuild="$1" build_only="$2" note="${3-}"
  _box_profile_image
  if [[ $rebuild -eq 1 ]]; then
    box_remove_images
    box_build_image "$note" 1
  elif [[ $build_only -eq 1 ]] || ! box_have_image; then
    box_build_image "$note"
  elif _box_custom_changed; then
    echo "==> your Dockerfile additions changed" >&2
    box_build_image "$note"
  fi
  # Not after --rebuild, which just installed the newest. Other builds reuse a
  # cached npm layer, so they can still be behind.
  [[ $rebuild -eq 1 ]] || _box_check_version
}

# ----------------------------------------------------------------- clean -----
# box_clean keep   drop everything in BOX_HOME except BOX_KEEP (runtimes, caches
#                  and package downloads go; the box stays logged in)
# box_clean all    delete BOX_HOME outright, after asking
box_clean() {
  local mode="$1" home="$BOX_HOME" tmp rel reply
  [[ $mode != data ]] || {
    _box_clean_data
    return
  }
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
      return 1
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

# box_clean_or_exit: what main does with the --clean flags. Alone, a clean is
# the whole command and nothing else runs. With --rebuild or --build-only the
# clean goes first and the build follows, so taking an agent's new major version
# is one command: `opencode-box --clean-all --rebuild`. --sync-only keeps its
# old meaning (clean, then stop) and a cancelled clean stops everything.
box_clean_or_exit() {
  [[ -n ${CLEAN-} ]] || return 0
  box_clean "$CLEAN" || exit 0
  [[ ${SYNC_ONLY:-0} -eq 0 && ( ${REBUILD:-0} -eq 1 || ${BUILD_ONLY:-0} -eq 1 ) ]] || exit 0
}

# box_clean data: delete this profile and project's service volumes, after asking.
_box_clean_data() {
  local prefix vols=() v reply
  prefix="$(_box_data_prefix)"
  while IFS= read -r v; do
    [[ $v == "$prefix"* ]] && vols+=("$v")
  done < <(_box_volume_names)
  [[ ${#vols[@]} -gt 0 ]] || {
    echo "==> no volumes for ${prefix}*" >&2
    return 0
  }
  printf '  %s\n' "${vols[@]}" >&2
  printf 'Delete these %d volume(s)? [y/N] ' "${#vols[@]}" >&2
  read -r reply </dev/tty || reply=""
  [[ $reply == [yY]* ]] || {
    echo "==> cancelled" >&2
    return 1
  }
  "${BOX_CTR[@]}" volume rm "${vols[@]}" >/dev/null
  echo "==> removed ${#vols[@]} volume(s)" >&2
}

# All volume names, one per line, from either runtime.
_box_volume_names() {
  if [[ ${BOX_CTR[0]} == podman ]]; then
    podman volume ls -q
  else
    container volume list --format json | grep -o '"name" *: *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/'
  fi
}

# ----------------------------------------------------------- host access -----
# Everything that reaches the host goes through one per-port mechanism, so no
# box is ever given all of the host's loopback: the --host-port ports, and the
# ssh/docker bridges (a Unix socket can't cross a VM boundary, so _box_bridge
# serves it on a TCP port).
#
# podman: pasta forwards each port (-T). The box dials 127.0.0.1:<port> and
# lands on the same port of the host's 127.0.0.1, and nothing else there
# (podman adds --no-map-gw). Each box has its own pasta, so other boxes can't
# use its forwards.
#
# Mac: there is no per-port option. Each forward gets a free port on the VM
# network's gateway, which socat serves once the box is up, to the box's own
# IP only (_box_mac_forwards). The box dials the gateway; for --host-port,
# box-entry relays each port from the box's own 127.0.0.1.
BOX_PASTA_FWD=() # podman: host loopback ports to forward
BOX_MAC_FWD=()   # Mac: "<gateway port> <socat address>", one per forward

_box_gateway() { box_knob HOST_GATEWAY 192.168.64.1; }

# The address the box dials for a forwarded port.
_box_forward_addr() {
  if [[ ${BOX_CTR[0]} == podman ]]; then
    printf '127.0.0.1'
  else
    _box_gateway
  fi
}

# --host-port: the agent dials 127.0.0.1:<port> as if the service ran in the
# box (see host access above).
_box_host_port_args() {
  [[ -n ${BOX_HOST_PORTS[*]-} ]] || return 0
  local list p map=()
  list="$(IFS=,; echo "${BOX_HOST_PORTS[*]}")"
  if [[ ${BOX_CTR[0]} == podman ]]; then
    BOX_PASTA_FWD+=("${BOX_HOST_PORTS[@]}")
    echo "==> host: 127.0.0.1:$list forwarded to the host (only those)" >&2
    return 0
  fi

  local info
  info="$(_box_entry_version)"
  # 7 brought box-entry's port:gateway-port pairs, which this needs; 8 only
  # moved its socat's messages into a log
  [[ ${info:-0} -ge 7 ]] || {
    echo "error: $BOX_IMAGE predates the box-entry --host-port needs; rerun with --build-only" >&2
    exit 1
  }
  command -v socat >/dev/null || {
    echo "error: --host-port needs socat (brew install socat)" >&2
    exit 1
  }
  for p in "${BOX_HOST_PORTS[@]}"; do
    _box_free_port "$(_box_gateway)"
    BOX_MAC_FWD+=("$BOX_FREE_PORT TCP:127.0.0.1:$p")
    map+=("$p:$BOX_FREE_PORT")
  done
  BOX_RUN_ARGS+=(--env "BOX_HOST_GATEWAY=$(_box_gateway)" --env "BOX_HOST_PORTS=${map[*]}")
  echo "==> host: 127.0.0.1:$list forwarded to the Mac (only those, only this box)" >&2
}

# _box_free_port ADDR: set BOX_FREE_PORT to a port in BOX_BRIDGE_PORTS that
# nothing listens on at ADDR, reserved for this launch (_box_reserve_port). It
# starts at a random offset, so concurrent launches rarely want the same one,
# and the reservation settles it when they do: on a Mac a forward only listens
# once its box is up, seconds after the port was picked. podman: a port is free
# when nothing answers on it; host loopback refuses a closed port at once. Mac:
# no probing, as macOS may silently drop a connection to a closed port on the
# gateway (the firewall's stealth mode), each probe then hanging for over a
# minute; netstat says what listens instead, on any address.
_box_free_port() {
  local addr="$1" i p off=$RANDOM taken=" "
  if [[ ${BOX_CTR[0]} != podman ]]; then
    taken+="$(_box_listening)"
  fi
  for ((i = 0; i < BOX_BRIDGE_PORTS[1]; i++)); do
    p=$((BOX_BRIDGE_PORTS[0] + (off + i) % BOX_BRIDGE_PORTS[1]))
    [[ $taken == *" $p "* ]] && continue
    if [[ ${BOX_CTR[0]} == podman ]]; then
      (exec 3<>"/dev/tcp/$addr/$p") 2>/dev/null && continue
    fi
    _box_reserve_port "$p" || continue
    BOX_FREE_PORT=$p
    return 0
  done
  echo "error: no free port in $BOX_BRIDGE_PORTS-$((BOX_BRIDGE_PORTS[0] + BOX_BRIDGE_PORTS[1] - 1)) at $addr" >&2
  exit 1
}

# Mac: the TCP ports something listens on, on any address, space-separated.
_box_listening() {
  netstat -an -p tcp 2>/dev/null |
    awk '$NF == "LISTEN" { n = split($4, a, "."); printf "%s ", a[n] }'
}

# _box_reserve_port P: claim port P until this launch exits, or fail if a live
# launch holds it, this one included. A claim is a directory (mkdir is atomic)
# holding the owner's PID; one whose owner is gone is taken over, one with no
# PID yet is being made.
_box_reserve_port() {
  local dir owner
  dir="${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/ports/$1"
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    owner="$(cat "$dir/pid" 2>/dev/null)" || true
    [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null || return 1
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null || return 1
  fi
  echo $$ >"$dir/pid"
  _box_at_exit "rm -rf '$dir'"
}

# The one --network flag for all of podman's forwards, or, on a Mac, socat for
# each forward once the box has an IP. Call last: the bridges add theirs late.
_box_forward_args() {
  if [[ ${BOX_CTR[0]} == podman ]]; then
    [[ -n ${BOX_PASTA_FWD[*]-} ]] || return 0
    local net=pasta: sep= p
    for p in "${BOX_PASTA_FWD[@]}"; do
      net+="$sep-T,$p"
      sep=,
    done
    BOX_RUN_ARGS+=(--network "$net")
  elif [[ -n ${BOX_MAC_FWD[*]-} ]]; then
    _box_mac_forwards "$BOX_RUN_NAME"
  fi
}

# _box_mac_forwards NAME: in the background, wait for the box NAME to show up in
# `container ls` with an IP, then serve each BOX_MAC_FWD on the gateway to that
# IP alone (socat's range=), so no other box can use them. A forward is up a
# moment after the box; the agent takes longer than that to start. Each socat
# writes its own PID to a file before it starts, and the exit trap reads that
# file only after killing the watcher, so one spawned as the launch ends isn't
# missed. A second in, the watcher checks each forward listens, and says so on
# the terminal if one doesn't: the box would just see its connections closed.
_box_mac_forwards() {
  local name="$1" gw pids watcher
  gw="$(_box_gateway)"
  pids="$(mktemp "${TMPDIR:-/tmp}/agent-box-fwd.XXXXXX")"
  (
    ip=
    for ((i = 0; i < 1200; i++)); do
      ip="$(container ls 2>/dev/null | awk -v n="$name" \
        '$1 == n && $5 == "running" && $6 ~ /^[0-9.]+\// { sub(/\/.*/, "", $6); print $6 }')"
      [[ -z $ip ]] || break
      sleep 0.1
    done
    [[ -n $ip ]] || {
      echo "warning: $name showed no IP in \`container ls\` for 2 minutes; nothing is forwarded, so the box's connections to the host will be closed" >&2
      exit 1
    }
    for f in "${BOX_MAC_FWD[@]}"; do
      sh -c 'echo $$ >>"$0"; exec "$@"' "$pids" \
        socat "TCP-LISTEN:${f%% *},bind=$gw,reuseaddr,fork,range=$ip/32" "${f#* }" 2> >(_box_socat_to) &
    done
    sleep 1
    listening=" $(_box_listening)"
    for f in "${BOX_MAC_FWD[@]}"; do
      [[ $listening == *" ${f%% *} "* ]] ||
        echo "warning: nothing listens on $gw:${f%% *} for ${f#* }; see $(_box_socat_log)" >&2
    done
  ) &
  watcher=$!
  # Not a job of this shell any more, so killing it at exit is quiet: bash
  # would print the whole subshell as "Killed: 9" when the box exits first.
  disown "$watcher"
  _box_at_exit "kill -9 $watcher 2>/dev/null; sleep 0.1; kill -9 \$(cat '$pids') 2>/dev/null; rm -f '$pids'"
}

# Before the boxes forwarded port by port, --docker on a Mac reached the Mac at
# a localhost DNS domain: a pf rule, loaded once per boot (the stamp records
# which), that sends a fixed IP to all of Mac loopback, from every VM, until a
# reboot. One loaded this boot defeats the per-port forwards, so offer to take
# it down; without a yes, or without a terminal to ask on, stop. "c" goes
# ahead with it up. Nothing sets it up any more, so this asks once at most.
_box_old_alias_down() {
  [[ ${BOX_CTR[0]} == container ]] || return 0
  local stamp alias reply
  stamp="$(_box_alias_stamp)"
  [[ -f $stamp && "$(cat "$stamp")" == "$(_box_boot_time)" ]] || return 0
  alias="$(box_knob HOST_ALIAS host.container.internal)"
  echo "==> An older --docker set up $alias this boot: until it's taken down, any" >&2
  echo "    box can reach every Mac loopback port there. The boxes don't use it any" >&2
  echo "    more. Taking it down restarts the container system, which stops every" >&2
  echo "    running box. To do it yourself:" >&2
  echo "      sudo /sbin/pfctl -a com.apple/container -F nat && sudo container system dns delete $alias && container system stop && container system start && rm '$stamp'" >&2
  printf 'Take it down now (sudo)? [Y/n, c to continue with it up] ' >&2
  read -r reply <"${BOX_TTY:-/dev/tty}" || reply=n
  case $reply in
  "" | [yY]*)
    # The anchor holds only the alias's rdr, so flushing it is safe. dns delete
    # leaves every box offline until the container system restarts.
    local out
    out=$(sudo /sbin/pfctl -a com.apple/container -F nat 2>&1) || {
      printf '%s\n' "$out" >&2
      echo "error: could not take $alias down" >&2
      exit 1
    }
    sudo container system dns delete "$alias" >/dev/null 2>&1 || true
    echo "==> restarting the container system (stops running boxes)" >&2
    container system stop && container system start
    rm -f "$stamp"
    echo "==> $alias taken down" >&2
    ;;
  [cC]*)
    echo "==> continuing with $alias open to every box" >&2
    ;;
  *)
    echo "error: not starting with $alias open; take it down or reboot" >&2
    exit 1
    ;;
  esac
}

# Where the older --docker recorded the boot it set the pf rule up in.
_box_alias_stamp() {
  printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/agent-box/host-alias.boot"
}

# The Mac's kernel boot time, in seconds.
_box_boot_time() {
  sysctl -n kern.boottime 2>/dev/null | sed 's/.*{ sec = \([0-9]*\).*/\1/'
}

# ------------------------------------------------------------------ exit -----
# Commands to run when the script exits (bridges, locks). One EXIT trap runs
# them all, so no caller's trap replaces another's.
BOX_AT_EXIT=()
_box_at_exit() {
  BOX_AT_EXIT+=("$1")
  trap '_box_run_at_exit' EXIT
}
# Runs every cleanup, newest first, and keeps the script's own exit status.
# Newest first so a thing is undone before what it was built on: a profile's
# .down before default's, a service before the reservation of its port. Under
# set -e a failing cleanup (a forwarder that already died) would otherwise end
# the trap early, skipping the rest, and become the status.
_box_run_at_exit() {
  local rc=$? c rev=()
  # reversed by prepending: bash 3.2 under set -u can't index an empty array
  for c in ${BOX_AT_EXIT[@]+"${BOX_AT_EXIT[@]}"}; do
    rev=("$c" ${rev[@]+"${rev[@]}"})
  done
  for c in ${rev[@]+"${rev[@]}"}; do
    eval "$c" || true
  done
  return "$rc"
}

# ---------------------------------------------------------------- bridge -----
# True when the box is a krun microVM, where a bind-mounted Unix socket is just
# a file to the guest kernel: connecting to it never reaches the host's listener.
_box_is_krun() {
  [[ ${BOX_CTR[0]} == podman && "$(box_runtime)" == krun ]]
}

# _box_bridge WHAT SOCK: serve the Unix socket SOCK on a TCP port the box can
# reach (see host access), for a VM that can't connect to the socket directly,
# and set BOX_BRIDGE_PORT. The listener lives as long as this script.
#
# Every host-side socat logs through _box_socat_to: its warnings (a refused
# connection, a peer outside range=) would otherwise land on the agent's screen.
#
# podman: a free port on host loopback, served now and forwarded by pasta. Any
# local user can connect to 127.0.0.1, which is why the range is fixed and
# small: one nft rule can keep other users off it (tools/README.md). Keep the
# two in step. It sits below Linux's ephemeral ports (32768+), so no outgoing
# connection lands there. Mac: a free port on the gateway, served to this box
# alone once it is up.
BOX_BRIDGE_PORTS=(24100 100) # first port, count

# Logs are bounded twice: each socat's share of its launch's log is capped at
# BOX_LOG_MAX bytes (so a log holds at most that times the launch's forwards),
# and a launch deletes all but the newest BOX_LOGS_KEPT. box-entry caps the
# box's own the same way (its /tmp is RAM). The writers share a log line by
# line: each prints whole lines, flushed, to a file opened for appending.
BOX_LOG_MAX=1048576
BOX_LOGS_KEPT=10

# _box_socat_to: copy stdin (a socat's stderr) to this launch's log until it
# has written BOX_LOG_MAX bytes, say so once, then drop the rest. It keeps
# reading, so the socat never blocks on a full pipe or dies of SIGPIPE.
_box_socat_to() {
  awk -v max="$BOX_LOG_MAX" '
    { n += length($0) + 1 }
    n <= max { print; fflush(); next }
    !capped { print "(log capped at " max " bytes; the rest dropped)"; fflush(); capped = 1 }
  ' >>"$(_box_socat_log)"
}

# This launch's socat log. The first call creates it and deletes the oldest
# launches' beyond BOX_LOGS_KEPT. $$ is the launch's PID in subshells too.
_box_socat_log() {
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/agent-box" log old
  log="$dir/socat-$$.log"
  if [[ ! -e $log ]]; then
    mkdir -p "$dir"
    touch "$log"
    ls -1t "$dir"/socat-*.log | tail -n +$((BOX_LOGS_KEPT + 1)) |
      while IFS= read -r old; do rm -f "$old"; done
  fi
  printf '%s' "$log"
}
_box_bridge() {
  local what="$1" sock="$2" hint="brew install socat"
  [[ ${BOX_CTR[0]} == podman ]] && hint="sudo pacman -S socat"
  command -v socat >/dev/null || {
    echo "error: $what needs socat ($hint)" >&2
    exit 1
  }
  if [[ ${BOX_CTR[0]} == podman ]]; then
    _box_free_port 127.0.0.1
    BOX_BRIDGE_PORT=$BOX_FREE_PORT
    socat "TCP-LISTEN:$BOX_BRIDGE_PORT,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$sock" 2> >(_box_socat_to) &
    # -9: SIGTERM makes socat log "exiting on signal 15" over the agent's last words
    _box_at_exit "kill -9 $! 2>/dev/null"
    BOX_PASTA_FWD+=("$BOX_BRIDGE_PORT")
  else
    _box_free_port "$(_box_gateway)"
    BOX_BRIDGE_PORT=$BOX_FREE_PORT
    BOX_MAC_FWD+=("$BOX_BRIDGE_PORT UNIX-CONNECT:$sock")
  fi
}

# ---------------------------------------------------------------- docker -----
box_docker_bridge() {
  # Expose the host's Docker to the box. A Unix socket can't be bind-mounted
  # into a VM, so on a Mac and under krun socat serves it on a TCP port (see
  # _box_bridge). Under podman's crun the socket mounts straight in.
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
    if ! _box_is_krun; then
      # The image's docker CLI already defaults to unix:///var/run/docker.sock.
      BOX_DOCKER_ENV+=(--volume "$sock:/var/run/docker.sock")
      echo "==> docker: $sock -> /var/run/docker.sock (this session only)" >&2
      return 0
    fi
  else
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
  fi

  local addr
  _box_bridge "${BOX_ENV_PREFIX}_DOCKER" "$sock"
  addr="$(_box_forward_addr)"
  BOX_DOCKER_ENV+=(--env "DOCKER_HOST=tcp://$addr:$BOX_BRIDGE_PORT")
  echo "==> docker: $sock -> tcp://$addr:$BOX_BRIDGE_PORT (this session only)" >&2
}

# ------------------------------------------------------------------ data -----
# Service data persists where the Dockerfile additions say VOLUME: a named
# volume is mounted there, one set per profile and project. The project is the
# git worktree (each worktree its own), or $PWD outside git;
# ${BOX_ENV_PREFIX}_PROJECT names it instead. Names read like
# agentbox-data-myapp-1234567890-var-lib-postgresql.
_box_data_prefix() {
  local proj dir
  proj="$(box_knob PROJECT)"
  if [[ -z $proj ]]; then
    dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
    proj="$(basename "$dir" | tr -c 'A-Za-z0-9_.\n-' '-')-$(printf '%s' "$dir" | cksum | cut -d' ' -f1)"
  fi
  printf 'agentbox-%s-%s-' "$(box_knob PROFILE default)" "$proj"
}

# A numeric label of the image, from either runtime; 0 when it has none.
_box_image_label() {
  local val
  if [[ ${BOX_CTR[0]} == podman ]]; then
    val="$(podman image inspect --format "{{index .Config.Labels \"$1\"}}" "$BOX_IMAGE")"
  else
    val="$(container image inspect "$BOX_IMAGE" |
      sed -n "s/.*\"$1\" *: *\"\([0-9]*\)\".*/\1/p" | head -1)"
  fi
  [[ $val =~ ^[0-9]+$ ]] || val=0
  printf '%s' "$val"
}

# The image's agent-box.entry label.
_box_entry_version() { _box_image_label agent-box.entry; }

# One box per volume set: two databases on one data dir corrupt it. A lock dir
# holding this script's PID; one left by a box that died is taken over.
_box_data_lock() {
  local dir="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/agentbox-locks/$1" pid
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    pid="$(cat "$dir/pid" 2>/dev/null || true)"
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      echo "error: another box (pid $pid) is using $1-* (same profile and project)" >&2
      exit 1
    fi
    rm -rf "$dir"
    mkdir "$dir" || {
      echo "error: could not lock $1-*" >&2
      exit 1
    }
  fi
  echo $$ >"$dir/pid"
  _box_at_exit "rm -rf '$dir'"
}

_box_data_volumes() {
  local prefix p name n=0 info
  [[ -n "$(_box_volume_paths)" ]] || return 0
  info="$(_box_entry_version)"
  [[ ${info:-0} -ge 5 ]] || {
    echo "error: $BOX_IMAGE predates the box-entry persisted data needs; rerun with --build-only" >&2
    exit 1
  }
  prefix="$(_box_data_prefix)"
  _box_data_lock "${prefix%-}"
  while IFS= read -r p; do
    name="$prefix$(printf '%s' "${p#/}" | tr -c 'A-Za-z0-9_.\n-' '-')"
    # podman creates a missing volume on first use; Apple's container doesn't.
    if [[ ${BOX_CTR[0]} == container ]] && ! container volume inspect "$name" >/dev/null 2>&1; then
      container volume create "$name" >/dev/null
    fi
    BOX_RUN_ARGS+=(--volume "$name:$p")
    n=$((n + 1))
  done < <(_box_volume_paths)
  echo "==> data: $n volume(s), ${prefix}*" >&2
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

# The repo's GitHub token, from the host keychain (`box-gh-token set`, which
# sits next to this lib). Nothing is written into the repo or ~/.box.*.
_box_gh_token() { "$BOX_LIB_DIR/box-gh-token" get; }

_box_gh_env() {
  # --gh: hand the box the repo's GitHub token. box-gh-token keys it by the main
  # worktree, so every worktree of the repo shares it. Exported rather than passed by value:
  # `--env NAME` inherits it, keeping the token out of the host's process list.
  # --gh=host: hand it the host's own `gh auth token` instead, for this run only.
  BOX_GH_ENV=()
  if [[ "$(box_knob GH)" == host ]]; then
    if GH_TOKEN=$(gh auth token 2>/dev/null) && [[ -n $GH_TOKEN ]]; then
      export GH_TOKEN
      BOX_GH_ENV=(--env GH_TOKEN)
      echo "==> gh: passing the host's own token (every repo it can reach)" >&2
      return 0
    fi
    echo "error: --gh=host: no gh token on the host (run \`gh auth login\`)" >&2
    exit 1
  fi
  [[ "$(box_knob GH)" == 1 ]] || return 0
  if GH_TOKEN=$(_box_gh_token) && [[ -n $GH_TOKEN ]]; then
    export GH_TOKEN
    BOX_GH_ENV=(--env GH_TOKEN)
    echo "==> gh: the repo's token" >&2
  else
    echo "error: --gh: no token passed" >&2
    exit 1
  fi
}

# _box_profile: read ~/.box.default.env if it exists, then the profile the
# script's flag set in *_BOX_PROFILE (which must exist) on top of it. Each is
# shell lines, e.g. `export SOME_VAR=SOME_VAL`; every variable goes into the box
# by name only, so the value stays out of the host's process list. They live
# outside BOX_HOME, which the box mounts read-write as /root: there the agent
# could read every profile and plant lines this host then evals.
#
# A profile can also bring a host side, e.g. a proxy holding a password the box
# shouldn't see, one per launch so no two boxes share it:
#   BOX_LAUNCH_PORT=VAR[,VAR...]  a line in the .env: each VAR gets a free host
#                  port, reserved for this launch, forwarded to this box alone
#                  and passed into it. Later lines can use $VAR.
#   ~/.box.NAME.up    runs in bash on the host before the box starts, with the
#                  profile's variables set; the launch stops if it fails.
#   ~/.box.NAME.down  runs when the launch exits, even if .up failed partway.
# Both get BOX_HOOK_DIR, a private directory for this launch (a generated
# config, a pid file), deleted after .down.
_box_profile_env() { printf '%s' "$HOME/.box.$1.env"; }
_box_profile_hook() { printf '%s' "$HOME/.box.$1.$2"; }

# _box_profile_exists NAME: any of a profile's files is there.
_box_profile_exists() {
  [[ -f "$(_box_profile_env "$1")" || -f "$(_box_profile_hook "$1" up)" ||
    -f "$(_box_profile_hook "$1" down)" ]]
}

_box_profile() {
  local name
  BOX_PROFILE_ENV=()
  _box_profile_legacy default
  [[ -f "$(_box_profile_env default)" ]] && _box_profile_load default
  _box_profile_hooks default
  name="$(box_knob PROFILE "")"
  [[ -n $name && $name != default ]] || return 0
  _box_profile_legacy "$name"
  _box_profile_exists "$name" || {
    echo "error: profile '$name' not found: $(_box_profile_env "$name")" >&2
    exit 1
  }
  [[ -f "$(_box_profile_env "$name")" ]] && _box_profile_load "$name"
  _box_profile_hooks "$name"
}

# _box_profile_hooks NAME: queue ~/.box.NAME.down for the exit, then run
# ~/.box.NAME.up. Their output goes to stderr, with the launch's own messages.
_box_profile_hooks() {
  local name="$1" up down dir
  up="$(_box_profile_hook "$name" up)"
  down="$(_box_profile_hook "$name" down)"
  [[ -f $up || -f $down ]] || return 0
  # macOS's TMPDIR ends in a slash
  dir="${TMPDIR:-/tmp}"
  dir="$(mktemp -d "${dir%/}/agent-box-hook.XXXXXX")"
  # Queued before .up runs, so a .up that fails halfway is still cleaned up
  # after; the dir first, as the exit runs them newest first and .down needs it.
  _box_at_exit "rm -rf '$dir'"
  if [[ -f $down ]]; then
    _box_at_exit "echo '==> profile $name: running $down' >&2; BOX_HOOK_DIR='$dir' bash '$down' >&2 || echo 'warning: profile $name: $down failed' >&2"
  fi
  [[ -f $up ]] || return 0
  echo "==> profile $name: running $up" >&2
  BOX_HOOK_DIR="$dir" bash "$up" >&2 || {
    echo "error: profile $name: $up failed" >&2
    exit 1
  }
}

# _box_launch_ports LIST: give each variable named in LIST (comma-separated) a
# free host port of its own, forwarded and passed into the box.
_box_launch_ports() {
  local name="$1" list="$2" var vars
  [[ -n $list ]] || {
    echo "error: profile $name: BOX_LAUNCH_PORT is empty; name a variable, e.g. BOX_LAUNCH_PORT=PGPORT" >&2
    exit 1
  }
  IFS=, read -ra vars <<<"$list"
  for var in ${vars[@]+"${vars[@]}"}; do
    [[ $var =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      echo "error: profile $name: BOX_LAUNCH_PORT '$list': not a variable name" >&2
      exit 1
    }
    _box_free_port 127.0.0.1
    export "$var=$BOX_FREE_PORT"
    _box_ports "$BOX_FREE_PORT"
    BOX_PROFILE_ENV+=(--env "$var")
    echo "==> profile $name: $var=$BOX_FREE_PORT, for this launch" >&2
  done
}

# Profiles used to sit in BOX_HOME. Refuse to run while one still does, so it
# doesn't stay readable (and writable) from inside the box.
_box_profile_legacy() {
  local old="$BOX_HOME/.env.$1"
  [[ -f $old ]] || return 0
  echo "error: profiles moved out of the box home; run" >&2
  echo "  mv '$old' '$(_box_profile_env "$1")'" >&2
  echo "(or delete it, if that file already has its contents)" >&2
  exit 1
}

_box_profile_load() {
  local name="$1" line n=0
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line#export }"
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
    if [[ ${BASH_REMATCH[1]} == BOX_LAUNCH_PORT ]]; then
      eval "$line"
      _box_launch_ports "$name" "$BOX_LAUNCH_PORT"
      unset BOX_LAUNCH_PORT
      continue
    fi
    # export, not just assign: --env NAME inherits from the environment, so a
    # bare shell variable would pass nothing.
    eval "export $line"
    BOX_PROFILE_ENV+=(--env "${BASH_REMATCH[1]}")
    n=$((n + 1))
  done <"$(_box_profile_env "$name")"
  echo "==> profile $name: $n var(s) passed" >&2
}

# podman only: box_runtime picks the OCI runtime for `run` (not for `build`,
# whose RUN steps don't need a VM each). krun sizes its VM from
# annotations rather than from --cpus/--memory, so pass those along too.
_box_runtime_args() {
  local rt mem
  rt="$(box_runtime)"
  [[ -n $rt ]] || return 0
  [[ ${BOX_CTR[0]} == podman ]] || {
    echo "==> ${BOX_ENV_PREFIX}_RUNTIME is podman-only; ignored here" >&2
    return 0
  }
  BOX_RUN_ARGS+=(--runtime "$rt")
  [[ $rt == krun ]] || return 0
  mem="$(box_knob MEMORY 4G)"
  case "$mem" in
  *[gG] | *[gG][bB]) mem=$((${mem%%[gG]*} * 1024)) ;;
  *[mM] | *[mM][bB]) mem=${mem%%[mM]*} ;;
  *)
    echo "error: ${BOX_ENV_PREFIX}_MEMORY=$mem: krun wants it in M or G" >&2
    exit 1
    ;;
  esac
  BOX_RUN_ARGS+=(--annotation "krun.cpus=$(box_knob CPUS 4)"
    --annotation "krun.ram_mib=$mem")
  echo "==> runtime: krun (${mem} MiB, $(box_knob CPUS 4) vCPUs)" >&2
}

# A linked worktree's (or submodule's) .git is a file pointing into the main
# repo's .git, outside $PWD, so git in the box can't find its objects. Mount
# that dir at its own path too. Read-write: commits, refs and the index live
# there.
#
# $PWD may also be a multi-repo workspace (each direct subdir a worktree), e.g.
# wt adds with -g; then every repo's .git is mounted, not just one.
_box_git_dir_volume() {
  local here d common c dirs=() commons=()
  here="$(pwd -P)"
  if git rev-parse --git-dir >/dev/null 2>&1; then
    dirs=("$here")
  else
    for d in "$here"/*/; do
      [[ -e "$d/.git" ]] && dirs+=("${d%/}")
    done
  fi
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  for d in "${dirs[@]}"; do
    common="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    [[ $common == "$here" || $common == "$here"/* ]] && continue
    for c in ${commons[@]+"${commons[@]}"}; do
      [[ $c == "$common" ]] && continue 2
    done
    commons+=("$common")
    BOX_RUN_ARGS+=(--volume "$common:$common")
    echo "==> git: $common (outside \$PWD)" >&2
  done
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
  # trailing '-' so GNU tr doesn't read "_.-\n" as a (reversed) range
  BOX_RUN_NAME="$BOX_NAME_PREFIX-$(basename "$PWD" | tr -c 'a-zA-Z0-9_.\n-' '-')-$$"
  BOX_RUN_ARGS=(
    -i --rm
    --name "$BOX_RUN_NAME"
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
  # A terminal only when there is one: `claude-box --shell -c ...` then also
  # works from a pipe or CI, where -t is refused.
  [[ -t 0 && -t 1 ]] && BOX_RUN_ARGS+=(-t)
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
  _box_git_dir_volume
  _box_runtime_args
  _box_host_port_args
  _box_data_volumes
  if [[ -n "$(box_knob SSH)" ]]; then
    if [[ ${BOX_CTR[0]} == podman ]]; then
      # podman has no --ssh; mount the agent socket at a fixed path instead.
      [[ -S "${SSH_AUTH_SOCK:-}" ]] || {
        echo "error: --ssh needs a running ssh-agent (SSH_AUTH_SOCK)" >&2
        exit 1
      }
      if _box_is_krun; then
        # Over a TCP port instead (_box_bridge); box-entry makes it a socket
        # again in /tmp.
        _box_bridge --ssh "$SSH_AUTH_SOCK"
        BOX_ENTRY=1
        BOX_RUN_ARGS+=(--env "BOX_SSH_AGENT_TCP=127.0.0.1:$BOX_BRIDGE_PORT"
          --env SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
        echo "==> ssh: agent -> tcp://127.0.0.1:$BOX_BRIDGE_PORT -> /tmp/ssh-agent.sock" >&2
      else
        BOX_RUN_ARGS+=(--volume "$SSH_AUTH_SOCK:/ssh-agent.sock"
          --env SSH_AUTH_SOCK=/ssh-agent.sock)
      fi
    else
      BOX_RUN_ARGS+=(--ssh)
    fi
  fi
  _box_forward_args
}

# Launch the image under whatever runtime the host has. Everything else about
# the invocation is host-independent, so the *-box scripts call this instead of
# naming the CLI.
#
# With --shell (BOX_SHELL=1) the same box starts bash instead of the agent, for
# poking at it by hand: bash goes in at the first argument naming $BOX_IMAGE,
# and whatever follows goes to it (`claude-box --shell -c 'uname -a'`). It
# still runs behind box-entry, so volumes, hooks and the ssh bridge are up; an
# image from before box-entry gets plain bash instead.
#
# BOX_ENTRY=1 (set by box_run_args for --ssh under krun) needs box-entry.
box_run() {
  [[ ${BOX_SHELL:-0} -eq 1 || ${BOX_ENTRY:-0} -eq 1 ]] || {
    "${BOX_CTR[@]}" run "$@"
    return
  }
  local args=() info
  while [[ $# -gt 0 && $1 != "$BOX_IMAGE" ]]; do
    args+=("$1")
    shift
  done
  info="$(_box_entry_version)"
  if [[ ${info:-0} -lt 2 && ${BOX_ENTRY:-0} -eq 1 ]]; then
    echo "error: $BOX_IMAGE predates box-entry, which --ssh under krun needs; rerun with --build-only" >&2
    exit 1
  fi
  [[ ${BOX_SHELL:-0} -eq 1 ]] || {
    "${BOX_CTR[@]}" run ${args[@]+"${args[@]}"} "$@"
    return
  }
  echo "==> --shell: bash instead of the agent" >&2
  if [[ ${info:-0} -ge 2 ]]; then
    "${BOX_CTR[@]}" run ${args[@]+"${args[@]}"} --entrypoint /usr/local/bin/box-entry "$1" bash "${@:2}"
  else
    echo "==> $BOX_IMAGE predates box-entry: no hooks (--rebuild to get them)" >&2
    "${BOX_CTR[@]}" run ${args[@]+"${args[@]}"} --entrypoint bash "$@"
  fi
}
