#!/usr/bin/env bash
# Self-test for setup.sh's is_radiance (which preset's .rad download/remove manage).
set -uo pipefail
cd "$(dirname "$0")"
eval "$(sed -n '/^is_radiance()/,/^}/p' setup.sh)"
declare -F is_radiance >/dev/null || { echo "FAIL: is_radiance() not found in setup.sh"; exit 1; }
eval "$(sed -n '/^declare -A PRESET=(/,/^)/p' setup.sh)"   # the real shipped table
fail() { echo "FAIL: $1"; exit 1; }

is_radiance qwen3.8-radiance || fail "shipped radiance preset not detected"
[[ $RAD == qwen3.8-27b-fp8.rad ]] || fail "wrong RAD: $RAD"
[[ $RAD_REPO == StillDeadcode/qwen3.8-27b-fp8 ]] || fail "wrong default RAD_REPO: $RAD_REPO"
is_radiance qwen3.8-flash-next || fail "flash-next radiance preset not detected"
[[ $RAD == qwen3.8-next-flash-fp8-iq4r-moe.rad ]] || fail "wrong RAD: $RAD"
is_radiance gemma4-heretic || fail "gemma4-heretic radiance preset not detected"
[[ $RAD_REPO == keptn/gemma4-31b-heretic-ara-w4a8 ]] || fail "RAD_REPO not read from cmd: $RAD_REPO"
is_radiance thinkingcap || fail "thinkingcap radiance preset not detected"
[[ $RAD_REPO == - ]] || fail "local RAD_REPO=- not read: $RAD_REPO"

PRESET+=(
  [g]="1|org/x-GGUF:Q4_K_M|-c 4096"
  [c]="1|cmd|./other-engine.sh"
  [o]="1|cmd|serve.sh a.rad --drafter b.rad"
  [t]="2|cmd|serve-radiance.sh a.rad --drafter b.rad"
  [p]="2|cmd|serve-radiance.sh /opt/localllm/models/x.rad --tp-wire wht6"
  [d]="2|cmd|serve-radiance.sh x.rad --draft x.rad"
  [x]="2|cmd|serve-radiance.sh model.radix"
  [r]="2|cmd|MAXLEN=1 serve-radiance.sh x.rad --lora-dir NOT_RAD_REPO=a/b"
)
is_radiance g && fail "gguf preset matched"
[[ -z $RAD && -z $RAD_REPO ]] || fail "non-radiance call left RAD=$RAD RAD_REPO=$RAD_REPO"
is_radiance c && fail "non-radiance cmd preset matched"
[[ -z $RAD ]] || fail "non-radiance call left RAD=$RAD"
is_radiance o && fail "foreign .rad tokens matched a non-radiance cmd"
out=$(is_radiance t 2>&1); [[ $? -ne 0 && $out == *"more than one"* ]] || fail "two .rad not refused"
is_radiance p || fail "path-form .rad not detected"
[[ $RAD == x.rad ]] || fail "wrong RAD for path form: $RAD"
is_radiance d || fail "same .rad named twice treated as ambiguous"
[[ $RAD == x.rad ]] || fail "wrong RAD for duplicate: $RAD"
is_radiance x && fail ".rad-like token (model.radix) matched"
is_radiance r && [[ $RAD_REPO == StillDeadcode/x ]] || fail "suffix match took a RAD_REPO: $RAD_REPO"

# download refuses two repos for one .rad name, before fetching anything
# (setup.sh's models dir and download record, so hf_fetch's manifest_add has both)
MODELS=$(mktemp -d)
MANIFEST=$MODELS/.managed
chown() { :; }   # setup.sh runs as root, the test not; the record is just chowned
for fn in manifest_write manifest_add manifest_drop; do
  eval "$(sed -n "/^$fn()/,/^}/p" setup.sh)"
