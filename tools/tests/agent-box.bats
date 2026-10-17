#!/usr/bin/env bats
# The boxes' own logic, against stubbed runtimes: what they'd pass to
# `podman run` / `container run` on Linux, WSL2 and a Mac.

load helpers

# ---------------------------------------------------------------- runtime -----
@test "runtime: krun on Linux" {
  load_lib
  [[ $(box_runtime) == krun ]]
}

@test "runtime: crun on WSL2" {
  as_wsl
  load_lib
  [[ $(box_runtime) == crun ]]
}

@test "runtime: the knob wins on WSL2" {
  as_wsl
  load_lib
  CL_BOX_RUNTIME=krun
  [[ $(box_runtime) == krun ]]
}

@test "runtime: none on a Mac" {
  as_mac
  load_lib
  [[ -z $(box_runtime) ]]
}

@test "runtime: krun sizes its VM from annotations" {
  load_lib
  BOX_RUN_ARGS=()
  CL_BOX_MEMORY=2G CL_BOX_CPUS=2
  _box_runtime_args
  [[ " ${BOX_RUN_ARGS[*]} " == *" --runtime krun "* ]]
  [[ " ${BOX_RUN_ARGS[*]} " == *" krun.ram_mib=2048 "* ]]
  [[ " ${BOX_RUN_ARGS[*]} " == *" krun.cpus=2 "* ]]
}

@test "runtime: krun refuses memory it can't size" {
  load_lib
  BOX_RUN_ARGS=()
  CL_BOX_MEMORY=2T
  run _box_runtime_args
  [[ $status -ne 0 && $output == *"krun wants it in M or G"* ]]
}

# --------------------------------------------------------------- WSL2 note -----
wsl_note() {
  as_wsl
  load_lib
  BOX_WSL_CONF="$BATS_TEST_TMPDIR/wsl.conf"
  printf '%s\n' "$@" >"$BOX_WSL_CONF"
  run _box_wsl_note
}

@test "wsl note: both open without a wsl.conf" {
  as_wsl
  load_lib
  BOX_WSL_CONF="$BATS_TEST_TMPDIR/missing"
  run _box_wsl_note
  [[ $output == *"/mnt/c"*"interop"*"docs/WSL2.md"* ]]
}

@test "wsl note: names only what's still open" {
  wsl_note '[automount]' 'enabled = false'
  [[ $output != *"/mnt/c"* && $output == *"interop"* ]]
}

@test "wsl note: silent when both are off" {
  wsl_note '[boot]' 'systemd=true' '' '[automount]' 'enabled=false  # no C:' \
    '[Interop]' 'Enabled = False' 'appendWindowsPath=false'
  [[ -z $output ]]
}

@test "wsl note: a key in another section doesn't count" {
  wsl_note '[network]' 'enabled=false' '[automount]' 'root=/win/'
  [[ $output == *"/mnt/c"*"interop"* ]]
}

@test "wsl note: silent under krun" {
  as_wsl
  load_lib
  BOX_WSL_CONF="$BATS_TEST_TMPDIR/missing"
  CL_BOX_RUNTIME=krun
  run _box_wsl_note
  [[ -z $output ]]
}

@test "wsl note: silent off WSL" {
  load_lib
  BOX_WSL_CONF="$BATS_TEST_TMPDIR/missing"
  CL_BOX_RUNTIME=crun
  run _box_wsl_note
  [[ -z $output ]]
}

