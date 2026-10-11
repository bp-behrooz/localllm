#!/bin/bash
# cmd presets on the radiance engine (the stilldeadcode/radiance image):
#   MAXLEN=<ctx> serve-radiance.sh <model.rad> [engine flags...]
# serves /opt/localllm/models/<model.rad> on the GPUs the pool assigned.
# The pool sets PORT, GPUS (HIP indices) and NAME, and stops the container
# by NAME; MAXLEN is the context, also what the pool advertises. One-time, as
# localllm: podman pull stilldeadcode/radiance; ./setup.sh download fetches the .rad.
set -euo pipefail
: "${PORT:?}" "${NAME:?}" "${GPUS:?}" "${MAXLEN:?}" "${1:?usage: $0 <model.rad> [flags...]}"
model=$1
shift
MODEL_DIR=/opt/localllm/models
STATE_DIR=/opt/localllm/radiance-state
IMAGE=${RADIANCE_IMAGE:-stilldeadcode/radiance}
[ -f "$MODEL_DIR/$model" ] || {
  echo "missing $MODEL_DIR/$model; fetch it with: sudo ./setup.sh download <this preset>" >&2
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
  --model "/models/$model" \
  -e HIP_VISIBLE_DEVICES="$GPUS" \
  --host :: --port "$PORT" --tp "$tp" --max-model-len "$MAXLEN" "$@"
