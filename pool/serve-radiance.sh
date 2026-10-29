#!/bin/bash
# cmd presets on the radiance engine (the stilldeadcode/radiance image):
#   MAXLEN=<ctx> serve-radiance.sh <model.rad> [engine flags...]
# serves /opt/localllm/models/<model.rad> on the GPUs the pool assigned.
# The pool sets PORT, GPUS (HIP indices) and NAME, and stops the container
# by NAME; MAXLEN is the context, also what the pool advertises. One-time, as
# localllm: ./setup.sh download fetches the .rad; the pinned image (IMAGE
# below) is pulled on first start if missing.
set -euo pipefail
: "${PORT:?}" "${NAME:?}" "${GPUS:?}" "${MAXLEN:?}" "${1:?usage: $0 <model.rad> [flags...]}"
model=$1
shift
MODEL_DIR=/opt/localllm/models
# pinned by digest (1.14.0): presets pass engine flags that releases rename
# or drop, so bump this together with them
IMAGE=${RADIANCE_IMAGE:-docker.io/stilldeadcode/radiance@sha256:69add58f7de1ed2bca2b1e20a4cc75717557df3f73569a178eca5aafe8c44093}
[ -f "$MODEL_DIR/$model" ] || {
  echo "missing $MODEL_DIR/$model; fetch it with: sudo ./setup.sh download <this preset>" >&2
  exit 1
}
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
  -e HIP_VISIBLE_DEVICES="$GPUS" \
  "$IMAGE" \
  --model "/models/$model" \
  --host :: --port "$PORT" --tp "$tp" --max-model-len "$MAXLEN" "$@"
