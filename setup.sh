#!/usr/bin/env bash
# Usage: ./setup.sh                     install/apply config; all presets served on demand
#        ./setup.sh download [preset]…  pre-fetch models (all of them if none named;
#                                       else the pool downloads on first request, slower)
#        ./setup.sh remove <preset>     delete a preset's downloaded files
# First run ever: HF_TOKEN=hf_xxx ./setup.sh   (token is stored, not needed again)
# Requires pool.py next to this script.
set -euo pipefail

# HIP device indices of the two R9700s — verify with `llama-server --list-devices`
GPUS=(0 1)

# name -> "gpus|model|extra llama-server args"
#   gpus: how many GPUs the model needs. 1 = pool places it on whichever is
#   free; 2 = spans both (pool evicts everything else first)
declare -A PRESET=(
  [thinkingcap]="1|bottlecapai/ThinkingCap-Qwen3.6-27B-GGUF:Q4_K_M|--spec-type draft-mtp --spec-draft-n-max 4 -c 262144 -ctk q8_0 -ctv q8_0 --temp 1.0 --top-p 0.95 --top-k 20"
  [qwen3.8]="1|unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL|--spec-type draft-mtp --spec-draft-n-max 4 -c 262144 -ctk q8_0 -ctv q8_0 --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0"
  [qwen3.8-fast]="1|ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF:IQ3_S-mtp|--spec-type draft-mtp --spec-draft-n-max 4 -c 262144 -ctk q8_0 -ctv q8_0 --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0"
  [tiel-coder]="1|peculiar-ragdoll/Tiel-Coder-35B-A3B-GGUF-MTP:UD-Q4_K_XL|--spec-type draft-mtp --spec-draft-n-max 4 -c 131072 -ctk q8_0 -ctv q8_0 --temp 0.6 --top-p 0.95 --top-k 20"
  [qwen3-coder]="1|unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:UD-Q4_K_XL|-c 262144 -ctk q8_0 -ctv q8_0 --temp 0.7 --top-p 0.8 --top-k 20 --repeat-penalty 1.05"
  [gpt-oss-20b]="1|ggml-org/gpt-oss-20b-GGUF|-c 131072 --temp 1.0 --top-p 1.0"
  [muse-glimmer]="1|unsloth/Muse-Glimmer-30B-GGUF:UD-Q4_K_XL|-c 131072 -ctk q8_0 -ctv q8_0 --temp 1.0 --top-p 0.95 --top-k 64"
  [gpt-oss-120b]="2|ggml-org/gpt-oss-120b-GGUF|-c 131072 --temp 1.0 --top-p 1.0"
)

usage() {
  echo "usage: $0                     apply config (all presets served on demand)"
  echo "       $0 download [preset]…  pre-fetch model files (no preset: all of them)"
  echo "       $0 remove <preset>     delete a preset's downloaded files"
  echo "presets: ${!PRESET[*]}"
  exit 1
}

hf_fetch() { # <preset>
  IFS='|' read -r _ m _ <<<"${PRESET[$1]}"
  local repo="${m%%:*}" tag="${m#*:}" inc=()
  # multimodal repos keep the vision tower in a separate mmproj gguf the tag filter would miss
  [[ "$tag" != "$m" ]] && inc=(--include "*${tag}*" --include "*mmproj*")
  sudo -u localllm env HF_TOKEN="${HF_TOKEN}" HF_XET_HIGH_PERFORMANCE=1 \
    HF_HUB_CACHE=/opt/localllm/.cache/huggingface/hub \
    /opt/localllm/venv/bin/hf download "$repo" "${inc[@]}"
}

