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

@test "runtime: krun preloads the port-0 fix, or says to rebuild for it" {
  load_lib
  BOX_CTR=(podman) BOX_RUN_ARGS=()
  _box_runtime_args 2>/dev/null
  [[ " ${BOX_RUN_ARGS[*]} " == *" --env LD_PRELOAD=/usr/local/lib/box-bind0.so "* ]]
  BOX_RUN_ARGS=()
  CL_BOX_RUNTIME=crun
  _box_runtime_args 2>/dev/null
  [[ ${BOX_RUN_ARGS[*]} != *LD_PRELOAD* ]]
  BOX_RUN_ARGS=()
  CL_BOX_RUNTIME=krun
  FAKE_BIND0= run _box_runtime_args
  [[ $output == *"predates the port-0 fix"* ]]
}

@test "image: every image builds the port-0 fix, labeled with its checksum" {
  load_lib
  run box_dockerfile_base
  [[ $output == *"cc -shared -fPIC -O2 -o /usr/local/lib/box-bind0.so"* ]]
  [[ $output == *"LABEL agent-box.bind0=$(_box_bind0_stamp)"* ]]
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

@test "git: a multi-repo workspace mounts each repo's .git" {
  make_repo main1
  make_repo main2
  git_q -C main1 worktree add -b foo ../ws/main1
  git_q -C main2 worktree add -b foo ../ws/main2
  cd ws
  load_lib
  BOX_RUN_ARGS=()
  _box_git_dir_volume 2>/dev/null
  local g1 g2
  g1="$(cd ../main1/.git && pwd -P)"
  g2="$(cd ../main2/.git && pwd -P)"
  [[ ${BOX_RUN_ARGS[*]} == "--volume $g1:$g1 --volume $g2:$g2" ]]
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

@test "flags: --host-port PORT and --host-port=PORT" {
  load_lib
  box_parse_args --host-port 1234
  [[ ${BOX_ARGS[*]} == "" && ${BOX_HOST_PORTS[*]} == 1234 ]]
  box_parse_args --host-port=1234
  [[ ${BOX_HOST_PORTS[*]} == 1234 ]]
}

@test "flags: bad --host-port ports are refused" {
  load_lib
  local bad
  for bad in nope 0 99999 5432,x ""; do
    run box_parse_args --host-port "$bad"
    [[ $status -ne 0 && $output == *"--host-port"* ]]
  done
  run box_parse_args --host-port
  [[ $status -ne 0 && $output == *"requires a port"* ]]
}

@test "flags: repeated and comma-separated --host-port, without repeats" {
  load_lib
  box_parse_args --host-port=5432 --host-port=6379,05432
  [[ ${BOX_HOST_PORTS[*]} == "5432 6379" ]]
}

@test "flags: the HOST_PORT knob, and the flag over it" {
  load_lib
  CL_BOX_HOST_PORT=5432,6379
  box_parse_args
  [[ ${BOX_HOST_PORTS[*]} == "5432 6379" ]]
  box_parse_args --host-port 7000
  [[ ${BOX_HOST_PORTS[*]} == 7000 ]]
  CL_BOX_HOST_PORT=nope
  run box_parse_args
  [[ $status -ne 0 && $output == *"CL_BOX_HOST_PORT 'nope'"* ]]
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
  run_has --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
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

@test "profile hooks: a launch port is this launch's own, forwarded and passed in" {
  export CL_BOX_RUNTIME=crun
  printf 'BOX_LAUNCH_PORT=PGPORT,REDIS_PORT\nexport URL=pg://127.0.0.1:$PGPORT\n' >"$HOME/.box.db.env"
  printf 'echo "$PGPORT $REDIS_PORT $URL" >"%s/up.saw"\n' "$FAKE_DIR" >"$HOME/.box.db.up"
  run_box --profile db --shell -c true
  [[ $status -eq 0 ]]
  local pg redis url
  read -r pg redis url <"$FAKE_DIR/up.saw"
  [[ $pg != "$redis" && $url == "pg://127.0.0.1:$pg" ]]
  ((pg >= 24100 && pg < 24200 && redis >= 24100 && redis < 24200))
  run_has --network "pasta:-T,$pg,-T,$redis"
  run_has --env PGPORT
  run_has --env REDIS_PORT
  run_has --env URL
  run grep -q BOX_LAUNCH_PORT "$FAKE_DIR/run.args"
  [[ $status -ne 0 ]]
}

@test "profile hooks: a launch port names a variable" {
  as_mac
  printf 'BOX_LAUNCH_PORT=6432\n' >"$HOME/.box.db.env"
  run_box --profile db --shell -c true
  [[ $status -ne 0 && $output == *"BOX_LAUNCH_PORT '6432': not a variable name"* ]]
}

@test "profile hooks: up before the box, down after, sharing a private dir" {
  as_mac
  printf 'export DB_NAME=bestplay\n' >"$HOME/.box.db.env"
  cat >"$HOME/.box.db.up" <<EOF
[ -e "$FAKE_DIR/run.args" ] && echo late >"$FAKE_DIR/up.late"
echo "\$DB_NAME" >"\$BOX_HOOK_DIR/state"
echo "\$BOX_HOOK_DIR" >"$FAKE_DIR/hook.dir"
echo up-to-stdout
EOF
  cat >"$HOME/.box.db.down" <<EOF
[ -e "$FAKE_DIR/run.args" ] && cat "\$BOX_HOOK_DIR/state" >"$FAKE_DIR/down.saw"
EOF
  run_box --profile db --shell -c true
  [[ $status -eq 0 && $output == *up-to-stdout* ]]
  [[ ! -e $FAKE_DIR/up.late ]]
  [[ $(cat "$FAKE_DIR/down.saw") == bestplay ]]
  [[ ! -e "$(cat "$FAKE_DIR/hook.dir")" ]]
}

@test "profile hooks: a failing up stops the launch, and down still runs" {
  as_mac
  printf 'exit 3\n' >"$HOME/.box.db.up"
  printf 'touch "%s/down.ran"\n' "$FAKE_DIR" >"$HOME/.box.db.down"
  run_box --profile db --shell -c true
  [[ $status -ne 0 && $output == *"profile db: "*".box.db.up failed"* ]]
  [[ ! -e $FAKE_DIR/run.args && -e $FAKE_DIR/down.ran ]]
}

@test "profile hooks: a failing down warns, and keeps the launch's status" {
  as_mac
  printf 'exit 3\n' >"$HOME/.box.db.down"
  run_box --profile db --shell -c true
  [[ $status -eq 0 && $output == *"warning: profile db: "*".box.db.down failed"* ]]
}

@test "profile hooks: an empty launch port is refused, not ignored" {
  as_mac
  printf 'BOX_LAUNCH_PORT=\n' >"$HOME/.box.db.env"
  BOX_TEST_BASH=/bin/bash run_box --profile db --shell -c true
  [[ $status -ne 0 && $output == *"BOX_LAUNCH_PORT is empty"* ]]
}

@test "profile hooks: the named profile's down runs before default's" {
  as_mac
  local p
  for p in default db; do
    printf 'echo %s >>"%s/downs"\n' "$p" "$FAKE_DIR" >"$HOME/.box.$p.down"
  done
  run_box --profile db --shell -c true
  [[ $status -eq 0 && $(paste -sd, "$FAKE_DIR/downs") == db,default ]]
}

@test "box: refuses rootful podman" {
  export CL_BOX_RUNTIME=crun FAKE_ROOTLESS=false
  run_box --shell -c true
  [[ $status -ne 0 && $output == *"not rootless"* ]]
}

# this host's socat/netstat stand-ins. socat says what it would serve, warns on
# stderr as the real one does, and stays up a moment; unless FAKE_SOCAT_DEAD is
# set, it notes the port it listens on. netstat lists those, and $FAKE_LISTEN
# ("addr.port" words), the way macOS does.
fake_mac_tools() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/socat" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_DIR/socat.calls"
case $1 in TCP-LISTEN:*)
  l=${1#TCP-LISTEN:}
  [ -n "${FAKE_SOCAT_DEAD-}" ] || echo "192.168.64.1.${l%%,*}" >>"$FAKE_DIR/listening" ;;
esac
echo "socat W refusing connection due to range option" >&2
[ -n "${FAKE_SOCAT_DEAD-}" ] || sleep 3
EOF
  cat >"$BATS_TEST_TMPDIR/bin/netstat" <<'EOF'
#!/bin/sh
for a in $FAKE_LISTEN $(cat "$FAKE_DIR/listening" 2>/dev/null); do
  echo "tcp4       0      0  $a      *.*      LISTEN"
done
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# a Unix socket at $1, as an ssh-agent or Docker would leave
make_sock() {
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
}

@test "host-port: only the listed ports are forwarded, under krun and crun" {
  load_lib
  BOX_RUN_ARGS=()
  BOX_HOST_PORTS=(5432 6379)
  _box_runtime_args
  run _box_host_port_args
  [[ $output == *"127.0.0.1:5432,6379 forwarded to the host (only those)"* ]]
  _box_host_port_args 2>/dev/null
  _box_forward_args
  [[ " ${BOX_RUN_ARGS[*]} " == *" --network pasta:-T,5432,-T,6379 "* ]]
  [[ ${BOX_RUN_ARGS[*]} != *map-host-loopback* ]]
  as_wsl
  load_lib
  BOX_RUN_ARGS=()
  BOX_PASTA_FWD=()
  _box_runtime_args
  _box_host_port_args 2>/dev/null
  _box_forward_args
  [[ " ${BOX_RUN_ARGS[*]} " == *" --network pasta:-T,5432,-T,6379 "* ]]
}

@test "host-port: a whole launch passes just the port forwards" {
  export CL_BOX_RUNTIME=crun
  run_box --host-port=5432,6379 --shell -c true
  [[ $status -eq 0 ]]
  run_has --network pasta:-T,5432,-T,6379
  run grep -q map-host-loopback "$FAKE_DIR/run.args"
  [[ $status -ne 0 ]]
}

@test "bridges: a free port is one nothing answers on and no live launch reserved" {
  load_lib
  # four ports: the first listened on, the second reserved by a live launch,
  # the third by one that is gone
  python3 -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen()
print(s.getsockname()[1], flush=True); time.sleep(30)' >"$BATS_TEST_TMPDIR/port" &
  local listener=$!
  until [[ -s "$BATS_TEST_TMPDIR/port" ]]; do sleep 0.05; done
  local busy ports="$XDG_STATE_HOME/agent-box/ports"
  busy="$(cat "$BATS_TEST_TMPDIR/port")"
  BOX_BRIDGE_PORTS=("$busy" 4)
  sleep 30 &
  local alive=$!
  mkdir -p "$ports/$((busy + 1))" "$ports/$((busy + 2))"
  echo "$alive" >"$ports/$((busy + 1))/pid"
  echo 4999999 >"$ports/$((busy + 2))/pid"
  local got=()
  _box_free_port 127.0.0.1
  got+=("$BOX_FREE_PORT")
  _box_free_port 127.0.0.1
  got+=("$BOX_FREE_PORT")
  # in either order, by the random start
  [[ " ${got[*]} " == *" $((busy + 2)) "* && " ${got[*]} " == *" $((busy + 3)) "* ]]
  [[ $(cat "$ports/$((busy + 2))/pid") == $$ && $(cat "$ports/$((busy + 3))/pid") == $$ ]]
  [[ $(cat "$ports/$((busy + 1))/pid") == "$alive" ]]
  run _box_free_port 127.0.0.1
  [[ $status -ne 0 && $output == *"no free port"* ]]
  kill "$listener" "$alive"
}

@test "bridges: a Mac asks netstat what listens, and never probes the gateway" {
  as_mac
  fake_mac_tools
  load_lib
  # here 192.168.64.1 may be a real host: a probe would hang for minutes
  export FAKE_LISTEN="192.168.64.1.24100 *.24101 127.0.0.1.24102"
  BOX_BRIDGE_PORTS=(24100 4)
  _box_free_port 192.168.64.1
  [[ $BOX_FREE_PORT == 24103 ]]
  # now this launch's
  run _box_free_port 192.168.64.1
  [[ $status -ne 0 && $output == *"no free port"* ]]
}

@test "bridges: under krun, --ssh and --docker are port forwards too, beside --host-port" {
  fake_mac_tools # only for its socat
  make_sock "$BATS_TEST_TMPDIR/agent.sock"
  make_sock "$BATS_TEST_TMPDIR/docker.sock"
  load_lib
  SSH_AUTH_SOCK="$BATS_TEST_TMPDIR/agent.sock"
  CL_BOX_SSH=1 CL_BOX_DOCKER=1 CL_BOX_DOCKER_SOCK="$BATS_TEST_TMPDIR/docker.sock"
  BOX_HOST_PORTS=(5432)
  box_docker_bridge 2>/dev/null
  local docker=$BOX_BRIDGE_PORT
  box_run_args 2>/dev/null
  local ssh=$BOX_BRIDGE_PORT
  [[ $docker != "$ssh" ]]
  [[ " ${BOX_RUN_ARGS[*]} " == *" DOCKER_HOST=tcp://127.0.0.1:$docker "* ]]
  [[ " ${BOX_RUN_ARGS[*]} " == *" BOX_SSH_AGENT_TCP=127.0.0.1:$ssh "* ]]
  [[ " ${BOX_RUN_ARGS[*]} " == *" --network pasta:-T,$docker,-T,5432,-T,$ssh "* ]]
  [[ $(grep -o -- --network <<<"${BOX_RUN_ARGS[*]}" | wc -l) -eq 1 ]]
  [[ ${BOX_RUN_ARGS[*]} != *map-host-loopback* && ${BOX_RUN_ARGS[*]} != *169.254* ]]
}

@test "bridges: a Mac serves --docker and --host-port on the gateway, to this box alone" {
  as_mac
  fake_mac_tools
  make_sock "$BATS_TEST_TMPDIR/docker.sock"
  export CL_BOX_DOCKER_SOCK="$BATS_TEST_TMPDIR/docker.sock" FAKE_BOX_IP=192.168.64.31
  FAKE_RUN_SLEEP=3 run_box --docker --host-port=5432,6379 --shell -c true
  [[ $status -eq 0 ]]
  [[ $output == *"127.0.0.1:5432,6379 forwarded to the Mac (only those, only this box)"* ]]
  [[ $output != *"nothing listens"* ]]
  local docker pg redis
  docker="$(sed -n 's#^DOCKER_HOST=tcp://192.168.64.1:##p' "$FAKE_DIR/run.args")"
  pg="$(sed -n 's#^BOX_HOST_PORTS=5432:\([0-9]*\) .*#\1#p' "$FAKE_DIR/run.args")"
  redis="$(sed -n 's#^BOX_HOST_PORTS=.* 6379:##p' "$FAKE_DIR/run.args")"
  [[ -n $docker && -n $pg && -n $redis ]]
  [[ $(printf '%s\n' "$docker" "$pg" "$redis" | sort -u | wc -l) -eq 3 ]]
  run_has --env BOX_HOST_GATEWAY=192.168.64.1
  local only="bind=192.168.64.1,reuseaddr,fork,range=192.168.64.31/32"
  grep -qxF "TCP-LISTEN:$docker,$only UNIX-CONNECT:$CL_BOX_DOCKER_SOCK" "$FAKE_DIR/socat.calls"
  grep -qxF "TCP-LISTEN:$pg,$only TCP:127.0.0.1:5432" "$FAKE_DIR/socat.calls"
  grep -qxF "TCP-LISTEN:$redis,$only TCP:127.0.0.1:6379" "$FAKE_DIR/socat.calls"
  # socat's warnings go to this launch's log, not the agent's screen
  [[ $output != *refusing* ]]
  [[ $(cat "$XDG_STATE_HOME"/agent-box/socat-*.log | grep -c refusing) -eq 3 ]]
  run grep -q 'sudo\|dns create\|pfctl' "$FAKE_DIR/calls"
  [[ $status -ne 0 ]]
}

@test "bridges: a Mac says so on the terminal when a forward doesn't listen" {
  as_mac
  fake_mac_tools
  export FAKE_SOCAT_DEAD=1
  FAKE_RUN_SLEEP=3 run_box --host-port=5432 --shell -c true
  [[ $status -eq 0 ]]
  local pg
  pg="$(sed -n 's#^BOX_HOST_PORTS=5432:##p' "$FAKE_DIR/run.args")"
  [[ $output == *"warning: nothing listens on 192.168.64.1:$pg for TCP:127.0.0.1:5432; see "*"/agent-box/socat-"* ]]
}

@test "logs: each launch's is capped, and only the newest are kept" {
  load_lib
  BOX_LOG_MAX=300 BOX_LOGS_KEPT=3
  mkdir -p "$XDG_STATE_HOME/agent-box"
  local i
  # older the higher i, and older than any clock; touch -t, as BSD touch has no
  # -d "-1 hour"
  for i in 1 2 3 4 5; do
    touch -t "20000101$(printf '%02d' $((10 - i)))00" "$XDG_STATE_HOME/agent-box/socat-old$i.log"
  done
  for i in $(seq 1 50); do echo "socat W refusing connection number $i"; done | _box_socat_to
  local log
  log="$(_box_socat_log)"
  [[ $(wc -c <"$log") -le 350 && $(tail -1 "$log") == "(log capped at 300 bytes; the rest dropped)" ]]
  [[ $(grep -c '^(log capped' "$log") -eq 1 ]]
  [[ $(ls "$XDG_STATE_HOME"/agent-box/socat-*.log | wc -l) -eq 3 ]]
  [[ -e $log && -e "$XDG_STATE_HOME/agent-box/socat-old1.log" && ! -e "$XDG_STATE_HOME/agent-box/socat-old3.log" ]]
}

@test "bridges: a Mac forwards nothing to a box that never shows an IP" {
  as_mac
  fake_mac_tools
  load_lib
  container() { :; }
  sleep() { :; }
  BOX_MAC_FWD=("24100 TCP:127.0.0.1:5432")
  # the watcher is disowned, so `wait` can't: poll for its warning instead,
  # then give any socat it wrongly started a moment (sleep is stubbed)
  _box_mac_forwards cl-nope-1 2>"$BATS_TEST_TMPDIR/err"
  local i
  for ((i = 0; i < 100; i++)); do
    grep -q "cl-nope-1 showed no IP" "$BATS_TEST_TMPDIR/err" && break
    command sleep 0.1
  done
  command sleep 0.5
  [[ ! -e "$FAKE_DIR/socat.calls" ]]
  grep -q "cl-nope-1 showed no IP" "$BATS_TEST_TMPDIR/err"
}

@test "bridges: a Mac launch's exit kills every forward the watcher started" {
  as_mac
  fake_mac_tools
  load_lib
  container() { echo "cl-x-1  box  linux  arm64  running  192.168.64.31/24  4  4096 MB  now"; }
  BOX_MAC_FWD=("24100 TCP:127.0.0.1:5432" "24101 TCP:127.0.0.1:6379")
  _box_mac_forwards cl-x-1 2>/dev/null
  until [[ $(cat "$FAKE_DIR/socat.calls" 2>/dev/null | wc -l) -eq 2 ]]; do sleep 0.05; done
  _box_run_at_exit
  run pgrep -f "$BATS_TEST_TMPDIR/bin/socat"
  [[ $status -ne 0 ]]
}

@test "host-port: a Mac image without the relay is told to rebuild" {
  as_mac
  FAKE_ENTRY=6 run_box --host-port 5432 --shell -c true
  [[ $status -ne 0 && $output == *"rerun with --build-only"* ]]
}

# An older --docker's pf route to all of Mac loopback, up this boot; sudo only
# says what it'd run
alias_up() {
  as_mac
  load_lib
  sudo() { echo "sudo $*" >>"$FAKE_DIR/sudo.calls"; }
  _box_boot_time() { echo 1234; }
  mkdir -p "$(dirname "$(_box_alias_stamp)")"
  echo 1234 >"$(_box_alias_stamp)"
}

@test "old alias: a Mac with the old route up takes it down on yes" {
  alias_up
  local answer
  for answer in y ""; do
    echo 1234 >"$(_box_alias_stamp)"
    : >"$FAKE_DIR/sudo.calls"
    BOX_TTY=<(echo "$answer") run _box_old_alias_down
    [[ $status -eq 0 && $output == *"any"*"box can reach every Mac loopback port"*"taken down"* ]]
    [[ $(cat "$FAKE_DIR/sudo.calls") == "sudo /sbin/pfctl -a com.apple/container -F nat
sudo container system dns delete host.container.internal" ]]
    grep -qx 'container system stop' "$FAKE_DIR/calls" && grep -qx 'container system start' "$FAKE_DIR/calls"
    [[ ! -e "$(_box_alias_stamp)" ]]
  done
}

@test "old alias: a Mac with the old route up stops on no, or with no terminal" {
  alias_up
  BOX_TTY=<(echo n) run _box_old_alias_down
  [[ $status -ne 0 && $output == *"not starting with host.container.internal open"* ]]
  BOX_TTY=/nonexistent/tty run _box_old_alias_down
  [[ $status -ne 0 && $output == *"sudo /sbin/pfctl -a com.apple/container -F nat"* ]]
  [[ ! -e "$FAKE_DIR/sudo.calls" && -e "$(_box_alias_stamp)" ]]
}

@test "old alias: a Mac with the old route up goes ahead on c" {
  alias_up
  BOX_TTY=<(echo c) run _box_old_alias_down
  [[ $status -eq 0 && $output == *"continuing with host.container.internal open"* ]]
  [[ ! -e "$FAKE_DIR/sudo.calls" && -e "$(_box_alias_stamp)" ]]
}

@test "old alias: asked before the build on any Mac launch, not for --build-only" {
  alias_up
  BOX_TTY=<(echo n) run box_require_runtime
  [[ $status -ne 0 && $output == *"An older --docker set up"* ]]
  BUILD_ONLY=1 BOX_TTY=/nonexistent/tty run box_require_runtime
  [[ $status -eq 0 && $output != *"An older"* ]]
}

@test "old alias: no question when it isn't up, or on podman" {
  alias_up
  echo 999 >"$(_box_alias_stamp)"
  BOX_TTY=/nonexistent/tty run _box_old_alias_down
  [[ $status -eq 0 && -z $output ]]
  as_linux
  load_lib
  _box_boot_time() { echo 1234; }
  echo 1234 >"$(_box_alias_stamp)"
  BOX_TTY=/nonexistent/tty run _box_old_alias_down
  [[ $status -eq 0 && -z $output ]]
}

@test "host-port: no network flag without it or a bridge" {
  load_lib
  BOX_RUN_ARGS=()
  BOX_HOST_PORTS=()
  _box_runtime_args
  _box_host_port_args
  _box_forward_args
  [[ ${BOX_RUN_ARGS[*]:-} != *"--network"* ]]
}

# ---------------------------------------------------------------- version ----
# The registry lookup runs in the background and feeds the next launch, so
# each test launches twice.
@test "version: warns when a profile's image is behind, naming the profile" {
  export CL_BOX_RUNTIME=crun FAKE_AGENT_VERSION=2.1.0 FAKE_NPM_VERSION=2.1.5
  echo 'RUN true' >"$HOME/.box.data.dockerfile"
  touch "$HOME/.box.data.env"
  run_box --profile=data --shell -c true
  wait_for_file "$XDG_STATE_HOME/agent-box/npm-@anthropic-ai_claude-code@latest"
  run_box --profile=data --shell -c true
  [[ $status -eq 0 ]]
  [[ $output == *"claude-box-data has @anthropic-ai/claude-code 2.1.0, latest is 2.1.5"* ]]
  [[ $output == *"claude-box --profile=data --rebuild"* ]]
}

@test "version: quiet when current, offline, or right after --rebuild" {
  export CL_BOX_RUNTIME=crun FAKE_AGENT_VERSION=2.1.5 FAKE_NPM_VERSION=2.1.5
  run_box --shell -c true
  wait_for_file "$XDG_STATE_HOME/agent-box/npm-@anthropic-ai_claude-code@latest"
  run_box --shell -c true
  [[ $status -eq 0 && $output != *"--rebuild"* ]]
  rm -rf "$XDG_STATE_HOME/agent-box"
  unset FAKE_NPM_VERSION
  run_box --shell -c true
  run_box --shell -c true
  [[ $status -eq 0 && $output != *"--rebuild"* ]]
  FAKE_AGENT_VERSION=2.1.0 FAKE_NPM_VERSION=2.1.5 run_box --rebuild --build-only
  [[ $status -eq 0 && $output != *"has @anthropic-ai"* ]]
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

# ----------------------------------------------------------- pi-box quiet ----
pi_run() {
  export PI_BOX_HOME="$BATS_TEST_TMPDIR/pi-home" PI_BOX_RUNTIME=crun \
    LOCAL_LLM_URL="file://$BATS_TEST_TMPDIR/llm/v1" LOCAL_LLM_API_KEY=sk-test
  run bash "$TOOLS/pi-box" --no-proxy "$@"
}

# the packages settings.json lists, one per line
pi_packages() {
  python3 -c 'import json,os
s = json.load(open(os.path.join(os.environ["PI_BOX_HOME"], ".pi/agent/settings.json")))
print("\n".join(s["packages"]))'
}

@test "pi quiet: offline, with packages from the image" {
  llm_serve qwen3-coder
  pi_run --shell -c true
  [[ $status -eq 0 ]]
  run_has --env PI_OFFLINE=1
  [[ $(pi_packages) == "/opt/pi-packages/node_modules/@dietrichgebert/ponytail
/opt/pi-packages/node_modules/pi-hide-providers" ]]
  TAVILY_API_KEY=tv pi_run --search --shell -c true
  [[ $(pi_packages) == *$'\n'/opt/pi-packages/node_modules/@tavily/pi-extension ]]
}

@test "pi quiet: an older home's package sources move to the image's copies" {
  mkdir -p "$BATS_TEST_TMPDIR/pi-home/.pi/agent"
  echo '{"packages": ["git:github.com/DietrichGebert/ponytail", "npm:pi-hide-providers",
    "npm:@tavily/pi-extension", "npm:something-else"]}' \
    >"$BATS_TEST_TMPDIR/pi-home/.pi/agent/settings.json"
  echo '{}' >"$BATS_TEST_TMPDIR/pi-home/.pi/agent/models.json"
  pi_run --shell -c true
  [[ $status -eq 0 ]]
  [[ $(pi_packages) == "/opt/pi-packages/node_modules/@dietrichgebert/ponytail
/opt/pi-packages/node_modules/pi-hide-providers
npm:something-else" ]]
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
assert "model" not in cfg, "a pin here would outrank the recent models"
assert cfg["plugin"] == ["/opt/opencode-plugins/node_modules/@dietrichgebert/ponytail/.opencode/plugins/ponytail.mjs"]'
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
  run bash "$TOOLS/opencode-box" --no-proxy "$@"
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

@test "opencode plugins: migrate npm references, preserve other plugins and removals" {
  llm_serve qwen3-coder
  oc_sync
  local cfg="$OC_BOX_HOME/.config/opencode/opencode.json"
  echo '{"plugin":["@dietrichgebert/ponytail","other-plugin"]}' >"$cfg"
  oc_run --shell -c true
  [[ $status -eq 0 ]]
  python3 - "$cfg" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
assert cfg["plugin"] == ["/opt/opencode-plugins/node_modules/@dietrichgebert/ponytail/.opencode/plugins/ponytail.mjs", "other-plugin"]
PY
  echo '{"plugin":[]}' >"$cfg"
  oc_run --shell -c true
  [[ $status -eq 0 ]]
  python3 - "$cfg" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))["plugin"] == []
PY
  echo '{}' >"$cfg"
  oc_run --shell -c true
  [[ $status -eq 0 ]]
  python3 - "$cfg" <<'PY'
import json, sys
assert "plugin" not in json.load(open(sys.argv[1]))
PY
}

@test "opencode plugins: an older image rebuilds with Ponytail baked in" {
  llm_serve qwen3-coder
  FAKE_OC_PLUGINS=0 oc_run --shell -c true
  [[ $status -eq 0 && $output == *"predates the baked-in OpenCode plugins"* ]]
  call_has "podman build"
  grep -q 'npm install --prefix /opt/opencode-plugins --omit=dev --legacy-peer-deps' "$FAKE_DIR/Dockerfile"
  grep -q '@dietrichgebert/ponytail' "$FAKE_DIR/Dockerfile"
  grep -qx 'LABEL opencode-box.plugins=1' "$FAKE_DIR/Dockerfile"
  grep -q 'test -f "/opt/opencode-plugins/node_modules/@dietrichgebert/ponytail/.opencode/plugins/ponytail.mjs"' "$FAKE_DIR/Dockerfile"
}

@test "opencode quiet: no catalog fetch, update check or LSP downloads" {
  llm_serve qwen3-coder
  oc_run --shell -c true
  [[ $status -eq 0 ]]
  run_has --env OPENCODE_DISABLE_MODELS_FETCH=1
  run_has --env OPENCODE_DISABLE_AUTOUPDATE=1
  run_has --env OPENCODE_DISABLE_LSP_DOWNLOAD=1
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
  export OCR_BOX_HOME="$BATS_TEST_TMPDIR/ocr-home" OCR_BOX_RUNTIME=crun OCR_BOX_PROXY=0 \
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

@test "wt: -g groups by branch, ls works from the feature root, --repos hits each repo" {
  make_repo alpha
  make_repo beta
  local dir
  dir="$(cd alpha && "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" add -g shared)"
  [[ $dir == "$BATS_TEST_TMPDIR/worktrees/shared/alpha" ]]
  (cd beta && "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" add -g shared)
  # resolution finds the grouped worktree even though the default layout is <repo>/<branch>
  [[ "$(cd alpha && "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" path shared)" == "$dir" ]]
  # ls at the feature root (no repo) lists every repo's worktree
  cd "$BATS_TEST_TMPDIR/worktrees/shared"
  run "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" ls
  [[ $status -eq 0 && $output == *"shared/alpha"* && $output == *"shared/beta"* ]]
  cd "$BATS_TEST_TMPDIR"
  git_q -C "$dir" commit --allow-empty -m "alpha change"
  git_q -C "$BATS_TEST_TMPDIR/worktrees/shared/beta" commit --allow-empty -m "beta change"
  (cd "$BATS_TEST_TMPDIR/worktrees/shared" && "${BOX_TEST_BASH:-bash}" "$TOOLS/wt" merge --repos)
  [[ "$(git -C alpha log -1 --format=%s)" == "alpha change" ]]
  [[ "$(git -C beta log -1 --format=%s)" == "beta change" ]]
  [[ ! -d "$BATS_TEST_TMPDIR/worktrees/shared" ]]
}

# a secret-tool that keeps each secret in a file named after its account
fake_secret_tool() {
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FAKE_DIR/secrets"
  cat >"$BATS_TEST_TMPDIR/bin/secret-tool" <<'EOF'
#!/bin/bash
f="$FAKE_DIR/secrets/$(printf %s "${!#}" | tr / _)"
case $1 in
  store) cat >"$f" ;;
  lookup) [ -f "$f" ] && cat "$f" ;;
  clear) rm "$f" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/secret-tool"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "box-secret: set, get in \$(...), show, remove" {
  fake_secret_tool
  run "$TOOLS/box-secret" set db <<<"s3cret"
  [[ $status -eq 0 && $output == "stored db" ]]
  [[ $("$TOOLS/box-secret" get db) == s3cret ]]
  run "$TOOLS/box-secret" show db
  [[ $output == "db is set" ]]
  run "$TOOLS/box-secret" remove db
  [[ $output == "removed db" ]]
  run "$TOOLS/box-secret" get db
  [[ $status -ne 0 && $output == *"box-secret set db"* ]]
}

@test "box-secret: get won't print to a terminal" {
  command -v script >/dev/null || skip "no script(1)"
  fake_secret_tool
  printf s3cret >"$FAKE_DIR/secrets/db"
  # a terminal on stdout: util-linux script takes -c CMD, BSD/macOS's takes
  # CMD after the file (uname is stubbed here, so ask script which it is)
  if script --version >/dev/null 2>&1; then
    run script -qec "'$TOOLS/box-secret' get db" /dev/null
  else
    run script -q /dev/null "$TOOLS/box-secret" get db
  fi
  [[ $output == *"not printing db to a terminal"* && $output != *s3cret* ]]
}

@test "box-secret: keeps spaces at either end, and a last line without a newline" {
  fake_secret_tool
  printf %s '  s3 cret  ' | "$TOOLS/box-secret" set db
  [[ $("$TOOLS/box-secret" get db) == '  s3 cret  ' ]]
}

@test "box-secret: a name with a quote or backslash is refused" {
  run "$TOOLS/box-secret" set 'a"b'
  [[ $status -eq 2 && $output == *"can't hold"* ]]
  run "$TOOLS/box-secret" set 'a\b'
  [[ $status -eq 2 ]]
}

# macOS's security, keeping each item in a file named after its account. It
# logs its argv, and takes `-i` commands on stdin with -X hex, as the real one.
fake_security() {
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$FAKE_DIR/keychain"
  cat >"$BATS_TEST_TMPDIR/bin/security" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_DIR/security.argv"
item() { printf '%s/keychain/%s' "$FAKE_DIR" "$(printf %s "$1" | tr / _)"; }
if [ "$1" = -i ]; then
  read -r line
  acct=${line#*-a \"}; acct=${acct%%\" -X *}
  hex=${line##* -X }
  printf "$(printf %s "$hex" | sed 's/../\\x&/g')" >"$(item "$acct")"
  exit 0
fi
cmd=$1; shift
while [ $# -gt 0 ]; do [ "$1" = -a ] && acct=$2; shift; done
case $cmd in
  find-generic-password) [ -f "$(item "$acct")" ] && cat "$(item "$acct")" ;;
  delete-generic-password) rm "$(item "$acct")" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/security"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "box-secret: on macOS the secret goes to security on stdin, never in argv" {
  as_mac
  fake_security
  local secret=' p@ss "w$rd\ %s '
  printf %s "$secret" | "$TOOLS/box-secret" set gh:/a/b
  [[ $("$TOOLS/box-secret" get gh:/a/b) == "$secret" ]]
  run grep -F 'p@ss' "$FAKE_DIR/security.argv"
  [[ $status -ne 0 ]]
}

@test "box-gh-token: a box-secret keyed by the current directory outside a repo" {
  fake_secret_tool
  cd "$BATS_TEST_TMPDIR"
  run "$TOOLS/box-gh-token" show
  [[ $status -eq 0 && $output == "no secret gh:$BATS_TEST_TMPDIR" ]]
  "$TOOLS/box-gh-token" set <<<"tok"
  [[ $("$TOOLS/box-secret" get "gh:$BATS_TEST_TMPDIR") == tok ]]
}

@test "box-gh-token: get without a token names box-gh-token set" {
  fake_secret_tool
  cd "$BATS_TEST_TMPDIR"
  run "$TOOLS/box-gh-token" get
  [[ $status -ne 0 && $output == *"run \`box-gh-token set\`"* ]]
}

@test "gh: no --gh means no token is passed, even if one is stored" {
  load_lib
  BOX_ENV_PREFIX=CL_BOX
  git init -q "$BATS_TEST_TMPDIR/repo"; cd "$BATS_TEST_TMPDIR/repo"
  _box_gh_token() { echo tok; }
  _box_gh_env
  [[ ${#BOX_GH_ENV[@]} -eq 0 && -z ${GH_TOKEN-} ]]
}
@test "gh: --gh passes the main checkout's token from a worktree" {
  fake_secret_tool
  load_lib
  BOX_ENV_PREFIX=CL_BOX; CL_BOX_GH=1
  git init -q -b main "$BATS_TEST_TMPDIR/repo"; cd "$BATS_TEST_TMPDIR/repo"
  git_q commit --allow-empty -m init
  git worktree add -q "$BATS_TEST_TMPDIR/wt" -b feat
  "$TOOLS/box-gh-token" set <<<"tok-repo"
  cd "$BATS_TEST_TMPDIR/wt"; _box_gh_env
  [[ $GH_TOKEN == tok-repo && " ${BOX_GH_ENV[*]} " == *" --env GH_TOKEN "* ]]
}
@test "gh: --gh without a stored token is refused" {
  fake_secret_tool
  load_lib
  BOX_ENV_PREFIX=CL_BOX; CL_BOX_GH=1
  git init -q "$BATS_TEST_TMPDIR/repo"; cd "$BATS_TEST_TMPDIR/repo"
  run _box_gh_env
  [[ $status -eq 1 ]]
  [[ $output == *"box-gh-token set"* ]]
}
@test "gh: --gh=host passes the host's gh token, not the stored one" {
  load_lib
  BOX_ENV_PREFIX=CL_BOX; box_parse_args --gh=host
  git init -q "$BATS_TEST_TMPDIR/repo"; cd "$BATS_TEST_TMPDIR/repo"
  _box_gh_token() { echo tok-repo; }
  gh() { [[ $* == "auth token" ]] && echo tok-host; }
  _box_gh_env
  [[ $GH_TOKEN == tok-host && " ${BOX_GH_ENV[*]} " == *" --env GH_TOKEN "* ]]
}
@test "gh: --gh=host without a host token is refused" {
  load_lib
  BOX_ENV_PREFIX=CL_BOX; CL_BOX_GH=host
  gh() { return 1; }
  run _box_gh_env
  [[ $status -eq 1 ]]
  [[ $output == *"gh auth login"* ]]
}

# ------------------------------------------------------------------ proxy -----
# A stub that takes the port box-proxy was given and listens on it, so the
# launch's readiness check passes without mitmproxy installed.
proxy_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/proxy-stub" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/proxy.calls"
addr=${5:?}
exec python3 -c 'import socket,sys,time
a, _, p = sys.argv[1].rpartition(":")
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((a or "127.0.0.1", int(p))); s.listen(); time.sleep(30)' "$addr"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/proxy-stub"
  export BOX_PROXY_CMD="$BATS_TEST_TMPDIR/bin/proxy-stub"
  # A CA of this launch's own, and the label a matching image would carry.
  export BOX_PROXY_CONFDIR="$BATS_TEST_TMPDIR/mitm"
  mkdir -p "$BOX_PROXY_CONFDIR"
  printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' \
    >"$BOX_PROXY_CONFDIR/mitmproxy-ca-cert.pem"
  printf -- 'fake key\n' >"$BOX_PROXY_CONFDIR/mitmproxy-ca-key.pem"
  cat "$BOX_PROXY_CONFDIR"/mitmproxy-ca-{key,cert}.pem >"$BOX_PROXY_CONFDIR/mitmproxy-ca.pem"
  if command -v sha256sum >/dev/null 2>&1; then
    export FAKE_CA_STAMP="$(sha256sum "$BOX_PROXY_CONFDIR/mitmproxy-ca-cert.pem" | cut -c1-16)"
  else
    export FAKE_CA_STAMP="$(shasum -a 256 "$BOX_PROXY_CONFDIR/mitmproxy-ca-cert.pem" | cut -c1-16)"
  fi
}

@test "proxy: --no-fence publishes the proxy without enforcing egress" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":["api.github.com"],"rules":[{"host":"api.github.com","header":"authorization","with":"Bearer {cmd:printf tok}","fake_env":[]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --no-fence --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  grep -q -- ':/etc/box-proxy:ro$' "$FAKE_DIR/proxy.args"
  grep -qx -- 'BOX_PROXY_CONFIG=/etc/box-proxy/proxy.json' "$FAKE_DIR/proxy.args"
  grep -q -- 'regular@0.0.0.0:8080' "$FAKE_DIR/proxy.args"
  local port
  port=$(sed -n 's|^127\.0\.0\.1:\([0-9]*\):8080$|\1|p' "$FAKE_DIR/proxy.args")
  [[ -n $port ]]
  grep -q "^HTTPS_PROXY=http://127.0.0.1:$port$" "$FAKE_DIR/run.args"
  grep -q '^BOX_SESSION=' "$FAKE_DIR/run.args"
  run_has --network "pasta:-T,$port"
  # the proxy's port is forwarded, but it isn't one of yours
  [[ $output != *"==> host:"* ]]
}

@test "proxy: a failed render leaves no rendered secrets behind" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  export SECRET_TOKEN=s3cr3t
  echo '{"allow":"all","rules":[{"host":"a.example.com","with":"Bearer {env:SECRET_TOKEN}","fake_env":[]},{"host":"b.example.com","with":"Bearer {cmd:exit 3}","fake_env":[]}]}' \
    >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --no-fence --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -ne 0 && $output == *"could not render"* ]]
  run grep -rl s3cr3t "$XDG_STATE_HOME/agent-box/proxy"
  [[ $status -ne 0 ]]
}

@test "proxy: a CA missing its key, or an image without the CA, is named as such" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"all"}' >"$BATS_TEST_TMPDIR/proxy.json"
  FAKE_CA_STAMP= run_box --no-fence --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -ne 0 && $output == *"predates the proxy CA"* ]]
  rm "$BOX_PROXY_CONFDIR/mitmproxy-ca-key.pem"
  run_box --no-fence --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -ne 0 && $output == *"certificate but no key"* ]]
  # and the proxy container itself won't start on a CA of its own
  load_lib
  [[ $BOX_PROXY_SH == *'[ -f /tmp/mitm/mitmproxy-ca.pem ] || {'*'exit 1; }'* ]]
}

