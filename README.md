# localllm

On-demand LLM serving for a dual-GPU box (2× AMD R9700, ROCm). Every
configured model is always addressable through one OpenAI-compatible
endpoint; a small scheduler loads models onto GPUs as they're requested and
LRU-evicts idle ones when space runs out.

```
client → Caddy (TLS, public) → pool.py :4000 (auth + scheduler) → llama-server (per model/GPU)
```

## Pieces

| File | Role |
|---|---|
| `setup.sh` | installs everything, generates all config; the preset table inside it is the single source of truth |
| `pool/pool.py` | the server: key auth, GPU scheduling (spawn/evict `llama-server` instances), request proxying |
| [`tools/`](tools/README.md) | the agent boxes: pi / OpenCode / Open Code Review against this server, plus Claude Code and Antigravity CLI (unrelated — they talk to Anthropic / Google as usual). Persistence, mise and customization documented there |
| `pool/test.sh` | self-test: bootstraps a local `.venv`, runs `pool.py --test` and `setup-test.sh` (no GPUs needed) |

## Requirements

- Linux with systemd (developed on Arch), two GPUs visible to ROCm
- `podman` and `crun`: `llama-server` runs from ggml-org's ROCm image
  (`ghcr.io/ggml-org/llama.cpp`, server-rocm), pinned by digest in
  `pool/serve-llama.sh` and pulled on first use (~7 GiB). No host ROCm or
  llama.cpp needed; bump the pin for newer model architectures
- `python3`; everything else installs into `/opt/localllm/venv`
- A HuggingFace read token for gated model repos

## Install

On the GPU box, as root:

```bash
HF_TOKEN=hf_xxx ./setup.sh    # token is stored in /opt/localllm/env; only needed once
./setup.sh download           # pre-fetch all preset models (or name specific ones)
```

The first run prints an API key, named after you (whoever ran `sudo`), that
clients send as a Bearer token (`Authorization: Bearer sk-xxx`), or, for
clients that can only send a bare key in a header of their choosing, as
`x-litellm-api-key: sk-xxx`.
`systemctl start|stop localllm` controls the whole stack. Optional env vars in
`/opt/localllm/env`: `POWER_CAP_W` (per-GPU watts, one of the powerbench-tested
300/270/240/210; written to the GPUs' `power1_cap` sysfs at startup — the
unit needs write access to that file, i.e. root or a group-writable file),
`IDLE_TTL` / `IDLE_TTL_CMD` / `REAP_INTERVAL` (seconds; override `pool.json`).

### API keys

Any number of keys can be active at once, one per person or client:

```bash
./setup.sh key add alice      # prints alice's key, once
./setup.sh key list           # names only
./setup.sh key rm alice       # revoked within 5 minutes
```

They live in `/opt/localllm/keys` as `name sha256` lines; only hashes, so a key
can't be read back, only reissued. The pool checks the file every 5 minutes
(`KEYS_RECHECK` in `/opt/localllm/env`, in seconds), so none of this needs a
restart, and a change takes up to that long to apply. To rotate a key: add a
new one, move the clients over, then remove the old one.

## Presets

Models are defined in the `PRESET` table at the top of `setup.sh`:

```
[name]="gpus|hf-repo:quant-tag|extra llama-server args"
```

- `gpus`: `1` = fits one GPU (the pool places it on whichever is free, and
  may run two load-balanced instances); `2` = spans both GPUs (the pool
  evicts everything else first).
- Sampling flags (`--temp`, `--top-p`, …) become server-side defaults — use
  each model card's recommended values; clients that send their own override
  per request.
- `-c` (context size) is also published through the server's `/model/info` so
  clients can discover each model's window.

Two extras:

- **Custom engines**: `[name]="gpus|cmd|<command>"` runs an arbitrary serving
  command instead of `llama-server`. The pool executes it via `bash -c` with
  `PORT`, `GPUS` (HIP indices) and `NAME` (a unique instance name) in the
  environment; it must serve `/health` and OpenAI-style `/v1` on `PORT`, under
  the preset's name. `download`/`remove` fetch and delete a radiance preset's
  `.rad`. Advertise the
  context window with a `MAXLEN=<n>` in the command so `/model/info` picks it up.
- **Preload**: preset names in `PRELOAD` (space-separated) are loaded when the
  pool starts, so the default model answers without a cold start. Preloaded
  models are still evictable like everything else.

After editing presets, re-run `sudo ./setup.sh` to apply. Other subcommands:

```bash
./setup.sh download [preset]…   # pre-fetch (all presets if none named)
./setup.sh remove <preset>      # delete a preset's downloaded files
```

## Scheduling behavior

- First request to a model loads it (a few seconds on fast NVMe; much longer
  if it must download — pre-download to avoid that) and the request then
  completes normally.
