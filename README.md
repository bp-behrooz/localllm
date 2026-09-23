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
| [`tools/`](tools/README.md) | the agent boxes: pi / OpenCode against this server, plus Claude Code (unrelated — it talks to Anthropic as usual). Persistence, mise and customization documented there |
| `pool/test.sh` | self-test: bootstraps a local `.venv` and runs `pool.py --test` (no GPUs needed) |

## Requirements

- Linux with systemd (developed on Arch), two GPUs visible to ROCm
- `llama-server` (ROCm build) in `PATH`
- `python3`; everything else installs into `/opt/localllm/venv`
- A HuggingFace read token for gated model repos

## Install

On the GPU box, as root:

```bash
HF_TOKEN=hf_xxx ./setup.sh    # token is stored in /opt/localllm/env; only needed once
./setup.sh download           # pre-fetch all preset models (or name specific ones)
```

The final output prints the API key (`MASTER_KEY`) clients must send as a
Bearer token (`Authorization: Bearer sk-xxx`), or, for clients that can only
send a bare key in a header of their choosing, as `x-litellm-api-key: sk-xxx`.
`systemctl start|stop localllm` controls the whole stack.

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
  the preset's name. `download`/`remove` don't manage these. Advertise the
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
the dependencies (and, with mise, the python pinned in `mise.toml`) and runs
`pool/pool.py --test`.

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

Clients then use base URL `https://example.com/localllm/v1` with the master
key as API key.

## The qwen3.8-radiance preset

The preloaded preset serves Qwen3.8-27B in native MXFP4 through
[radiance-vllm-mxfp4](https://codeberg.org/ggz14/radiance-vllm-mxfp4)
(vLLM with RDNA4 kernels + speculative decoding; ~6× llama.cpp's dense-model
speed on the same cards). It's a `cmd` preset, so the radiance checkout is a
one-time manual install — as the `localllm` user, under its home:

```bash
sudo git clone https://codeberg.org/ggz14/radiance-vllm-mxfp4 /opt/localllm/radiance
sudo chown -R localllm:localllm /opt/localllm/radiance
sudo -u localllm env HOME=/opt/localllm ASSUME_YES=1 /opt/localllm/radiance/setup-mxfp4.sh
sudo ./setup.sh
```

`setup-mxfp4.sh` pulls the ~40 GiB image + checkpoints into `/opt/localllm`
(the pool user is added to the `docker` group by `setup.sh`). Cold start is
slower than a llama-server preset — engine init plus, on the very first run,
kernel compilation. Delete the preset from the table (and `PRELOAD`) if you
don't want any of this; nothing else depends on it.

## Agents (pi / OpenCode)

`tools/pi-box` and `tools/opencode-box` run the respective agent in a
sandboxed Apple `container` VM (Apple Silicon, macOS 26). They take the
server's base URL and key from the environment:

```bash
export PI_BOX_LOCAL_URL=https://example.com/localllm/v1   # OC_BOX_LOCAL_URL for opencode-box
export LOCAL_LLM_API_KEY=sk-xxx
./tools/pi-box          # or: ./tools/opencode-box
```

On first launch (or with `--sync`) they query the server and write the served
models, with context limits, into the box's own config under `~/.pi-box` /
`~/.opencode-box` — re-run with `--sync` after preset changes.

[`tools/README.md`](tools/README.md) covers the rest: what persists between
runs, how to customize a box and how to clean it out again.

## License

[MIT](LICENSE)
