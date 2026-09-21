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
| `pool.py` | the server: bearer-key auth, GPU scheduling (spawn/evict `llama-server` instances), request proxying |
| `tools/pi-box`, `tools/opencode-box` | run the pi / OpenCode agent in a sandboxed VM (Apple `container`); sync the served models on launch |
| `tools/claude-box` | same sandbox for Claude Code; unrelated to this server, it talks to Anthropic as usual |

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
Bearer token. `systemctl start|stop localllm` controls the whole stack.

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
  has been idle 10+ minutes (`IDLE_SCALE_EVICT` in `pool.py`).
- Instances with requests in flight are never evicted; if nothing can be
  evicted the request gets a 503.

Inspect the pool: `curl -s localhost:4000/health | python3 -m json.tool`
(`/health` is the one endpoint that doesn't require the key; it reveals only
which models are loaded).

Self-test (no GPUs needed): `python3 pool.py --test`

## Remote access via Caddy

The server listens on `0.0.0.0:4000` (open the port for your LAN, e.g.
`ufw allow from 192.168.2.0/24 to any port 4000 proto tcp`). To reach it from
outside, let a Caddy that can reach the box terminate TLS. Auth is the Bearer
key enforced by the server itself, so Caddy just proxies — allowlisting the
API paths keeps everything else (like the unauthenticated `/health`) off the
internet:

```caddyfile
example.com {
    handle_path /localllm/* {
        @api path /v1/* /model/info
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
`~/.opencode-box` — re-run with `--sync` after preset changes. See each
script's header for the full list of knobs.

## License

[MIT](LICENSE)