- A 1-GPU model requested while the whole pool is free starts as **two
  load-balanced instances**; requests go to the instance with the fewest
  in-flight requests.
- When a model is requested and no GPU is free, the **least-recently-used
  idle** instance is evicted; duplicate instances are sacrificed before any
  model's last instance.
- A saturated model **scales out** onto a free GPU, or onto one whose model
  has been idle 10+ minutes (`IDLE_SCALE_EVICT` in `pool/pool.py`).
- Instances with requests in flight are never evicted; if nothing can be
  evicted the request gets a 503.

Inspect the pool: `curl -s localhost:4000/health | python3 -m json.tool`
(`/health` is the one endpoint that doesn't require the key; it reveals only
which models are loaded).

Self-test (no GPUs needed): `./pool/test.sh` — bootstraps a local `.venv` with
the dependencies (and, with mise, the python pinned in `mise.toml`), runs
`pool/pool.py --test` and `setup-test.sh` (the radiance preset detection).

## Remote access via Caddy

The server listens on `0.0.0.0:4000` (open the port for your LAN, e.g.
`ufw allow from 192.168.2.0/24 to any port 4000 proto tcp`). To reach it from
outside, let a Caddy that can reach the box terminate TLS. Auth is the key
enforced by the server itself, so Caddy just proxies — allowlisting the
API paths keeps everything else (like the unauthenticated `/health`) off the
internet:

```caddyfile
example.com {
    handle_path /localllm/* {
        @api path /v1/* /model/info /model_group/info
        handle @api {
            reverse_proxy gpu-box:4000
        }
        respond 404
    }

    # ... your existing site config ...
}
```

Clients then use base URL `https://example.com/localllm/v1` with their key as
API key.

## nanbeige4.3

Nanbeige4.3-33B (a plain Llama-shaped dense model) as bartowski's Q5_K_M
GGUF on llama-server, split across both GPUs with `-sm tensor`, at 256K
context with a q8_0 KV cache: about 32 tok/s. Sized for 2× 32 GB: ~23 GiB
of weights plus ~28 GiB of KV at 256K (about 110 KiB a token). Q6_K_L fits
at `-c 196608`; `-c 524288`, the model's maximum, doesn't fit at all.