done
eval "$(sed -n '/^hf_fetch()/,/^}/p' setup.sh)"
declare -F hf_fetch >/dev/null || fail "hf_fetch() not found in setup.sh"
install() { :; }; sudo() { echo "fetched: $*"; }   # never reached on a clash
HF_TOKEN=test   # download sources it from /opt/localllm/env
# PRESET[t] (two .rads) stays in: a malformed other preset mustn't sink this download
PRESET+=([g2]="2|cmd|RAD_REPO=other/fork serve-radiance.sh gemma4-31b-heretic-ara-w4a8.rad")
out=$(set -e; hf_fetch gemma4-heretic 2>&1); rc=$?
[[ $rc -ne 0 && $out == *"rename one"* && $out != *fetched* ]] || fail "same .rad from two repos not refused: $out"
unset 'PRESET[g2]'
out=$(set -e; hf_fetch gemma4-heretic 2>&1) || fail "clash check failed a clean preset: $out"
# the scan clobbers RAD/RAD_REPO along the way: the fetch must still be this preset's own
[[ $out == *"hf download keptn/gemma4-31b-heretic-ara-w4a8 gemma4-31b-heretic-ara-w4a8.rad "* ]] \
  || fail "clean preset fetched the wrong repo/file: $out"
# a locally converted .rad (RAD_REPO=-) has nothing to download
out=$(set -e; hf_fetch thinkingcap 2>&1) || fail "local .rad failed download: $out"
[[ $out == *"converted locally"* && $out != *fetched* ]] || fail "local .rad not skipped: $out"

# prune: deletes a .rad `download` recorded that no preset names, and never one
# built by hand (no record) or one a preset still names
eval "$(sed -n '/^prune_models()/,/^}/p' setup.sh)"
declare -F prune_models >/dev/null || fail "prune_models() not found in setup.sh"
: >"$MODELS/keep.rad"; : >"$MODELS/stale.rad"; : >"$MODELS/handmade.rad"
manifest_add stale.rad StillDeadcode/stale
manifest_add keep.rad StillDeadcode/keep
manifest_add gone.rad StillDeadcode/gone        # recorded, already deleted by hand
PRESET=([k]="2|cmd|serve-radiance.sh keep.rad" [lg]="2|bartowski/x-GGUF:Q4_K_M|-c 4096")
out=$(prune_models) || fail "prune dry run failed: $out"
[[ -f $MODELS/stale.rad ]] || fail "dry run deleted stale.rad"
[[ $out == *stale.rad* && $out == *handmade.rad* && $out == *--yes* ]] \
  || fail "dry run output: $out"
out=$(prune_models --yes) || fail "prune --yes failed: $out"
[[ ! -e $MODELS/stale.rad ]] || fail "stale.rad not removed"
[[ -e $MODELS/keep.rad && -e $MODELS/handmade.rad ]] || fail "prune removed a kept or a by-hand .rad"
[[ $out != *gone.rad* ]] || fail "a record with no file was reported as prunable: $out"
grep -qx 'keep.rad StillDeadcode/keep' "$MANIFEST" || fail "manifest lost keep.rad: $(cat "$MANIFEST")"
grep -q '^stale.rad \|^gone.rad ' "$MANIFEST" && fail "manifest kept a removed file: $(cat "$MANIFEST")"
out=$(prune_models --yes) || fail "second prune failed: $out"
[[ $out == *"nothing to prune"* ]] || fail "second prune: $out"
rm -rf "$MODELS"

# the docs' copyable commands carry the pin's digest, or a bump ships a stale one
pin=$(sed -n 's/^IMAGE=.*@\(sha256:[0-9a-f]*\)}.*/\1/p' pool/serve-radiance.sh)
[[ -n $pin ]] || fail "no image pin read from pool/serve-radiance.sh"
grep -q "radiance@$pin" docs/presets.md || fail "docs/presets.md doesn't carry the pin's digest"
stale=$(grep -o 'radiance@sha256:[0-9a-f]*' docs/presets.md | grep -v "$pin" | sort -u)
[[ -z $stale ]] || fail "docs/presets.md names a digest the pin doesn't: $stale"
echo "setup-test ok"
