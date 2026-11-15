# Preset notes

Per-model notes for the presets in `setup.sh`'s `PRESET` table. The format
itself is in the [README](../README.md#presets).

## The radiance presets

All presets run on the
[radiance](https://codeberg.org/StillDeadcode/radiance) engine, C++/HIP with
RDNA4 kernels and speculative decoding:

- `qwen3.8-flash-next` (preloaded): Qwen3.8-Flash-Next in IQR-V4 (int8 shared
  path, IQ4R-V4 routed experts, vocabulary-weighted head; 113.3 GiB), 256K
  context. The experts that don't fit VRAM stream from a pinned host pool
  (`--host-pool-mib 24576` total across both GPUs, so 12 GiB per card), and idle
  sessions move to RAM (up to 4 GiB). Sized for 2× 32 GB cards, 96 GB of RAM
  and the 114 GiB model on the `/opt` disk.
- `qwen3.8-radiance`: Qwen3.8-27B in IQ8R (Hadamard-rotated int8, 28.8 GiB,
  KL 0.00039 vs 0.00363 for block FP8) with its DFlash2 drafter, 256K context.
- `qwen3.8-iq4r`: Qwen3.8-27B in IQR-V4 (`qwen3.8-27b-iq4r-l-v4.rad`, 17.4 GiB,
  4.79 bits a weight): every trunk linear rotated by a 128-wide Hadamard and
  fitted by GPTQ against calibration Hessians, with a vocabulary-weighted head
  and its DFlash2 drafter and vision tower merged in. One card, up to 8
  sequences sharing the `i8` KV pool (~380K tokens on one 32 GB card). KL
  0.00297 and 98.07% top-1 against the bf16 model.
- `ornith-1.5`: Ornith-1.5-35B-A3B w4a8 v2.0 (19.75 GiB, IQ8R non-expert
  linears and 4-bit routed experts; KL 0.0122 vs 0.064 in v1.0), a 35B-A3B MoE
  with vision, tools and thinking, one card, 262K context, up to 8 sequences.
  About 229 tok/s on one R9700. **Note**: if upgrading from Radiance 1.17,
  re-download `ornith-1.5-35b-a3b-w4a8.rad` (`./setup.sh remove ornith-1.5 &&
  ./setup.sh download ornith-1.5`), as Radiance 2.0 refuses the v1.0 block-FP8
  trunk.
- `gemma4-heretic`: Gemma 4 31B heretic-ara (refusals removed) with a GPTQ
  int4 trunk, int8 activations and MTP, 256K context at 8 sequences
  (upstream's flags at the trained context: the card measures a 1M-token
  KV pool on 2 cards at 8 sequences, so ~4 full-length ones at once).
- `thinkingcap`: ThinkingCap-Qwen3.8-27B (a Qwen3.8-27B finetune that
  reasons in fewer tokens) as IQ8R with Qwen3.8's DFlash2 drafter, the
  same form and speed as `qwen3.8-radiance`. Nobody publishes this `.rad`, so
  it's [converted locally](#converting-thinkingcap).
- `nanbeige4.3` and `nanbeige4.3-int4`: Nanbeige4.3-33B (a 52-layer
  Llama-shaped dense model with 56 query heads over 8 KV heads at `head_dim`
  128, GQA 7), served natively by Radiance 2.0 (`arch/llama_dense_fp8` +
  `libr4d`'s `gqa7` paged attention). Both are [converted locally](#converting-nanbeige43):
  `nanbeige4.3` is IQ8R (~34 GiB, ~33 tok/s decode on 2 GPUs), and
  `nanbeige4.3-int4` is 4-bit (~20 GiB, ~53 tok/s decode on 2 GPUs at 262K
  context; also fits 1 GPU at `MAXLEN=131072`, ~30 tok/s, if changed to `1|`).
- `flint`: Recursive Flint (39.8B total / ~2.5B active: 2 dense layers + 47
  sigmoid-routed MoE layers with 256 experts top-6, sink attention, 35 sliding
  layers at window 513 and 14 full NoPE layers) in IQ8R (`flint-iq8r.rad`,
  37.9 GiB, Hadamard-rotated int8 trunk and experts), 2 GPUs, 256K context
  (~147 tok/s decode on two R9700s).

A preset whose `.rad` isn't in a `StillDeadcode/<name>` repo names its repo
with `RAD_REPO=<owner/repo>` in the cmd, as `gemma4-heretic` does;
`RAD_REPO=-` marks one converted locally, which `download` skips.

### Install

They're `cmd` presets: `setup.sh` installs their launcher
(`/opt/localllm/serve-radiance.sh <model.rad> [engine flags]`); the image and
models are a one-time manual install, as the `localllm` user. Run `setup.sh`
first, as it gives `localllm` the subuid range and lingering user manager
rootless podman needs:

```bash
sudo pacman -S podman crun
sudo ./setup.sh
(cd /opt/localllm && sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman pull docker.io/stilldeadcode/radiance@sha256:d3d6c796083b0d00f2b462554aa002f853248506d55658d60d685017abb9b42d)
sudo ./setup.sh download qwen3.8-flash-next qwen3.8-radiance gemma4-heretic   # 114 + 29 + 20 GiB
sudo systemctl restart localllm
```

`download` and `remove` fetch and delete a preset's `.rad`. Skip a model you
don't want, and delete its preset from the table (and `PRELOAD`). Cold start is slower than a llama-server preset: engine init plus
loading the model, several minutes for Flash-Next.

`prune` deletes what `download` fetched that no preset names any more, and
only that: every fetch is recorded in `models/.managed`, so a `.rad` built
here with `rad-convert` — or one old enough to predate the record — has no
line and is never removed, only listed. It prints the plan and deletes
nothing until `--yes`. Re-running `download` on a preset that is already
local records it, which backfills the record.

`serve-radiance.sh` pins the image by digest, and the comment beside the pin
names its release. Radiance releases rename and drop engine flags, so move
that pin and the presets' flags together. Its ROCm 10.1 userspace needs an
amdgpu driver of interface 3.64 or later (Linux 6.16+): on an older kernel it
starts, but without GPU virtual memory, so Flash-Next's KV cache can't lend
VRAM to the experts.

### Converting thinkingcap

Accept the gated repo's terms on Hugging Face with your token's account
first. It needs ~85 GiB free while it runs, CPU only, and uses the round-to-nearest
IQ8R + DFlash2 recipe (`q38-27b-iq8r-rtn.recipe`, no calibration Hessians needed)
from the pinned image:

```bash
SRC=/opt/localllm/hf-src; sudo install -d -o localllm -g localllm $SRC
for r in bottlecapai/ThinkingCap-Qwen3.8-27B z-lab/Qwen3.8-27B-DFlash2; do
  sudo -u localllm bash -c 'source /opt/localllm/env && HF_TOKEN=$HF_TOKEN HF_XET_HIGH_PERFORMANCE=1 \
    /opt/localllm/venv/bin/hf download "$1" --local-dir "$2"' _ "$r" "$SRC/$r"
done
(cd /opt/localllm && sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman run --rm --log-driver k8s-file \
    -v $SRC:/src:ro -v /opt/localllm/models:/models --entrypoint rad-convert \
    docker.io/stilldeadcode/radiance@sha256:d3d6c796083b0d00f2b462554aa002f853248506d55658d60d685017abb9b42d \
    /src/bottlecapai/ThinkingCap-Qwen3.8-27B --draft-model /src/z-lab/Qwen3.8-27B-DFlash2 \
    --recipe /opt/radiance/share/radiance/recipes/q38-27b-iq8r-rtn.recipe \
    --set quantization_config.quant_method=w8a8 --set quantization_config.fmt=fwht128 \
    -o /models/thinkingcap-qwen3.8-27b-iq8r-df2.rad)
sudo rm -rf $SRC   # once the .rad serves well
```

### Converting nanbeige4.3

Both `nanbeige4.3` (`nanbeige4.3-33b-iq8r.rad`, ~34 GiB) and `nanbeige4.3-int4`
(`nanbeige4.3-33b-int4.rad`, ~20 GiB) can be converted from the official bf16
checkpoint (`Nanbeige/Nanbeige4.3-33B`), or `nanbeige4.3-int4` from
`Nanbeige/Nanbeige4.3-33B-INT4`:

```bash
SRC=/opt/localllm/hf-src; sudo install -d -o localllm -g localllm $SRC
sudo -u localllm bash -c 'source /opt/localllm/env && HF_TOKEN=$HF_TOKEN HF_XET_HIGH_PERFORMANCE=1 \
  /opt/localllm/venv/bin/hf download Nanbeige/Nanbeige4.3-33B --local-dir "$1"' _ "$SRC/Nanbeige4.3-33B"

# 1. IQ8R (~34 GiB, 2 GPUs, ~33 tok/s decode):
(cd /opt/localllm && sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman run --rm --log-driver k8s-file \
    -v $SRC:/src:ro -v /opt/localllm/models:/models --entrypoint rad-convert \
    docker.io/stilldeadcode/radiance@sha256:d3d6c796083b0d00f2b462554aa002f853248506d55658d60d685017abb9b42d \
    /src/Nanbeige4.3-33B \
    --recipe /opt/radiance/share/radiance/recipes/minicpm5-2b-iq8r.recipe \
    -o /models/nanbeige4.3-33b-iq8r.rad)

# 2. INT4 (~20 GiB, 2 GPUs at 262K / ~53 tok/s, or 1 GPU at 131K / ~30 tok/s):
(cd /opt/localllm && sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman run --rm --log-driver k8s-file \
    -v $SRC:/src:ro -v /opt/localllm/models:/models --entrypoint rad-convert \
    docker.io/stilldeadcode/radiance@sha256:d3d6c796083b0d00f2b462554aa002f853248506d55658d60d685017abb9b42d \
    /src/Nanbeige4.3-33B \
    --quant 'output.weight=rtn:codes=i8,group=128,scale=bf16,clamp=sym,rule=search' \
    --quant 'blk.*.weight=rtn:codes=u4,zero=u8,group=128,scale=f16,transform=fwht128,rule=search' \
    -o /models/nanbeige4.3-33b-int4.rad)
sudo rm -rf $SRC   # once the .rads serve well
```
