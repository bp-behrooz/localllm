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
PLUGIN_DIR=/opt/localllm/plugins
# pinned by digest (2.0.0): presets pass engine flags that releases rename
# or drop, so bump this together with them
IMAGE=${RADIANCE_IMAGE:-docker.io/stilldeadcode/radiance@sha256:9ec1b8bf9011ebe219f4acbcef0e47d3a35c76067248219dd3965334ee63c0fb}
[ -f "$MODEL_DIR/$model" ] || {
  echo "missing $MODEL_DIR/$model; fetch it with: sudo ./setup.sh download <this preset>" >&2
  exit 1
}
podman image exists "$IMAGE" 2>/dev/null || podman pull "$IMAGE"
tp=$(tr ',' '\n' <<<"$GPUS" | wc -l)
plugins=()
[ -d "$PLUGIN_DIR" ] && plugins=(
  -v "$PLUGIN_DIR":/plugins:ro
  -e RADIANCE_HOME=/plugins:/opt/radiance/share/radiance
)
# NAME is pool-<preset>-<port>; radiance 2.0 routes requests by the YAML model
# key, and pool.py forwards the client's `"model": "<preset>"` untouched
preset=${NAME#pool-}; preset=${preset%-"$PORT"}
exec podman run --replace --name "$NAME" \
  --network host \
  --device /dev/kfd --device /dev/dri \
  --group-add keep-groups \
  --security-opt seccomp=unconfined \
  --ulimit memlock=-1 \
  --init \
  -v "$MODEL_DIR":/models:ro \
  "${plugins[@]}" \
  -e HIP_VISIBLE_DEVICES="$GPUS" \
  --entrypoint sh "$IMAGE" -ec \
  'rad-yaml "$@" >/tmp/radiance.yaml && exec radiance --config /tmp/radiance.yaml' -- \
  --served-model-name "$preset" \
  --model "/models/$model" \
  --host :: --port "$PORT" --tp "$tp" --max-model-len "$MAXLEN" "$@"
