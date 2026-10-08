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
# The sourcing script sets these variables first:
#
#   BOX_IMAGE        image tag to build and run       (e.g. "claude-box")
#   BOX_NAME_PREFIX  prefix for container names       (e.g. "cl")
#   BOX_ENV_PREFIX   its user-facing env-knob prefix  (e.g. "CL_BOX")
#   BOX_HOME         host dir mounted as the box's /root
#   BOX_KEEP         paths under BOX_HOME that `--clean` preserves, relative
#                    (e.g. (.claude) — the logins and settings, not the runtimes)
#   BOX_CAN_SYNC     optional: 1 if the box adds --sync / --sync-only (default 0)
#
# BOX_ENV_PREFIX is how the shared knobs stay named after their own tool:
# everything below reads ${BOX_ENV_PREFIX}_DOCKER, _DOCKER_SOCK, _HOST_ALIAS,
# _HOST_ALIAS_IP, _SSH, _SEARCH, _CPUS, _MEMORY, _PROFILE and _RUNTIME, and names that same
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

# ----------------------------------------------------------------- flags -----
# Parses common flags shared by all boxes:
#   --rebuild, --build-only, --clean, --clean-all, --clean-data, --ssh, --docker, --search,
#   --profile[=NAME], --shell
# plus (--sync, --sync-only) when BOX_CAN_SYNC=1.
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
    --docker)
      printf -v "${BOX_ENV_PREFIX}_DOCKER" '%s' 1
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
}

# --------------------------------------------------------------- runtime -----
# podman's OCI runtime for `run`: krun (a microVM) unless ${BOX_ENV_PREFIX}_RUNTIME
# names another, e.g. crun for a plain container. On a Mac only what was set.
box_runtime() {
  if [[ ${BOX_CTR[0]} == podman ]]; then
    box_knob RUNTIME krun
  else
    box_knob RUNTIME
  fi
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
# back into the socket ssh expects. Fill any empty VOLUME from the copy taken at
# build time (podman fills a new volume itself; Apple's container doesn't, and
# hands over a fresh ext4 with only lost+found). A failing hook stops the box:
# an agent without the services it expects is worse than an error.
# Then run the hooks in /etc/box-entry.d (a profile's Dockerfile can start
# services there) and hand over. With hooks in
# /etc/box-exit.d it stays around instead, and runs them once the agent exits,
# so services stop cleanly before the box is torn down. The label tells the
# host which box-entry this image has.
RUN mkdir -p /etc/box-entry.d /etc/box-exit.d \
 && printf '%s\n' '#!/bin/sh' \
      'if [ -n "$BOX_SSH_AGENT_TCP" ]; then' \
      '  socat "UNIX-LISTEN:$SSH_AUTH_SOCK,fork,unlink-early,mode=600" "TCP:$BOX_SSH_AGENT_TCP" &' \
      '  i=0; while [ ! -S "$SSH_AUTH_SOCK" ] && [ $i -lt 50 ]; do sleep 0.05; i=$((i + 1)); done' \
      'fi' \
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
LABEL agent-box.entry=5

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
  fi
  return "$rc"
}

