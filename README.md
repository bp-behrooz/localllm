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
| `pool/test.sh` | self-test, no GPUs needed: bootstraps a local `.venv` (with mise, the python pinned in `mise.toml`), runs `pool.py --test` and `setup-test.sh` |
| [`docs/presets.md`](docs/presets.md) | notes on the individual presets, and installing the radiance engine |
| [`tools/`](tools/README.md) | the agent boxes: sandboxed coding agents, some against this server |

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
300/270/240/210; written to the GPUs' `power1_cap` sysfs at startup, so the
unit needs write access to that file, i.e. root or a group-writable file),
`IDLE_TTL` / `IDLE_TTL_CMD` / `REAP_INTERVAL` (seconds; override `pool.json`).

All logs, the pool's and every engine's, are in `journalctl -u localllm -f`.
`setup.sh` sets `localllm`'s podman to the `passthrough` log driver and turns
off per-container cgroups, so containers write straight to the pool's stdout
and `systemctl stop localllm` stops them too. The costs: `podman logs` shows
nothing, `podman run -d` as `localllm` needs `--log-driver k8s-file`, and
there are no per-container limits or `podman stats`.

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
- Sampling flags (`--temp`, `--top-p`, …) become server-side defaults; use
  each model card's recommended values. Clients that send their own override
  them per request.
- `-c` (context size) is also published through the server's `/model/info` so
  clients can discover each model's window.

Two extras:

- **Custom engines**: `[name]="gpus|cmd|<command>"` runs an arbitrary serving
  command instead of `llama-server`. The pool executes it via `bash -c` with
  `PORT`, `GPUS` (HIP indices) and `NAME` (a unique instance name) in the
  environment; it must serve `/health` and OpenAI-style `/v1` on `PORT`, under
  the preset's name. Advertise the context window with a `MAXLEN=<n>` in the
  command so `/model/info` picks it up. The radiance presets are built this
  way; see [docs/presets.md](docs/presets.md#the-radiance-presets).
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
  if it must download, so pre-download to avoid that) and the request then
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

## Remote access via Caddy

The server listens on `0.0.0.0:4000` (open the port for your LAN, e.g.
`ufw allow from 192.168.2.0/24 to any port 4000 proto tcp`). To reach it from
outside, let a Caddy that can reach the box terminate TLS. Auth is the key
enforced by the server itself, so Caddy just proxies. Allowlisting the API
paths keeps everything else (like the unauthenticated `/health`) off the
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

## Agents

pi, OpenCode and Open Code Review can run against this server in sandboxed
boxes; see [`tools/README.md`](tools/README.md).

## License

[MIT](LICENSE)