@test "proxy: --proxy without a config stops before anything runs" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  run_box --proxy="$BATS_TEST_TMPDIR/nope.json" --shell -c true
  [[ $status -ne 0 && $output == *"no config at"* ]]
  [[ ! -f $FAKE_DIR/run.args ]]
}

@test "proxy: proxy and fence default on, and --no-proxy opts out of both" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$HOME/.box.default.proxy.json"
  local platform
  for platform in as_linux as_mac; do
    "$platform"
    : >"$FAKE_DIR/calls"
    run bash "$TOOLS/claude-box" --shell -c true
    [[ $status -eq 0 ]]
    call_has 'network create --internal'
    grep -qx 'HTTPS_PROXY=http://127.0.0.2:8080' "$FAKE_DIR/run.args"
    : >"$FAKE_DIR/calls"
    run bash "$TOOLS/claude-box" --no-proxy --shell -c true
    [[ $status -eq 0 ]]
    ! grep -q '^HTTPS_PROXY=' "$FAKE_DIR/run.args"
    call_lacks 'network create'
  done
}

@test "proxy: an explicit proxy path enables fencing unless the knob opts out" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  call_has 'network create --internal'
  : >"$FAKE_DIR/calls"
  CL_BOX_FENCE=0 run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  call_lacks 'network create --internal'
  grep -q '^HTTPS_PROXY=http://127.0.0.1:' "$FAKE_DIR/run.args"
}

