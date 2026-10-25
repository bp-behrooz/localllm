#!/bin/bash
# llama-server from the ggml-org ROCm image, as the pool's LLAMA_BIN:
#   serve-llama.sh <llama-server args...>
# The pool sets HIP_VISIBLE_DEVICES, NAME and PORT, and stops the container by
# NAME. Models live in (and -hf downloads to) the same HF cache `setup.sh
# download` fills, so a preset is fetched once whichever way.
set -euo pipefail
: "${NAME:?}" "${HIP_VISIBLE_DEVICES:?}" "${PORT:?}"
# llama-server binds its port at once, but an engine evicted from it just now
# (radiance unpinning its host pool) can hold it, and its VRAM, for seconds
# after podman stop returns: wait for it to go, up to 2 minutes
for _ in $(seq 240); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || break
  sleep 0.5
done
HUB=/opt/localllm/.cache/huggingface/hub
# pinned by digest (b11870): bump it for newer model architectures
IMAGE=${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp@sha256:bfb6ee07f3100d337752cdb6ff634f9cc666c90a6dfdb1739f65284687c8117c}
mkdir -p "$HUB"
podman image exists "$IMAGE" 2>/dev/null || podman pull "$IMAGE"
exec podman run --rm --replace --name "$NAME" \
  --network host \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1 \
  --init --no-healthcheck \
  -v "$HUB":/hub \
  -e HF_HUB_CACHE=/hub -e HF_TOKEN -e HIP_VISIBLE_DEVICES \
  "$IMAGE" "$@"
