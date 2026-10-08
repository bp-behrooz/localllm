#!/usr/bin/env bats
# A real box under rootless podman, with crun (CI runners have no krun).
# Building the image takes minutes, so it only runs when asked:
#
#   BOX_IT=1 bats tools/tests/integration.bats
#
# Uses your own podman storage; the box's home is a throwaway.

TOOLS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup_file() {
  [[ ${BOX_IT:-} == 1 ]] || skip "set BOX_IT=1 to build and run a real box"
  export CL_BOX_RUNTIME=crun CL_BOX_CPUS=2 CL_BOX_MEMORY=2G
  export CL_BOX_HOME="$BATS_FILE_TMPDIR/box-home"
  bash "$TOOLS/claude-box" --build-only
}

setup() {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global user.name "Box Test"
  git config --global user.email box@example.com
  cd "$BATS_TEST_TMPDIR" || return
}

# box CMD: bash -c CMD in a fresh box at $PWD.
box() {
  run bash "$TOOLS/claude-box" --shell -c "$1" </dev/null
  echo "$output"
}

make_repo() {
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

@test "the agent is installed" {
  box 'claude --version'
  [[ $status -eq 0 && $output == *"Claude Code"* ]]
}

@test "the project is at its own path" {
  box 'pwd'
  [[ $status -eq 0 && $output == *"$PWD"* ]]
}

@test "git works in a plain repo" {
  make_repo main
  cd main
  box 'git log -1 --format=%s'
  [[ $status -eq 0 && $output == *init* ]]
}

@test "git works in a worktree, and its commits land in the main repo" {
  make_repo main
  git -C main worktree add -q -b foo ../agents/foo
  cd agents/foo
  box 'echo hi >f && git add f && git commit -qm "from the box" && git log -1 --format="%an: %s"'
  [[ $status -eq 0 && $output == *"Box Test: from the box"* ]]
  [[ $(git -C ../../main log -1 --format=%s foo) == "from the box" ]]
}