@test "proxy: only declared fake envs are supplied, without inferring host names" {
  llm_serve qwen3-coder
  proxy_stub
  echo '{"allow":["llm.example.com"],"rules":[{"host":"llm.example.com","path":"/a","with":"Bearer {env:LOCAL_LLM_API_KEY}","fake_env":["ALT_CLIENT_TOKEN"]},{"host":"llm.example.com","path":"/b","with":"Bearer {env:LOCAL_LLM_API_KEY}","fake_env":["ALT_CLIENT_TOKEN"]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  oc_run --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  run_has --env ALT_CLIENT_TOKEN=box-proxy-placeholder
  [[ $(grep -cx ALT_CLIENT_TOKEN=box-proxy-placeholder "$FAKE_DIR/run.args") -eq 1 ]]
  run_has --env LOCAL_LLM_API_KEY
  run_has --env OPENCODE_API_KEY
  run_lacks LOCAL_LLM_API_KEY=box-proxy-placeholder
  run_lacks OPENCODE_API_KEY=box-proxy-placeholder
  run_lacks BQ_TOKEN=box-proxy-placeholder
  run_lacks CLOUDSDK_AUTH_ACCESS_TOKEN=box-proxy-placeholder
}

@test "proxy: final env filtering covers wrappers and preserves client arguments" {
  load_lib
  BOX_CTR=(podman)
  BOX_FAKE_ENV=(CUSTOM_TOKEN GH_TOKEN UNSET_TOKEN)
  export CUSTOM_TOKEN=host-secret GH_TOKEN=gh-secret
  local mode
  for mode in 0 1; do
    BOX_SHELL=$mode
    box_run --env CUSTOM_TOKEN --env CUSTOM_TOKEN=inline-secret \
      --env=CUSTOM_TOKEN=equals-secret -e GH_TOKEN -eGH_TOKEN=short-secret \
      --env UNLISTED=keep "$BOX_IMAGE" --env CUSTOM_TOKEN=client-argument
    run_has --env CUSTOM_TOKEN=box-proxy-placeholder
    run_has --env=CUSTOM_TOKEN=box-proxy-placeholder
    run_has -e GH_TOKEN=box-proxy-placeholder
    run_has -eGH_TOKEN=box-proxy-placeholder
    run_has --env UNSET_TOKEN=box-proxy-placeholder
    run_has --env UNLISTED=keep
    run_has --env CUSTOM_TOKEN=client-argument
    run_lacks CUSTOM_TOKEN
    run_lacks GH_TOKEN
    ! grep -Eq 'host-secret|gh-secret|inline-secret|equals-secret|short-secret' "$FAKE_DIR/run.args"
    [[ $CUSTOM_TOKEN == host-secret && $GH_TOKEN == gh-secret ]]
  done
  CL_BOX_PROXY=0 _box_proxy_start
  [[ ${#BOX_FAKE_ENV[@]} -eq 0 ]]
  box_run --env CUSTOM_TOKEN "$BOX_IMAGE"
  run_has --env CUSTOM_TOKEN
  run_lacks CUSTOM_TOKEN=box-proxy-placeholder
}

@test "proxy: declarations mask tokens selected by either gh passthrough flag" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  fake_secret_tool
  "$TOOLS/box-gh-token" set <<<"repo-real"
  printf '#!/bin/sh\nprintf host-real\n' >"$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  echo '{"allow":["api.github.com"],"rules":[{"host":"api.github.com","with":"Bearer {env:GH_TOKEN}","fake_env":["GH_TOKEN"]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  local flag
  for flag in --gh --gh=host; do
    run_box "$flag" --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
    [[ $status -eq 0 ]]
    run_has --env GH_TOKEN=box-proxy-placeholder
    run_lacks GH_TOKEN
    run_box "$flag" --no-proxy --shell -c true
    [[ $status -eq 0 ]]
    run_has --env GH_TOKEN
    run_lacks GH_TOKEN=box-proxy-placeholder
  done
}

@test "proxy: profile credentials stay on the host and bq gets a fake token" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  cat >"$HOME/.box.default.env" <<'EOF'
export LOCAL_LLM_API_KEY=local-real
export OPENCODE_API_KEY=go-real
export BQ_TOKEN=bq-real
export CLOUDSDK_AUTH_ACCESS_TOKEN=cloud-real
export CUSTOM_TOKEN=custom-real
export UNRELATED=keep-me
EOF
  cat >"$HOME/.box.default.down" <<'EOF'
printf '%s\n' "$LOCAL_LLM_API_KEY" "$OPENCODE_API_KEY" "$BQ_TOKEN" "$CLOUDSDK_AUTH_ACCESS_TOKEN" >"$FAKE_DIR/host-keys"
EOF
  echo '{"allow":["llm.example.com"],"rules":[{"host":"llm.example.com","with":"Bearer {env:LOCAL_LLM_API_KEY}","fake_env":["LOCAL_LLM_API_KEY","OPENCODE_API_KEY","BQ_TOKEN","CLOUDSDK_AUTH_ACCESS_TOKEN","CUSTOM_TOKEN","UNSET_TOKEN"]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  local var
  for var in LOCAL_LLM_API_KEY OPENCODE_API_KEY BQ_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN CUSTOM_TOKEN UNSET_TOKEN; do
    run_has --env "$var=box-proxy-placeholder"
    run_lacks "$var"
  done
  run_has --env UNRELATED
  ! grep -Eq 'local-real|go-real|bq-real|cloud-real|custom-real' "$FAKE_DIR/run.args"
  [[ $(<"$FAKE_DIR/host-keys") == $'local-real\ngo-real\nbq-real\ncloud-real' ]]
  run_box --no-proxy --shell -c true
  [[ $status -eq 0 ]]
  for var in LOCAL_LLM_API_KEY OPENCODE_API_KEY BQ_TOKEN CLOUDSDK_AUTH_ACCESS_TOKEN CUSTOM_TOKEN; do
    run_has --env "$var"
    run_lacks "$var=box-proxy-placeholder"
  done
  run_lacks UNSET_TOKEN=box-proxy-placeholder
}

@test "proxy: LLM clients get fake envs and migrate managed literal keys" {
  llm_serve qwen3-coder
  proxy_stub
  export OPENCODE_API_KEY=go-real
  echo '{"allow":["llm.example.com","opencode.ai"],"rules":[{"host":"llm.example.com","with":"Bearer {env:LOCAL_LLM_API_KEY}","fake_env":["LOCAL_LLM_API_KEY"]},{"host":"opencode.ai","with":"Bearer {env:OPENCODE_API_KEY}","fake_env":["OPENCODE_API_KEY"]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  local agent
  # Seed through the real sync commands, then simulate older inline-key configs.
  pi_sync
  [[ $status -eq 0 ]]
  oc_sync
  [[ $status -eq 0 ]]
  python3 - "$PI_BOX_HOME/.pi/agent/models.json" "$OC_BOX_HOME/.config/opencode/opencode.json" <<'PY'
import json, sys
for path, root, provider, key in ((sys.argv[1], "providers", "local", "apiKey"),
                                  (sys.argv[2], "provider", "localllm", "options")):
    cfg = json.load(open(path))
    p = cfg[root][provider]
    if key == "options":
        p["options"]["apiKey"] = "legacy-local-key"
    else:
        p[key] = "legacy-local-key"
    with open(path, "w") as f:
        json.dump(cfg, f)
PY
  for agent in pi oc; do
    "${agent}_run" --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
    [[ $status -eq 0 ]]
    run_has --env LOCAL_LLM_API_KEY=box-proxy-placeholder
    run_has --env OPENCODE_API_KEY=box-proxy-placeholder
    run_lacks LOCAL_LLM_API_KEY
    run_lacks OPENCODE_API_KEY
    "${agent}_run" --shell -c true
    [[ $status -eq 0 ]]
    run_has --env LOCAL_LLM_API_KEY
    run_has --env OPENCODE_API_KEY
  done
  ! grep -q legacy-local-key "$PI_BOX_HOME/.pi/agent/models.json"
  ! grep -q legacy-local-key "$OC_BOX_HOME/.config/opencode/opencode.json"
}

@test "proxy: OCR's managed config follows the declared fake env" {
  llm_serve qwen3-coder
  proxy_stub
  export OCR_BOX_HOME="$BATS_TEST_TMPDIR/ocr-home" OCR_BOX_RUNTIME=crun \
    LOCAL_LLM_URL="file://$BATS_TEST_TMPDIR/llm/v1" LOCAL_LLM_API_KEY=local-real
  echo '{"allow":["llm.example.com"],"rules":[{"host":"llm.example.com","with":"Bearer {env:LOCAL_LLM_API_KEY}","fake_env":[]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  run bash "$TOOLS/ocr-box" --sync-only
  [[ $status -eq 0 ]]
  local config="$OCR_BOX_HOME/.opencodereview/config.json"
  ! grep -q '"api_key"' "$config"
  ! grep -q local-real "$config"
  run bash "$TOOLS/ocr-box" --no-proxy --shell -c true
  [[ $status -eq 0 ]]
  grep -q local-real "$config"
  run bash "$TOOLS/ocr-box" --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  grep -q local-real "$config"
  echo '{"allow":["llm.example.com"],"rules":[{"host":"llm.example.com","with":"Bearer {env:LOCAL_LLM_API_KEY}","fake_env":["LOCAL_LLM_API_KEY"]}]}' >"$BATS_TEST_TMPDIR/proxy.json"
  run bash "$TOOLS/ocr-box" --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  grep -q box-proxy-placeholder "$config"
  ! grep -q local-real "$config"
  run env -u LOCAL_LLM_API_KEY bash "$TOOLS/ocr-box" --no-proxy --shell -c true
  [[ $status -ne 0 && $output == *"LOCAL_LLM_API_KEY is unset and no active fake_env"* ]]
}

@test "proxy: quoted tilde config paths expand on the host" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$HOME/custom.proxy.json"
  run_box '--proxy=~/custom.proxy.json' --shell -c true
  [[ $status -eq 0 ]]
}

