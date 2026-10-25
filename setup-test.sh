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
for p in flint; do
  is_radiance "$p" && fail "gguf preset $p matched"
done
[[ -z $RAD && -z $RAD_REPO ]] || fail "non-radiance call left RAD=$RAD RAD_REPO=$RAD_REPO"

PRESET+=(
  [c]="1|cmd|./other-engine.sh"
  [o]="1|cmd|serve.sh a.rad --drafter b.rad"
  [t]="2|cmd|serve-radiance.sh a.rad --drafter b.rad"
  [p]="2|cmd|serve-radiance.sh /opt/localllm/models/x.rad --tp-wire wht6"
  [d]="2|cmd|serve-radiance.sh x.rad --draft x.rad"
  [x]="2|cmd|serve-radiance.sh model.radix"
  [r]="2|cmd|MAXLEN=1 serve-radiance.sh x.rad --lora-dir NOT_RAD_REPO=a/b"
)
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
eval "$(sed -n '/^hf_fetch()/,/^}/p' setup.sh)"
declare -F hf_fetch >/dev/null || fail "hf_fetch() not found in setup.sh"
install() { echo "fetched"; }; sudo() { echo "fetched"; }   # never reached on a clash
HF_TOKEN=test   # download sources it from /opt/localllm/env
unset 'PRESET[t]'   # the two-.rad preset dies in is_radiance before the clash check
PRESET+=([g2]="2|cmd|RAD_REPO=other/fork serve-radiance.sh gemma4-31b-heretic-ara-w4a8.rad")
out=$(set -e; hf_fetch gemma4-heretic 2>&1); rc=$?
[[ $rc -ne 0 && $out == *"rename one"* && $out != *fetched* ]] || fail "same .rad from two repos not refused: $out"
unset 'PRESET[g2]'
out=$(set -e; hf_fetch gemma4-heretic 2>&1) || fail "clash check failed a clean preset: $out"
[[ $out == *fetched* ]] || fail "clean preset not fetched: $out"
# a locally converted .rad (RAD_REPO=-) has nothing to download
out=$(set -e; hf_fetch thinkingcap 2>&1) || fail "local .rad failed download: $out"
[[ $out == *"converted locally"* && $out != *fetched* ]] || fail "local .rad not skipped: $out"
echo "setup-test ok"