# True when the Dockerfile additions differ from what the image was built with.
_box_custom_changed() {
  local built
  built="$(cat "$(_box_custom_stamp)" 2>/dev/null || printf '' | cksum)"
  [[ "$(_box_dockerfile_custom | cksum)" != "$built" ]]
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
    return 0
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

# ------------------------------------------------------------ host alias -----
# The address the box reaches host loopback by. On podman (only bridged under
# krun) it is a link-local IP that pasta maps to the host's 127.0.0.1 (see
# _box_runtime_args); podman's own host.containers.internal won't do, as it
# lands on the host's LAN address. On a Mac it is a localhost DNS domain
# (box_ensure_host_alias).
BOX_PASTA_LOOPBACK=169.254.1.3
box_host_alias() {
  if [[ ${BOX_CTR[0]} == podman ]]; then
    printf '%s' "$BOX_PASTA_LOOPBACK"
  else
    box_knob HOST_ALIAS host.container.internal
  fi
}

box_ensure_host_alias() {
  # macOS-only: podman already resolves its alias to host loopback.
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
    # pfctl always warns about -f flushing the main ruleset (it doesn't: -a scopes the
    # load to the anchor) and about ALTQ. Drop that noise unless the load fails. Not -q:
    # the sudoers entry in tools/README.md matches these exact args.
    local out
    if ! out=$(sudo /sbin/pfctl -a com.apple/container -f "$anchor" 2>&1); then
      printf '%s\n' "$out" >&2
      return 1
    fi
    printf '%s\n' "$out" | grep -vE \
      -e '^pfctl: Use of -f option' -e '^present in the main ruleset' \
      -e '^See /etc/pf.conf' -e '^No ALTQ support' -e '^ALTQ related functions' \
      -e '^$' >&2 || true
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

# ------------------------------------------------------------------ exit -----
# Commands to run when the script exits (bridges, locks). One EXIT trap runs
# them all, so no caller's trap replaces another's.
BOX_AT_EXIT=()
_box_at_exit() {
  BOX_AT_EXIT+=("$1")
  trap '_box_run_at_exit' EXIT
}
_box_run_at_exit() {
  local c
  for c in ${BOX_AT_EXIT[@]+"${BOX_AT_EXIT[@]}"}; do
    eval "$c"
  done
}

# ---------------------------------------------------------------- bridge -----
# True when the box is a krun microVM, where a bind-mounted Unix socket is just
# a file to the guest kernel: connecting to it never reaches the host's listener.
_box_is_krun() {
  [[ ${BOX_CTR[0]} == podman && "$(box_runtime)" == krun ]]
}

# _box_bridge WHAT SOCK: serve the Unix socket SOCK on a free host-loopback port
# in BOX_BRIDGE_PORTS, for a VM that can't connect to it directly, and set
# BOX_BRIDGE_PORT. The listener lives as long as this script. Any local user can
# connect to 127.0.0.1, which is why the range is fixed and small: one nft rule
# can keep other users off it (tools/README.md). Keep the two in step. It sits
# below Linux's ephemeral ports (32768+), so no outgoing connection lands there.
BOX_BRIDGE_PORTS=(24100 100) # first port, count
_box_bridge() {
  local what="$1" sock="$2" hint="brew install socat" i p off=$RANDOM
  [[ ${BOX_CTR[0]} == podman ]] && hint="sudo pacman -S socat"
  command -v socat >/dev/null || {
    echo "error: $what needs socat ($hint)" >&2
    exit 1
  }
  # Start at a random offset so concurrent launches rarely race for one port;
  # a port is free when nothing answers on it.
  BOX_BRIDGE_PORT=
  for ((i = 0; i < BOX_BRIDGE_PORTS[1]; i++)); do
    p=$((BOX_BRIDGE_PORTS[0] + (off + i) % BOX_BRIDGE_PORTS[1]))
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && continue
    BOX_BRIDGE_PORT=$p
    break
  done
  [[ -n $BOX_BRIDGE_PORT ]] || {
    echo "error: $what: no free port in $BOX_BRIDGE_PORTS-$((BOX_BRIDGE_PORTS[0] + BOX_BRIDGE_PORTS[1] - 1))" >&2
    exit 1
  }
  socat "TCP-LISTEN:$BOX_BRIDGE_PORT,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$sock" &
  # -9: SIGTERM makes socat log "exiting on signal 15" over the agent's last words
  _box_at_exit "kill -9 $! 2>/dev/null"
}

# ---------------------------------------------------------------- docker -----
box_docker_bridge() {
  # Expose the host's Docker to the box. On a Mac, Unix sockets can't be
  # bind-mounted into the VM, and containers can't reach the Mac at the bridge
  # gateway IP by default. Apple's supported route is a "localhost" DNS domain:
  # it installs a pf rule that redirects a chosen IP to the Mac's loopback, so
  # we listen on 127.0.0.1 with socat and let the box connect by name. On Linux
  # podman's Docker-compatible socket mounts straight in, no socat, no sudo,
  # except under krun, whose VM gets the same socat bridge as the Mac.
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

  local alias
  alias="$(box_host_alias)"
  box_ensure_host_alias "$alias"
  _box_bridge "${BOX_ENV_PREFIX}_DOCKER" "$sock"
  BOX_DOCKER_ENV+=(--env "DOCKER_HOST=tcp://$alias:$BOX_BRIDGE_PORT")
  echo "==> docker: $sock -> tcp://$alias:$BOX_BRIDGE_PORT (this session only)" >&2
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

# The image's agent-box.entry label, from either runtime.
_box_entry_version() {
  if [[ ${BOX_CTR[0]} == podman ]]; then
    podman image inspect --format '{{index .Config.Labels "agent-box.entry"}}' "$BOX_IMAGE"
  else
    container image inspect "$BOX_IMAGE" |
      sed -n 's/.*"agent-box.entry" *: *"\([0-9]*\)".*/\1/p' | head -1
  fi
}

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
    echo "error: $BOX_IMAGE predates the box-entry persisted data needs; rerun with --rebuild" >&2
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

# _box_profile: read ~/.box.default.env if it exists, then the profile the
# script's flag set in *_BOX_PROFILE (which must exist) on top of it. Each is
# shell lines, e.g. `export SOME_VAR=SOME_VAL`; every variable goes into the box
# by name only, so the value stays out of the host's process list. They live
# outside BOX_HOME, which the box mounts read-write as /root: there the agent
# could read every profile and plant lines this host then evals.
_box_profile_env() { printf '%s' "$HOME/.box.$1.env"; }

_box_profile() {
  local name
  BOX_PROFILE_ENV=()
  _box_profile_legacy default
  [[ -f "$(_box_profile_env default)" ]] && _box_profile_load default
  name="$(box_knob PROFILE "")"
  [[ -n $name && $name != default ]] || return 0
  _box_profile_legacy "$name"
  [[ -f "$(_box_profile_env "$name")" ]] || {
    echo "error: profile '$name' not found: $(_box_profile_env "$name")" >&2
    exit 1
  }
  _box_profile_load "$name"
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
  # The ssh/docker bridges listen on host loopback. Map it in only when one is
  # on: the guest then reaches every host 127.0.0.1 port, not just theirs.
  if [[ -n "$(box_knob SSH)" || "$(box_knob DOCKER 0)" == 1 ]]; then
    BOX_RUN_ARGS+=(--network "pasta:--map-host-loopback,$BOX_PASTA_LOOPBACK")
  fi
  echo "==> runtime: krun (${mem} MiB, $(box_knob CPUS 4) vCPUs)" >&2
}

# A linked worktree's (or submodule's) .git is a file pointing into the main
# repo's .git, outside $PWD, so git in the box can't find its objects. Mount
# that dir at its own path too. Read-write: commits, refs and the index live
# there.
_box_git_dir_volume() {
  local common here
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  here="$(pwd -P)"
  [[ $common == "$here" || $common == "$here"/* ]] && return 0
  BOX_RUN_ARGS+=(--volume "$common:$common")
  echo "==> git: $common (outside \$PWD)" >&2
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
    -i --rm
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
  _box_data_volumes
  if [[ -n "$(box_knob SSH)" ]]; then
    if [[ ${BOX_CTR[0]} == podman ]]; then
      # podman has no --ssh; mount the agent socket at a fixed path instead.
      [[ -S "${SSH_AUTH_SOCK:-}" ]] || {
        echo "error: --ssh needs a running ssh-agent (SSH_AUTH_SOCK)" >&2
        exit 1
      }
      if _box_is_krun; then
        # Over host loopback instead; box-entry makes it a socket again in /tmp.
        _box_bridge --ssh "$SSH_AUTH_SOCK"
        BOX_ENTRY=1
        BOX_RUN_ARGS+=(--env "BOX_SSH_AGENT_TCP=$(box_host_alias):$BOX_BRIDGE_PORT"
          --env SSH_AUTH_SOCK=/tmp/ssh-agent.sock)
        echo "==> ssh: agent -> tcp://$(box_host_alias):$BOX_BRIDGE_PORT -> /tmp/ssh-agent.sock" >&2
      else
        BOX_RUN_ARGS+=(--volume "$SSH_AUTH_SOCK:/ssh-agent.sock"
          --env SSH_AUTH_SOCK=/ssh-agent.sock)
      fi
    else
      BOX_RUN_ARGS+=(--ssh)
    fi
  fi
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
    echo "error: $BOX_IMAGE predates box-entry, which --ssh under krun needs; rerun with --rebuild" >&2
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
