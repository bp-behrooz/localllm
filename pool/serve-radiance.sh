#!/bin/bash
# The qwen3.8-radiance preset: serve Qwen3.8-27B MXFP4 with the radiance
# engine (the stilldeadcode/radiance image) on the GPUs the pool assigned.
# The pool sets PORT, GPUS (HIP indices) and NAME, and stops the container
# by NAME. One-time, as localllm: podman pull stilldeadcode/radiance and
# curl -LC - -o /opt/localllm/models/qwen3.8-27b-mxfp4.rad
#   https://huggingface.co/StillDeadcode/qwen3.8-27b-mxfp4/resolve/main/qwen3.8-27b-mxfp4.rad
set -euo pipefail
: "${PORT:?}" "${NAME:?}" "${GPUS:?}"
MODEL_DIR=/opt/localllm/models
STATE_DIR=/opt/localllm/radiance-state
IMAGE=${RADIANCE_IMAGE:-stilldeadcode/radiance}
[ -f "$MODEL_DIR/qwen3.8-27b-mxfp4.rad" ] || {
  echo "missing $MODEL_DIR/qwen3.8-27b-mxfp4.rad; fetch it first (resumable):" >&2
  echo "  curl -LC - -o $MODEL_DIR/qwen3.8-27b-mxfp4.rad https://huggingface.co/StillDeadcode/qwen3.8-27b-mxfp4/resolve/main/qwen3.8-27b-mxfp4.rad" >&2
  exit 1
}
mkdir -p "$STATE_DIR"
podman image exists "$IMAGE" 2>/dev/null || podman pull "$IMAGE"
tp=$(tr ',' '\n' <<<"$GPUS" | wc -l)
exec podman run --replace --name "$NAME" \
  --network host \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1 \
  --init \
  -v "$MODEL_DIR":/models:ro \
  -v "$STATE_DIR":/data \
  "$IMAGE" \
  --model /models/qwen3.8-27b-mxfp4.rad \
  --host :: --port "$PORT" \
  --tp "$tp" --max-num-seqs 32 --max-model-len 262144 --kv-cache-dtype fp8
