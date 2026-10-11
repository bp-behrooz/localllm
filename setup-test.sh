#!/usr/bin/env bash
# Self-test for setup.sh's is_radiance (which preset's .rad download/remove manage).
set -uo pipefail
cd "$(dirname "$0")"
eval "$(sed -n '/^is_radiance()/,/^}/p' setup.sh)"
declare -F is_radiance >/dev/null || { echo "FAIL: is_radiance() not found in setup.sh"; exit 1; }
eval "$(sed -n '/^declare -A PRESET=(/,/^)/p' setup.sh)"   # the real shipped table
fail() { echo "FAIL: $1"; exit 1; }

is_radiance qwen3.8-radiance || fail "shipped radiance preset not detected"
[[ $RAD == qwen3.8-27b-mxfp4.rad ]] || fail "wrong RAD: $RAD"
is_radiance qwen3.8-flash-next || fail "flash-next radiance preset not detected"
[[ $RAD == qwen3.8-next-flash-fp8-iq4r-moe.rad ]] || fail "wrong RAD: $RAD"
for p in thinkingcap gpt-oss-120b; do
  is_radiance "$p" && fail "gguf preset $p matched"
done
[[ -z $RAD ]] || fail "non-radiance call left RAD=$RAD"

PRESET+=(
  [c]="1|cmd|./other-engine.sh"
  [o]="1|cmd|serve.sh a.rad --drafter b.rad"
  [t]="2|cmd|serve-radiance.sh a.rad --drafter b.rad"
  [p]="2|cmd|serve-radiance.sh /opt/localllm/models/x.rad --tp-wire wht6"
  [d]="2|cmd|serve-radiance.sh x.rad --draft x.rad"
  [x]="2|cmd|serve-radiance.sh model.radix"
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
echo "setup-test ok"