@test "proxy: journal directories are resolved and created, but not broad mounts" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  mkdir -p "$BATS_TEST_TMPDIR/project"
  cd "$BATS_TEST_TMPDIR/project"
  echo '{"allow":"none","journal":{"path":"logs/calls.jsonl"}}' >proxy.json
  run_box --proxy=proxy.json --shell -c true
  [[ $status -eq 0 && -d $PWD/logs ]]
  grep -qx -- "$PWD/logs:/var/journal" "$FAKE_DIR/proxy.args"
  echo '{"allow":"none","journal":{"path":"calls.jsonl"}}' >proxy.json
  run_box --proxy=proxy.json --shell -c true
  [[ $status -eq 0 ]]
  grep -qx -- "$PWD:/var/journal" "$FAKE_DIR/proxy.args"
  local path
  for path in '~/calls.jsonl' /calls.jsonl; do
    printf '{"allow":"none","journal":{"path":"%s"}}' "$path" >proxy.json
    run_box --proxy=proxy.json --shell -c true
    [[ $status -ne 0 && $output == *"dedicated directory"* ]]
  done
}

# --------------------------------------------------------------- box-proxy ----
@test "box-proxy: security and parser regressions" {
  run python3 "$BATS_TEST_DIRNAME/box_proxy_unit.py"
  [[ $status -eq 0 ]] || { echo "$output"; false; }
}

