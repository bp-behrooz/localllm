# Shared by the tests: the stubs in stubs/ stand in for podman, Apple's
# container and uname, so the boxes run on any host and in CI without a VM.
TOOLS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"
  export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$FAKE_DIR"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  as_linux
  # Nothing from the host's own setup: no git identity, no box knobs.
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  local v
  for v in $(compgen -v | grep '^CL_BOX_'); do unset "$v"; done
  unset SSH_AUTH_SOCK
  cd "$BATS_TEST_TMPDIR" || return
}

as_linux() { export FAKE_UNAME_S=Linux FAKE_UNAME_R=6.12.0-arch1-1; }
as_wsl() { export FAKE_UNAME_S=Linux FAKE_UNAME_R=6.6.87.2-microsoft-standard-WSL2; }
as_mac() { export FAKE_UNAME_S=Darwin FAKE_UNAME_R=25.0.0; }

# Source the lib as claude-box does, for testing its functions one by one.
load_lib() {
  BOX_IMAGE=claude-box
  BOX_NAME_PREFIX=cl
  BOX_ENV_PREFIX=CL_BOX
  BOX_HOME="$HOME/.claude-box"
  BOX_KEEP=(.claude)
  # shellcheck source=../agent-box-lib.bash
  source "$TOOLS/agent-box-lib.bash"
}

# claude-box against the stubs; what it passed to `run` is in run.args.
# BOX_TEST_BASH picks the bash it runs under, e.g. macOS's own /bin/bash 3.2.
run_box() {
  run "${BOX_TEST_BASH:-bash}" "$TOOLS/claude-box" "$@"
}

# run_has ARG [NEXT]: `run` got ARG (followed by NEXT).
run_has() {
  if [[ $# -eq 1 ]]; then
    grep -qxF -- "$1" "$FAKE_DIR/run.args"
  else
    awk -v a="$1" -v b="$2" 'p == a && $0 == b { f = 1 } { p = $0 } END { exit !f }' \
      "$FAKE_DIR/run.args"
  fi
}

# run_lacks ARG: `run` didn't get ARG. (A bare `! run_has` can't fail a test:
# set -e ignores negated commands.)
run_lacks() {
  ! grep -qxF -- "$1" "$FAKE_DIR/run.args"
}

git_q() { git -c user.name=t -c user.email=t@example.com "$@" -q; }

# A repo at $1 with one commit.
make_repo() {
  git init -q "$1"
  git_q -C "$1" commit --allow-empty -m init
}
