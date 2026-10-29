# Preset notes

Per-model notes for the presets in `setup.sh`'s `PRESET` table. The format
itself is in the [README](../README.md#presets).

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

Six presets run on the
[radiance](https://codeberg.org/StillDeadcode/radiance) engine, C++/HIP with
RDNA4 kernels and speculative decoding:

- `qwen3.8-flash-next` (preloaded): Qwen3.8-Flash-Next, an MoE with an int8
  trunk and 4-bit experts, 256K context. The experts that don't fit VRAM
  stream from a pinned host pool (12 GiB per GPU, so 24 GiB of RAM), and idle
  sessions move to RAM (up to 4 GiB). Sized for 2× 32 GB cards, 96 GB of RAM
  and the 114 GiB model on the `/opt` disk.
- `qwen3.8-radiance`: Qwen3.8-27B in Qwen's own FP8 (128×128 blocks) with
  its DFlash2 drafter, 256K context.
- `qwen3.8-m2xfp4`: Qwen3.8-27B as the PARO-M2XFP4 container (19.6 GiB,
  4.25 bits a weight) with its DFlash2 drafter. **Single GPU only**: the
  learned rotation is per projection, so radiance refuses `--tp > 1`. One 262K
  sequence a replica; quality sits between plain MXFP4 and FP8 (KL 0.0211
  against 0.0117).
- `ornith-1.5`: Ornith-1.5-35B-A3B w4a8 (19.7 GiB), a 35B-A3B MoE with
  vision, tools and thinking, one card, 262K context, up to 8 sequences.
  About 229 tok/s on one R9700, far quicker than the 27B dense, at KL 0.064
  to its bf16 original, so below the 27B FP8 in fidelity.
- `gemma4-heretic`: Gemma 4 31B heretic-ara (refusals removed) with a GPTQ
  int4 trunk, int8 activations and MTP, 64K context at 8 sequences
  (upstream's flags; 256K fits at `--max-num-seqs 2`).
- `thinkingcap`: ThinkingCap-Qwen3.8-27B (a Qwen3.8-27B finetune that
  reasons in fewer tokens) as block FP8 with Qwen3.8's DFlash2 drafter, the
  same form and speed as `qwen3.8-radiance`. Nobody publishes this `.rad`, so
  it's [converted locally](#converting-thinkingcap).

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
cd /opt/localllm   # podman must start in a dir localllm can enter
sudo -u localllm env HOME=/opt/localllm XDG_RUNTIME_DIR=/run/user/$(id -u localllm) \
  podman pull docker.io/stilldeadcode/radiance@sha256:e648ec53a68c42f329d80fbbc008ee96f5301ada6b100475c731d2ca1ebb9c16
sudo ./setup.sh download qwen3.8-flash-next qwen3.8-radiance gemma4-heretic   # 114 + 29 + 20 GiB
sudo systemctl restart localllm
```

`download` and `remove` fetch and delete a preset's `.rad`. Skip a model you
don't want, and delete its preset from the table (and `PRELOAD`). Cold start is slower than a llama-server preset: engine init plus
loading the model, several minutes for Flash-Next.

The image is pinned by digest in `serve-radiance.sh` (currently 1.13.0), since
radiance releases rename and drop engine flags; upgrade by changing that pin
and the presets' flags together. Its ROCm 10.1 userspace needs an amdgpu
driver of interface 3.64 or later (Linux 6.16+): on an older kernel it starts,
but without GPU virtual memory, so Flash-Next's KV cache can't lend VRAM to
the experts.

### Converting thinkingcap

Accept the gated repo's terms on Hugging Face with your token's account
first. It needs ~85 GiB free while it runs, CPU only, and uses the DFlash2
recipe from the pinned image:

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
    docker.io/stilldeadcode/radiance@sha256:e648ec53a68c42f329d80fbbc008ee96f5301ada6b100475c731d2ca1ebb9c16 \
    /src/bottlecapai/ThinkingCap-Qwen3.8-27B --draft-model /src/z-lab/Qwen3.8-27B-DFlash2 \
    --recipe /opt/radiance/share/radiance/recipes/q38-27b-fp8block-df2.recipe \
    --set quantization_config.quant_method=fp8 --set quantization_config.fmt=e4m3 \
    --set "quantization_config.weight_block_size=128 128" \
    --set quantization_config.activation_scheme=dynamic \
    -o /models/thinkingcap-qwen3.8-27b-fp8-df2.rad
rm -rf $SRC   # once the .rad serves well
```