# -------------------------------------------------------------------- git -----
@test "git: a plain repo needs no extra mount" {
  make_repo main
  cd main
  load_lib
  BOX_RUN_ARGS=()
  _box_git_dir_volume
  [[ ${#BOX_RUN_ARGS[@]} -eq 0 ]]
}

@test "git: a worktree mounts the main repo's .git" {
  make_repo main
  git_q -C main worktree add -b foo ../agents/foo
  cd agents/foo
  load_lib
  BOX_RUN_ARGS=()
  _box_git_dir_volume 2>/dev/null
  local git_dir
  git_dir="$(cd ../../main/.git && pwd -P)"
  [[ ${BOX_RUN_ARGS[*]} == "--volume $git_dir:$git_dir" ]]
}

@test "git: outside a repo, nothing" {
  mkdir plain
  cd plain
  load_lib
  BOX_RUN_ARGS=()
  _box_git_dir_volume
  [[ ${#BOX_RUN_ARGS[@]} -eq 0 ]]
}

# ------------------------------------------------------------------ flags -----
@test "flags: --profile NAME and --profile=NAME" {
  load_lib
  box_parse_args --profile work --shell -c x
  [[ $CL_BOX_PROFILE == work && $BOX_SHELL -eq 1 && ${BOX_ARGS[*]} == "-c x" ]]
  box_parse_args --profile=home
  [[ $CL_BOX_PROFILE == home ]]
}

@test "flags: a profile name has to be a plain word" {
  load_lib
  run box_parse_args --profile '../x'
  [[ $status -ne 0 && $output == *"use letters, digits"* ]]
}

@test "flags: -- ends the box's own flags" {
  load_lib
  box_parse_args --ssh -- --shell
  [[ $CL_BOX_SSH -eq 1 && $BOX_SHELL -eq 0 && ${BOX_ARGS[*]} == --shell ]]
}

# ------------------------------------------------------------------- data -----
@test "data: each worktree gets its own volumes" {
  make_repo main
  git_q -C main worktree add -b foo ../agents/foo
  load_lib
  local a b
  a="$(cd main && _box_data_prefix)"
  b="$(cd agents/foo && _box_data_prefix)"
  [[ $a == agentbox-default-main-* && $b == agentbox-default-foo-* && $a != "$b" ]]
}

@test "data: the project knob names it" {
  load_lib
  CL_BOX_PROJECT=shop CL_BOX_PROFILE=work
  [[ $(_box_data_prefix) == agentbox-work-shop- ]]
}

# ------------------------------------------------------- the whole script -----
@test "box: Linux runs podman with the project at its own path" {
  export CL_BOX_RUNTIME=crun
  run_box --shell -c true
  [[ $status -eq 0 ]]
  run_has --volume "$PWD:$PWD"
  run_has --workdir "$PWD"
  run_has --volume "$HOME/.claude-box:/root"
  run_has --runtime crun
  run_has --entrypoint /usr/local/bin/box-entry
  run_has --env ANTHROPIC_CUSTOM_HEADERS
  run_has claude-box bash
  run_has -c true
  run_lacks -t
}

@test "box: WSL2 runs crun and says what's reachable" {
  as_wsl
  run_box --shell -c true
  [[ $status -eq 0 ]]
  run_has --runtime crun
  [[ $output == *"WSL2:"* ]]
}

@test "box: a Mac runs container, without --runtime" {
  as_mac
  run_box --shell -c true
  [[ $status -eq 0 ]]
  grep -q '^container run' "$FAKE_DIR/calls"
  run_has --volume "$PWD:$PWD"
  run_lacks --runtime
}

@test "box: a worktree gets the main repo's .git" {
  as_mac
  make_repo main
  git_q -C main worktree add -b foo ../agents/foo
  cd agents/foo
  run_box --shell -c true
  [[ $status -eq 0 ]]
  local git_dir
  git_dir="$(cd ../../main/.git && pwd -P)"
  run_has --volume "$git_dir:$git_dir"
}

@test "box: a profile's variables go in by name only" {
  as_mac
  printf 'export SECRET_TOKEN=s3cret\nFOO=bar\n' >"$HOME/.box.work.env"
  run_box --profile work --shell -c true
  [[ $status -eq 0 ]]
  run_has --env SECRET_TOKEN
  run_has --env FOO
  run grep -q s3cret "$FAKE_DIR/run.args"
  [[ $status -ne 0 ]]
}

@test "box: refuses rootful podman" {
  export CL_BOX_RUNTIME=crun FAKE_ROOTLESS=false
  run_box --shell -c true
  [[ $status -ne 0 && $output == *"not rootless"* ]]
}

# ------------------------------------------------------------------ clean ----
# --clean-all and --clean-data ask on the tty, so these use --clean: same code
# path, no answer needed.
@test "clean: a bare clean stops there" {
  export CL_BOX_RUNTIME=crun
  mkdir -p "$HOME/.claude-box/runtimes"
  touch "$HOME/.claude-box/runtimes/node"
  run_box --clean
  [[ $status -eq 0 && ! -e "$HOME/.claude-box/runtimes" ]]
  call_lacks "podman build"
}

@test "clean: --rebuild --clean cleans, then rebuilds and runs" {
  export CL_BOX_RUNTIME=crun
  mkdir -p "$HOME/.claude-box/runtimes"
  touch "$HOME/.claude-box/runtimes/node"
  run_box --rebuild --clean
  [[ $status -eq 0 && ! -e "$HOME/.claude-box/runtimes" ]]
  call_has "podman image rm"
  call_has "podman build"
  call_has "podman run"
}

# -------------------------------------------------------------- pi-box sync ----
# --sync-only stops before the runtime, so a plain file answers the server:
# sync_models fetches <root>/model/info, and urllib reads file:// URLs.
# Shared by every box that syncs models.
llm_serve() {
  local json m
  for m in "$@"; do
    json+="{\"model_name\":\"$m\",\"model_info\":{\"max_input_tokens\":32768}},"
  done
  mkdir -p "$BATS_TEST_TMPDIR/llm/model"
  printf '{"data":[%s]}' "${json%,}" >"$BATS_TEST_TMPDIR/llm/model/info"
}

pi_sync() {
  export PI_BOX_HOME="$BATS_TEST_TMPDIR/pi-home" \
    LOCAL_LLM_URL="file://$BATS_TEST_TMPDIR/llm/v1" LOCAL_LLM_API_KEY=sk-test
  run bash "$TOOLS/pi-box" --sync-only
}

pi_default() {
  python3 -c 'import json,os
s = json.load(open(os.path.join(os.environ["PI_BOX_HOME"], ".pi/agent/settings.json")))
print(s["defaultProvider"] + "/" + s["defaultModel"])'
}

# what Ctrl+S on a model in /model leaves behind
pi_pick() {
  PI_BOX_HOME="$PI_BOX_HOME" PICK="$1" python3 -c 'import json,os
p = os.path.join(os.environ["PI_BOX_HOME"], ".pi/agent/settings.json")
s = json.load(open(p))
s["defaultProvider"], _, s["defaultModel"] = os.environ["PICK"].partition("/")
json.dump(s, open(p, "w"))'
}

@test "pi sync: seeds the default model on a fresh home" {
  llm_serve qwen3-coder llama-4-scout
  pi_sync
  [[ $status -eq 0 && $output == *"default model local/qwen3-coder"* ]]
  [[ $(pi_default) == local/qwen3-coder ]]
}

@test "pi sync: moves a model saved in the box back onto the first served one" {
  llm_serve qwen3-coder llama-4-scout
  pi_sync
  pi_pick local/llama-4-scout
  pi_sync
  [[ $output == *"default model local/qwen3-coder"* ]]
  [[ $(pi_default) == local/qwen3-coder ]]
}

@test "pi sync: follows the server when a preset disappears" {
  llm_serve qwen3-coder
  pi_sync
  llm_serve radiance-2
  pi_sync
  [[ $status -eq 0 && $output == *"default model local/radiance-2"* ]]
  [[ $(pi_default) == local/radiance-2 ]]
}

@test "pi sync: PI_BOX_DEFAULT wins, and has to be served" {
  llm_serve qwen3-coder
  PI_BOX_DEFAULT=opencode-go/minimax-m2.7 pi_sync
  [[ $status -eq 0 ]]
  [[ $(pi_default) == opencode-go/minimax-m2.7 ]]
  PI_BOX_DEFAULT=local/not-a-model pi_sync
  [[ $status -ne 0 && $output == *"not served"* ]]
}

# --------------------------------------------- opencode-box sync -------------
# Same file-backed server; the box keeps its own config and its recent-model
# state under OC_BOX_HOME, which is the container's whole /root.
oc_sync() {
  export OC_BOX_HOME="$BATS_TEST_TMPDIR/oc-home" \
    LOCAL_LLM_URL="file://$BATS_TEST_TMPDIR/llm/v1" LOCAL_LLM_API_KEY=sk-test
  run bash "$TOOLS/opencode-box" --sync-only
}

# what opencode starts on: the first entry of its recent models
oc_start() {
  python3 -c 'import json,os
s = json.load(open(os.path.join(os.environ["OC_BOX_HOME"], ".local/state/opencode/model.json")))
print(s["recent"][0]["providerID"] + "/" + s["recent"][0]["modelID"])'
}

# what /model leaves behind when you pick another one
oc_pick() {
  OC_BOX_HOME="$OC_BOX_HOME" PICK="$1" python3 -c 'import json,os
p = os.path.join(os.environ["OC_BOX_HOME"], ".local/state/opencode/model.json")
s = json.load(open(p))
pid, _, mid = os.environ["PICK"].partition("/")
s["recent"][0] = {"providerID": pid, "modelID": mid}
json.dump(s, open(p, "w"))'
}

@test "opencode sync: seeds the provider and starts on the first served model" {
  llm_serve qwen3-coder llama-4-scout
  oc_sync
  [[ $status -eq 0 && $output == *"synced 2 local model(s)"* ]]
  [[ $(oc_start) == localllm/qwen3-coder ]]
  python3 -c 'import json,os
cfg = json.load(open(os.path.join(os.environ["OC_BOX_HOME"], ".config/opencode/opencode.json")))
p = cfg["provider"]["localllm"]
assert p["options"]["baseURL"] == os.environ["LOCAL_LLM_URL"], p["options"]
assert p["options"]["apiKey"] == "{env:LOCAL_LLM_API_KEY}", p["options"]
assert set(p["models"]) == {"qwen3-coder", "llama-4-scout"}, p["models"]
assert "model" not in cfg, "a pin here would outrank the recent models"'
}

@test "opencode sync: OC_BOX_DEFAULT picks where the box starts" {
  llm_serve qwen3-coder llama-4-scout
  OC_BOX_DEFAULT=localllm/llama-4-scout oc_sync
  [[ $status -eq 0 && $output == *"current model localllm/llama-4-scout"* ]]
  [[ $(oc_start) == localllm/llama-4-scout ]]
}

@test "opencode sync: a model picked in the box lasts until the next sync" {
  llm_serve qwen3-coder llama-4-scout
  oc_sync
  oc_pick localllm/llama-4-scout
  oc_sync
  [[ $(oc_start) == localllm/qwen3-coder ]]
}

# -------------------------------------------- opencode-box private server ----
# 2.0's background service registers itself in the shared home, once per user,
# so two boxes on one home would overwrite each other's registration and both
# TUIs loop on "Your session will resume automatically". The box runs each
# agent with its own server instead.
@test "opencode: the agent gets a private server, so boxes don't fight" {
  make_repo main
  git_q -C main worktree add -b foo ../agents/foo
  llm_serve qwen3-coder
  cd main
  oc_run
  [[ $status -eq 0 ]]
  run_has --standalone
  run_has opencode-box --standalone
  local main_db
  main_db="$(grep '^OPENCODE_DB=' "$FAKE_DIR/run.args")"
  [[ $main_db == OPENCODE_DB=agentbox-default-main-*.db ]]
  cd ../agents/foo
  oc_run --continue
  run_has --standalone
  local foo_db
  foo_db="$(grep '^OPENCODE_DB=' "$FAKE_DIR/run.args")"
  [[ $foo_db == OPENCODE_DB=agentbox-default-foo-*.db && $foo_db != "$main_db" ]]
  oc_run .
  run_has --standalone
  # A second opencode-box in the same worktree is refused while the lock is held.
  local lock="$XDG_RUNTIME_DIR/agentbox-locks/opencode-${foo_db#OPENCODE_DB=}"
  lock="${lock%.db}"
  mkdir -p "$lock" && echo $$ >"$lock/pid"
  oc_run
  [[ $status -ne 0 && $output == *"another box (pid $$)"* ]]
  # --shell still gets in for debugging.
  oc_run --shell -c true
  [[ $status -eq 0 ]]
}

@test "opencode: bash and a subcommand keep their command" {
  llm_serve qwen3-coder
  oc_run --shell -c true
  run_lacks --standalone
  oc_run session list
  run_lacks --standalone
}

@test "opencode: --server is refused; a prompt that mentions it is not" {
  llm_serve qwen3-coder
  oc_run --server http://127.0.0.1:4000
  [[ $status -ne 0 && $output == *"--server is not supported"* ]]
  call_lacks "podman run"
  oc_run run "add --server support"
  [[ $status -eq 0 ]]
  run_lacks --server
}

# -------------------------------------------- opencode-box web search --------
# A full launch against the stubs: ensure_settings writes the config, box_run
# records what the box would be started with.
oc_run() {
  export OC_BOX_HOME="$BATS_TEST_TMPDIR/oc-home" OC_BOX_RUNTIME=crun \
    LOCAL_LLM_URL="file://$BATS_TEST_TMPDIR/llm/v1" LOCAL_LLM_API_KEY=sk-test
  run bash "$TOOLS/opencode-box" "$@"
}

# what the config pins web search to: {"provider":...} or false
oc_websearch() {
  python3 -c 'import json,os
print(json.dumps(json.load(open(os.path.join(os.environ["OC_BOX_HOME"],
  ".config/opencode/opencode.json"))).get("websearch")))'
}

@test "opencode search: --search names the provider, so 2.0 never asks" {
  llm_serve qwen3-coder
  TAVILY_API_KEY=tv oc_run --search --shell -c true
  [[ $status -eq 0 ]]
  [[ $(oc_websearch) == '{"provider": "tavily"}' ]]
  run_has --env TAVILY_API_KEY
}

@test "opencode search: a provider named once is undone by the next launch without it" {
  llm_serve qwen3-coder
  TAVILY_API_KEY=tv oc_run --search --shell -c true
  [[ $(oc_websearch) == '{"provider": "tavily"}' ]]
  oc_run --shell -c true
  [[ $(oc_websearch) == false ]]
}

@test "opencode search: without --search the tool is off, not offered" {
  llm_serve qwen3-coder
  TAVILY_API_KEY=tv oc_run --shell -c true
  [[ $status -eq 0 && $(oc_websearch) == false ]]
  run_lacks TAVILY_API_KEY
}

@test "opencode search: --search without a key is refused before anything runs" {
  llm_serve qwen3-coder
  TAVILY_API_KEY= oc_run --search --shell -c true
  [[ $status -ne 0 && $output == *"needs TAVILY_API_KEY"* ]]
}

# -------------------------------------------------------------------- wt -----
@test "wt: add, merge and rm under <parent>/<WT_DIR>/<project>/<slug>" {
  make_repo myproj
  echo "SECRET=1" >myproj/.env
  cd myproj
  local dir
  dir="$("${BOX_TEST_BASH:-bash}" "$TOOLS/wt" add feat/one)"
  [[ $dir == "$BATS_TEST_TMPDIR/worktrees/myproj/feat-one" ]]
  [[ -f "$dir/.env" && ! -L "$dir/.env" ]]
  # Running from inside the linked worktree resolves main_root and merges/removes cleanly.
  cd "$dir"
  [[ "$("${BOX_TEST_BASH:-bash}" "$TOOLS/wt" path -m)" == "$BATS_TEST_TMPDIR/myproj" ]]
  git_q commit --allow-empty -m "feat commit"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
    "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" merge --rebase
  cd "$BATS_TEST_TMPDIR/myproj"
  [[ ! -d "$dir" && ! -d "$BATS_TEST_TMPDIR/worktrees/myproj" ]]
  [[ "$(git log -1 --format=%s)" == "feat commit" ]]
  # WT_DIR overrides the sibling folder (e.g. agents).
  dir="$(WT_DIR=agents "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" add fix-two)"
  [[ $dir == "$BATS_TEST_TMPDIR/agents/myproj/fix-two" ]]
  WT_DIR=agents "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" rm fix-two
  [[ ! -d "$dir" ]]
}

@test "wt: -w moves uncommitted changes, ls shows status, rm prunes box data" {
  make_repo myproj
  cd myproj
  echo "wip" >untracked.txt
  local dir proj lock db
  dir="$("${BOX_TEST_BASH:-bash}" "$TOOLS/wt" add -w wip-branch)"
  [[ ! -e "$BATS_TEST_TMPDIR/myproj/untracked.txt" && -f "$dir/untracked.txt" ]]
  proj="$(basename "$dir")-$(printf '%s' "$dir" | cksum | cut -d' ' -f1)"
  lock="$XDG_RUNTIME_DIR/agentbox-locks/opencode-agentbox-default-$proj"
  db="$HOME/.opencode-box/.local/share/opencode/agentbox-default-$proj.db"
  mkdir -p "$lock" "$(dirname "$db")"
  echo $$ >"$lock/pid"
  touch "$db"
  local ls_out
  ls_out="$("${BOX_TEST_BASH:-bash}" "$TOOLS/wt" ls)"
  [[ $ls_out == *"(dirty,running)"* ]]
  "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" rm -f wip-branch
  [[ ! -d "$dir" && ! -e "$db" && ! -d "$lock" ]]
}

@test "wt: ocr --pr fetches PR into worktree and runs ocr-box review against main" {
  make_repo origin_repo
  git clone -q "$BATS_TEST_TMPDIR/origin_repo" myproj
  # Simulate refs/pull/42/head on origin
  git_q -C origin_repo checkout -b pr-src
  echo "change" >origin_repo/file.txt
  git -C origin_repo add file.txt
  git_q -C origin_repo commit -m "pr change"
  git -C origin_repo update-ref refs/pull/42/head HEAD

  llm_serve qwen3-coder
  export OCR_BOX_HOME="$BATS_TEST_TMPDIR/ocr-home" OCR_BOX_RUNTIME=crun \
    LOCAL_LLM_URL="file://$BATS_TEST_TMPDIR/llm/v1" LOCAL_LLM_API_KEY=sk-test
  cd myproj
  local mb cd_file="$BATS_TEST_TMPDIR/cd_target"
  mb="$(git branch --show-current)"
  WT_CD_FILE="$cd_file" run "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" ocr --pr 42
  [[ $status -eq 0 ]]
  local pr_dir="$BATS_TEST_TMPDIR/worktrees/myproj/pr-42"
  [[ -f "$pr_dir/file.txt" && "$(cat "$cd_file")" == "$pr_dir" ]]
  run_has --workdir "$pr_dir"
  run_has review --from
  run_has --from "$mb"
  run_has --to HEAD
  # wt init works outside a git repo (e.g. from config.fish at shell startup)
  cd "$BATS_TEST_TMPDIR"
  run "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" init fish
  [[ $status -eq 0 && $output == *"function wt"* ]]
}