# The proxy itself, end to end over TLS. Needs mitmproxy on PATH; the rest of
# the suite runs without it.
@test "box-proxy: rewrites, refuses, answers and journals" {
  command -v mitmdump >/dev/null || skip "mitmdump is not on PATH"
  run python3 "$BATS_TEST_DIRNAME/box_proxy_e2e.py"
  [[ $status -eq 0 ]] || {
    echo "$output"
    false
  }
}

@test "fence: the box sits on an internal network and the proxy is its only way out" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --fence --shell -c true
  [[ $status -eq 0 ]]
  local net
  call_has "network create --internal --disable-dns cl-net-"
  net=$(sed -n 's/^podman network create --internal --disable-dns \(.*\)$/\1/p' "$FAKE_DIR/calls")
  [[ -n $net ]]
  # the box is on it, and the proxy is the only container on both it and the
  # default network
  run_has --network "$net"
  grep -qx -- "$net" "$FAKE_DIR/proxy.args"
  grep -qx -- podman "$FAKE_DIR/proxy.args"
  [[ $(awk '$0 == "--network" { getline; print }' "$FAKE_DIR/proxy.args") == "podman"$'\n'"$net" ]]
  [[ $(awk '$0 == "--network" { getline; print }' "$FAKE_DIR/run.args") == "$net" ]]
  ! grep -q '^127\.0\.0\.1:' "$FAKE_DIR/proxy.args"
  grep -q "^HTTPS_PROXY=http://127.0.0.2:8080$" "$FAKE_DIR/run.args"
}