case "${1:-apply}" in
apply) [[ $# -eq 0 ]] || usage ;;
download)
  shift
  [[ $# -ge 1 ]] || set -- "${!PRESET[@]}"   # no presets named: download them all
  for p in "$@"; do [[ -n "${PRESET[$p]:-}" ]] || { echo "unknown preset: $p"; usage; }; done
  source /opt/localllm/env
  for p in "$@"; do hf_fetch "$p"; done
  exit 0
  ;;
remove)
  [[ $# -eq 2 && -n "${PRESET[$2]:-}" ]] || usage
  IFS='|' read -r _ m _ <<<"${PRESET[$2]}"
  repo="${m%%:*}" tag="${m#*:}"
  dir="/opt/localllm/.cache/huggingface/hub/models--${repo//\//--}"
  if [[ "$tag" == "$m" ]]; then
    rm -rf "$dir"   # untagged preset owns the whole repo
  else
    # tagged: delete only this quant's files (blob + symlink); other presets
    # sharing the repo (and the mmproj) stay intact
    for f in "$dir"/snapshots/*/*"$tag"*; do
      [[ -e "$f" ]] || continue
      rm -f "$(realpath "$f")" "$f"
    done
  fi
  du -sh "$dir" 2>/dev/null || echo "repo fully removed"
  exit 0
  ;;
*) usage ;;
esac

LLAMA_BIN="$(command -v llama-server)"
[[ -f "$(dirname "$0")/pool.py" ]] || { echo "pool.py not found next to $0"; exit 1; }

# ---------- one-time provisioning (idempotent, skipped when done) ----------
id localllm &>/dev/null || useradd -r -m -d /opt/localllm -s "$(command -v nologin)" localllm
usermod -aG render,video localllm
[[ -x /opt/localllm/venv/bin/uvicorn ]] || {
  [[ -d /opt/localllm/venv ]] || python3 -m venv /opt/localllm/venv
  /opt/localllm/venv/bin/pip install -q --upgrade pip fastapi uvicorn httpx
}
[[ -x /opt/localllm/venv/bin/hf ]] \
  || /opt/localllm/venv/bin/pip install -q 'huggingface_hub[hf_xet]'
touch /opt/localllm/env
grep -q '^MASTER_KEY=' /opt/localllm/env \
  || echo "MASTER_KEY=sk-$(openssl rand -hex 16)" >>/opt/localllm/env
grep -q '^HF_TOKEN=' /opt/localllm/env \
  || echo "HF_TOKEN=${HF_TOKEN:?no HF_TOKEN stored yet - run as HF_TOKEN=hf_xxx $0}" >>/opt/localllm/env
chmod 600 /opt/localllm/env

# ---------- pool config: every preset, placed on demand ----------
{
  echo '{'
  echo "  \"llama_bin\": \"${LLAMA_BIN}\","
  echo "  \"gpus\": [$(IFS=,; echo "${GPUS[*]}")],"
  echo '  "presets": {'
  sep=""
  for name in "${!PRESET[@]}"; do
    IFS='|' read -r ngpus model args <<<"${PRESET[$name]}"
    [[ "$ngpus" =~ ^[12]$ ]] || { echo "preset $name: bad gpu count '$ngpus'"; exit 1; }
    printf '%s    "%s": {"hf": "%s", "gpus": %d, "args": "%s"}' \
      "$sep" "$name" "$model" "$ngpus" "$args"
    sep=$',\n'
  done
  printf '\n  }\n}\n'
} >/opt/localllm/pool.json
install -m 644 "$(dirname "$0")/pool.py" /opt/localllm/pool.py

chown -R localllm:localllm /opt/localllm
chmod 600 /opt/localllm/env

# ---------- systemd units ----------
systemctl stop localllm 2>/dev/null || true

cat >/etc/systemd/system/localllm.service <<'EOF'
[Unit]
Description=localllm GPU pool server

[Service]
User=localllm
EnvironmentFile=/opt/localllm/env
WorkingDirectory=/opt/localllm
ExecStart=/opt/localllm/venv/bin/python /opt/localllm/pool.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now localllm

echo
echo "Pool up. All presets are live model names on :4000; first request to a"
echo "preset loads it (downloads it too, if you skipped '$0 download <preset>')."
grep '^MASTER_KEY=' /opt/localllm/env
echo "Loaded models: curl -s localhost:4000/health | python3 -m json.tool"