It runs without ProCreations' DFlash2 drafter. Converted to a GGUF, the
drafter crashes llama.cpp under `-sm tensor`
([#28777](https://github.com/ggml-org/llama.cpp/issues/28777),
[#27833](https://github.com/ggml-org/llama.cpp/issues/27833)), and under
`-sm layer` it accepted 11% of its drafts, for 19 tok/s.

## The radiance presets

Four presets run on the
[radiance](https://codeberg.org/StillDeadcode/radiance) engine — C++/HIP with
RDNA4 kernels and speculative decoding — each across both GPUs:

- `qwen3.8-flash-next` (preloaded): Qwen3.8-Flash-Next, an MoE with an int8
  trunk and 4-bit experts, 256K context. The experts that don't fit VRAM
  stream from a pinned host pool (12 GiB per GPU, so 24 GiB of RAM), and idle
  sessions move to RAM (up to 4 GiB). Sized for 2× 32 GB cards, 96 GB of RAM
  and the 114 GiB model on the `/opt` disk.
- `qwen3.8-radiance`: Qwen3.8-27B in Qwen's own FP8 (128×128 blocks) with
  its DFlash2 drafter, 256K context.
- `gemma4-heretic`: Gemma 4 31B heretic-ara (refusals removed) with a GPTQ
  int4 trunk, int8 activations and MTP, 64K context at 8 sequences
  (upstream's flags; 256K fits at `--max-num-seqs 2`).
- `thinkingcap`: ThinkingCap-Qwen3.8-27B (a Qwen3.8-27B finetune that
  reasons in fewer tokens) as block FP8 with Qwen3.8's DFlash2 drafter, the
  same form and speed as `qwen3.8-radiance`. Nobody publishes this `.rad`, so
  it's converted locally (below).

A preset whose `.rad` isn't in a `StillDeadcode/<name>` repo names its repo
with `RAD_REPO=<owner/repo>` in the cmd, as `gemma4-heretic` does;
`RAD_REPO=-` marks one converted locally, which `download` skips.

To convert `thinkingcap` (accept the gated repo's terms on Hugging Face with
your token's account first; needs ~85 GiB free while it runs, CPU only, the
DFlash2 recipe from the pinned image):

```bash
cd /opt/localllm && source /opt/localllm/env      # for HF_TOKEN
SRC=/opt/localllm/hf-src; install -d -o localllm -g localllm $SRC
for r in bottlecapai/ThinkingCap-Qwen3.8-27B z-lab/Qwen3.8-27B-DFlash2; do
  sudo -u localllm env HF_TOKEN="$HF_TOKEN" HF_XET_HIGH_PERFORMANCE=1 \
    /opt/localllm/venv/bin/hf download "$r" --local-dir "$SRC/$r"
done
sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman run --rm --log-driver k8s-file \
    -v $SRC:/src:ro -v /opt/localllm/models:/models --entrypoint rad-convert \
    docker.io/stilldeadcode/radiance@sha256:e82764045e46ebae07e33961f17dedba981c0d07336dfcddd67e4b3b042b8600 \
    /src/bottlecapai/ThinkingCap-Qwen3.8-27B --draft-model /src/z-lab/Qwen3.8-27B-DFlash2 \
    --recipe /opt/radiance/share/radiance/recipes/q38-27b-fp8block-df2.recipe \
    --set quantization_config.quant_method=fp8 --set quantization_config.fmt=e4m3 \
    --set "quantization_config.weight_block_size=128 128" \
    --set quantization_config.activation_scheme=dynamic \
    -o /models/thinkingcap-qwen3.8-27b-fp8-df2.rad
rm -rf $SRC   # once the .rad serves well
```

They're `cmd` presets: `setup.sh` installs their launcher
(`/opt/localllm/serve-radiance.sh <model.rad> [engine flags]`), and the image
and models are a one-time manual install, as the `localllm` user, under its
home. It runs on rootless podman: no daemon, no root-equivalent `docker`
group, and the models and caches stay `localllm`-owned. `setup.sh` gives
`localllm` a subuid range and a lingering user manager, so run it first:

```bash
sudo pacman -S podman crun
sudo ./setup.sh
cd /opt/localllm   # podman must start in a dir localllm can enter
sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman pull docker.io/stilldeadcode/radiance@sha256:e82764045e46ebae07e33961f17dedba981c0d07336dfcddd67e4b3b042b8600
sudo ./setup.sh download qwen3.8-flash-next qwen3.8-radiance gemma4-heretic   # 114 + 29 + 20 GiB
sudo systemctl restart localllm
```

The radiance image is pinned by digest in `serve-radiance.sh` (currently 1.12.0), since
radiance releases rename and drop engine flags; upgrade by changing that pin
and the presets' flags together. Its ROCm 10.1 userspace needs an amdgpu
driver of interface 3.64 or later (Linux 6.16+): on an older kernel it starts,
but without GPU virtual memory, so Flash-Next's KV cache can't lend VRAM to
the experts. Skip a model you don't want, and delete its
preset from the table (and `PRELOAD`). Coming from
the old docker setup: after the steps above (which also drop `localllm` from
the `docker` group and re-own the root-owned caches), free the old image with
`sudo docker system prune -a`, and if nothing else on the box needs it,
`sudo systemctl disable --now docker.socket docker.service` and
`sudo pacman -Rns docker`. Cold start is
slower than a llama-server preset — engine init plus loading the model,
several minutes for Flash-Next.

All logs, the pool's and every engine's, are in `journalctl -u localllm -f`.
`setup.sh` sets `localllm`'s podman to the `passthrough` log driver, so a
container writes straight to the pool's stdout, and turns off per-container
cgroups, so it stays in `localllm.service` (journald files lines by the
writer's cgroup). That also makes `systemctl stop localllm` stop the
containers with it. The costs: `podman logs` shows nothing (despite what
radiance prints), `podman run -d` as `localllm` needs `--log-driver k8s-file`,
and there are no per-container limits or `podman stats`.

## Agents (pi / OpenCode / OCR)

`tools/pi-box`, `tools/opencode-box` and `tools/ocr-box` run the respective
agent in a sandboxed Apple `container` VM (Apple Silicon, macOS 26). All three
take the server's base URL and key from the same two environment variables:

```bash
export LOCAL_LLM_URL=https://example.com/localllm/v1
export LOCAL_LLM_API_KEY=sk-xxx
./tools/pi-box          # or: ./tools/opencode-box
./tools/ocr-box review  # or: ocr-box scan — Open Code Review, one model per run
```

On first launch (or with `--sync`) all three query the server and write the
served models into the box's own config under `~/.pi-box` / `~/.opencode-box` /
`~/.ocr-box` — re-run with `--sync` after preset changes. pi-box and
opencode-box record context limits too; ocr-box writes a `localllm` provider
that `ocr` prefers over any environment, reviewing with `OCR_BOX_MODEL`
(default: the first model the server reports).

Worth doing once: alias the boxes to the agents' own names
(`alias pi=pi-box claude=claude-box opencode=opencode-box agy=agy-box`), so the resume hint
each agent prints as it exits — `pi --session <id>` — is copy-pasteable.
See [Resuming a session](tools/README.md#resuming-a-session).

[`tools/README.md`](tools/README.md) covers the rest: what persists between
runs, how to customize a box and how to clean it out again.

## License

[MIT](LICENSE)