@test "fence: --fence brings the proxy, and uses the profile's config" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  run_box --fence --shell -c true
  [[ $status -ne 0 && $output == *"no config at"*".box.default.proxy.json"* ]]
  echo '{"allow":"none"}' >"$HOME/.box.default.proxy.json"
  run_box --fence --shell -c true
  [[ $status -eq 0 ]]
  call_has "network create --internal --disable-dns cl-net-"
  grep -q "^HTTPS_PROXY=http://127.0.0.2:8080$" "$FAKE_DIR/run.args"
}

@test "fence: explicit proxy opt-outs are refused in either flag order" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  run_box --no-proxy --fence --shell -c true
  [[ $status -ne 0 && $output == *"--fence needs a proxy"* ]]
  run_box --fence --no-proxy --shell -c true
  [[ $status -ne 0 && $output == *"--fence needs a proxy"* ]]
  CL_BOX_PROXY=no run_box --fence --shell -c true
  [[ $status -ne 0 && $output == *"--fence needs a proxy"* ]]
}

@test "fence: podman inspect only reports attached networks" {
  printf '%s\n' --network right-net >"$FAKE_DIR/proxy.args"
  run podman inspect --format '{{(index .NetworkSettings.Networks "wrong-net").IPAddress}}' proxy
  [[ $status -eq 0 && -z $output ]]
  run podman inspect --format '{{(index .NetworkSettings.Networks "right-net").IPAddress}}' proxy
  [[ $status -eq 0 && $output == 127.0.0.2 ]]
}

