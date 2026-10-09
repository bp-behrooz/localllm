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