@test "fence: another way out is refused" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  CL_BOX_SSH=1 run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --fence --shell -c true
  [[ $status -ne 0 && $output == *"leaves no way out; drop --ssh"* ]]
}

@test "fence: under podman a host port goes through the proxy, over a private socket" {
  command -v socat >/dev/null || skip "socat is not on PATH"
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --fence --host-port=5432,6379 --shell -c true
  [[ $status -eq 0 ]]
  [[ $output == *"127.0.0.1:5432,6379 forwarded to the host through the proxy"* ]]
  # the box dials the proxy's fence address, on the relay's own ports
  run_has --env BOX_HOST_GATEWAY=127.0.0.2
  run_has --env "BOX_HOST_PORTS=5432:24100 6379:24101"
  awk -v r="BOX_RELAY=192.0.2.1 24100=unix:/run/box-relay/5432.sock 24101=unix:/run/box-relay/6379.sock" \
    'p == "-e" && $0 == r { f = 1 } { p = $0 } END { exit !f }' "$FAKE_DIR/proxy.args"
  local socks
  socks="$(awk -F: 'p == "-v" && $2 == "/run/box-relay" { print $1 } { p = $0 }' "$FAKE_DIR/proxy.args")"
  [[ $socks == "$XDG_RUNTIME_DIR"/agent-box-relay.* ]]
  # no pasta forwards: the fence network is the box's only one, and the
  # sockets and their socat are gone with the launch
  [[ $(awk '$0 == "--network" { getline; print }' "$FAKE_DIR/run.args") == cl-net-* ]]
  [[ ! -e $socks ]]
  run pgrep -f "UNIX-LISTEN:$socks"
  [[ $status -ne 0 ]]
}

@test "fence: on a Mac a launch port goes through the proxy, to the proxy alone" {
  as_mac
  fake_mac_tools
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  printf 'BOX_LAUNCH_PORT=PGPORT\n' >"$HOME/.box.db.env"
  FAKE_RUN_SLEEP=3 run_box --profile db --proxy="$BATS_TEST_TMPDIR/proxy.json" --fence --shell -c true
  [[ $status -eq 0 ]]
  [[ $output == *"forwarded to the host through the proxy"* ]]
  [[ $output != *"nothing listens"* ]]
  local pg gw
  pg="$(sed -n 's/.*PGPORT=\([0-9]*\), for this launch.*/\1/p' <<<"$output")"
  gw="$(sed -n "s#^BOX_HOST_PORTS=$pg:\([0-9]*\)\$#\1#p" "$FAKE_DIR/run.args")"
  [[ -n $pg && -n $gw ]]
  # the box dials the proxy's fence address; the proxy relays to the gateway
  run_has --env BOX_HOST_GATEWAY=127.0.0.2
  awk -v r="BOX_RELAY=192.168.64.1 $gw" 'p == "-e" && $0 == r { f = 1 } { p = $0 } END { exit !f }' \
    "$FAKE_DIR/proxy.args"
  # and the gateway serves it to the proxy's outbound (default-network) address
  # only, not its fence one
  grep -qxF "TCP-LISTEN:$gw,bind=192.168.64.1,reuseaddr,fork,range=127.0.0.3/32 TCP:127.0.0.1:$pg" \
    "$FAKE_DIR/socat.calls"
  [[ $(awk '$0 == "--network" { getline; print }' "$FAKE_DIR/run.args" | wc -l) -eq 1 ]]
}

@test "fence: krun's VM goes on the fence network like a container" {
  load_lib
  BOX_CTR=(podman) BOX_RUN_ARGS=()
  CL_BOX_PROXY=1 CL_BOX_RUNTIME=krun
  _box_fence_start 2>/dev/null
  [[ $BOX_FENCE_NET == cl-net-* ]]
  [[ " ${BOX_RUN_ARGS[*]} " == *" --network $BOX_FENCE_NET "* ]]
  call_has "network create --internal --disable-dns $BOX_FENCE_NET"
}

@test "fence: a knob value that isn't 0 or 1 is refused, not read as off" {
  load_lib
  BOX_CTR=(podman)
  CL_BOX_PROXY=1 CL_BOX_RUNTIME=crun
  local v
  for v in yes true on 2 off; do
    CL_BOX_FENCE=$v
    run _box_fence_start
    [[ $status -ne 0 && $output == *"CL_BOX_FENCE='$v'"* ]]
  done
  CL_BOX_FENCE=0
  run _box_fence_start
  [[ $status -eq 0 && -z $output ]]
}

@test "fence: WSL2 fails closed unless explicitly opted out" {
  load_lib
  BOX_CTR=(podman)
  as_wsl
  CL_BOX_PROXY=1 CL_BOX_FENCE=1 CL_BOX_RUNTIME=crun
  run _box_fence_start
  [[ $status -ne 0 && $output == *"WSL2"* && $output == *"--no-fence"* ]]
  CL_BOX_FENCE=0
  run _box_fence_start
  [[ $status -eq 0 ]]
}

# -------------------------------------------------------------------- gpu -----
@test "gpu: --gpu runs crun with kfd and all of /dev/dri" {
  export CL_BOX_RUNTIME=crun
  run_box --gpu --shell -c true
  [[ $status -eq 0 ]]
  run_has --runtime crun
  run_has --device /dev/kfd
  run_has --device /dev/dri
  run_has --group-add keep-groups
}

@test "gpu: --gpu=NODES passes only those render nodes" {
  export CL_BOX_RUNTIME=crun BOX_DRI_DIR="$BATS_TEST_TMPDIR/dri"
  mkdir -p "$BOX_DRI_DIR" && touch "$BOX_DRI_DIR/renderD128" "$BOX_DRI_DIR/renderD129"
  run_box --gpu=renderD129 --shell -c true
  [[ $status -eq 0 ]]
  run_has --device /dev/dri/renderD129
  run_lacks /dev/dri
  run_box --gpu=renderD130 --shell -c true
  [[ $status -ne 0 && $output == *"isn't a render node"* ]]
}

@test "gpu: refused under krun, on WSL2 and on a Mac" {
  load_lib
  CL_BOX_GPU=all CL_BOX_RUNTIME=krun BOX_RUN_ARGS=()
  run _box_gpu_args
  [[ $status -ne 0 && $output == *"no /dev/kfd"* ]]
  as_wsl
  run_box --gpu --shell -c true
  [[ $status -ne 0 && $output == *"--gpu needs Linux"* ]]
  as_mac
  run_box --gpu --shell -c true
  [[ $status -ne 0 && $output == *"--gpu needs Linux"* ]]
}

@test "gpu: --gpu and --proxy together, and only the box gets the devices" {
  export CL_BOX_RUNTIME=crun BOX_DRI_DIR="$BATS_TEST_TMPDIR/dri"
  proxy_stub
  mkdir -p "$BOX_DRI_DIR" && touch "$BOX_DRI_DIR/renderD128"
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --gpu --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  run_has --device /dev/kfd
  ! grep -qx -- /dev/kfd "$FAKE_DIR/proxy.args"
}

# ------------------------------------------------------------------- size -----
@test "size: max leaves the limit off, and the box goes first on OOM" {
  export CL_BOX_RUNTIME=crun
  CL_BOX_CPUS=max CL_BOX_MEMORY=max run_box --shell -c true
  [[ $status -eq 0 ]]
  run_lacks --cpus
  run_lacks --memory
  run_has --oom-score-adj 1000
  CL_BOX_MEMORY=max run_box --shell -c true
  run_has --cpus 4
  CL_BOX_CPUS=max run_box --shell -c true
  run_has --memory 4G
  run_lacks --oom-score-adj
}

@test "size: max is refused for a VM" {
  load_lib
  CL_BOX_MEMORY=max BOX_RUN_ARGS=()
  run _box_size_args
  [[ $status -ne 0 && $output == *"a VM needs a size"* ]]
}

@test "proxy: an image built with another CA is refused" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":[]}' >"$BATS_TEST_TMPDIR/proxy.json"
  FAKE_CA_STAMP=deadbeefdeadbeef run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -ne 0 && $output == *"built with another CA"* ]]
  [[ ! -f $FAKE_DIR/proxy.args ]]
}

@test "fence: on a Mac the box gets a host-only network and the proxy's address" {
  as_mac
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --fence --shell -c true
  [[ $status -eq 0 ]]
  call_has "network create --internal cl-net-"
  local net
  net=$(sed -n 's/^container network create --internal \(.*\)$/\1/p' "$FAKE_DIR/calls")
  [[ -n $net ]]
  run_has --network "$net"
  # the proxy is on the fence network and on the default one, the box only on
  # the fence
  grep -qx -- "$net" "$FAKE_DIR/proxy.args"
  grep -qx -- default "$FAKE_DIR/proxy.args"
  [[ $(awk '$0 == "--network" { getline; print }' "$FAKE_DIR/proxy.args") == "default"$'\n'"$net" ]]
  [[ $(awk '$0 == "--network" { getline; print }' "$FAKE_DIR/run.args") == "$net" ]]
  grep -q "^HTTPS_PROXY=http://127.0.0.2:8080$" "$FAKE_DIR/run.args"
}

@test "proxy: an address that never appears stops the launch with its log" {
  export CL_BOX_RUNTIME=crun
  proxy_stub
  echo '{"allow":"none"}' >"$BATS_TEST_TMPDIR/proxy.json"
  local platform
  for platform in as_linux as_mac; do
    "$platform"
    FAKE_NO_IP=1 run_box --proxy="$BATS_TEST_TMPDIR/proxy.json" --fence --shell -c true
    [[ $status -ne 0 ]]
    [[ $output == *"has no address"* ]]
    [[ $output == *"logs"* ]]
  done
}


@test "proxy: --no-fence on a Mac uses a plain shared network" {
  as_mac
  proxy_stub
  echo '{"allow":"all"}' >"$BATS_TEST_TMPDIR/proxy.json"
  run_box --no-fence --proxy="$BATS_TEST_TMPDIR/proxy.json" --shell -c true
  [[ $status -eq 0 ]]
  call_has "network create cl-net-"
  local net
  net=$(sed -n 's/^container network create \(cl-net-.*\)$/\1/p' "$FAKE_DIR/calls")
  [[ -n $net ]]
  # one network is both the way to the proxy and the way out
  run_has --network "$net"
  run_lacks default
  grep -qx -- "$net" "$FAKE_DIR/proxy.args"
  grep -q "^HTTPS_PROXY=http://127.0.0.2:8080$" "$FAKE_DIR/run.args"
}
