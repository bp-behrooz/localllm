#!/usr/bin/env python3
"""GPU pool server for llama-server.

The whole front end: an OpenAI-compatible, key-authenticated server on
0.0.0.0:4000. Requesting a model loads it on a free GPU (or both, for presets
that need them), LRU-evicting idle instances when no GPU is free, and unloading any instance
left idle past its preset's TTL so the GPUs can drop into BACO. A
single-GPU model can run as two load-balanced instances: both are started up
front when the whole pool is free (and the model is already downloaded), and
a busy model scales out onto a free or long-idle GPU on demand. Config comes
from pool.json and env vars (see README), both provided by setup.sh.

Self-test (no GPUs or config needed): python3 pool.py --test
"""
import asyncio
import glob
import json
import os
import re
import shlex
import subprocess
import sys
import time

from contextlib import asynccontextmanager

import httpx
import uvicorn
from fastapi import FastAPI
from starlette.background import BackgroundTask
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_HUB = os.path.join(HERE, ".cache/huggingface/hub")
GPUS, PRESETS, LLAMA_BIN, MASTER_KEY, PRELOAD = [], {}, "", "", []
READY_TIMEOUT = 3600  # first start of a preset may have to download the model
IDLE_SCALE_EVICT = 600  # only sacrifice a model idle this long to duplicate a busy one
# Unload an instance idle this long (seconds; 0 = never) so its GPUs can power
# down. cmd presets (vLLM) load slowly, so they get their own, longer default.
# An env var or pool.json can override both, and a preset can set its own
# "idle_ttl".
IDLE_TTL, IDLE_TTL_CMD = 900, 2700
REAP_INTERVAL = 30  # how often the reaper looks for idle instances

@asynccontextmanager
async def _lifespan(_app):
    if PRELOAD:
        asyncio.create_task(preload_all())
    reaper_task = asyncio.create_task(reaper())
    yield
    reaper_task.cancel()


app = FastAPI(lifespan=_lifespan)
client = httpx.AsyncClient(timeout=None)
lock = asyncio.Lock()
instances = {}  # name -> [Instance]


def load_config():
    global GPUS, PRESETS, LLAMA_BIN, MASTER_KEY, PRELOAD, IDLE_TTL, IDLE_TTL_CMD, REAP_INTERVAL
    cfg = json.load(open(os.path.join(HERE, "pool.json")))
    GPUS, PRESETS, LLAMA_BIN = cfg["gpus"], cfg["presets"], cfg["llama_bin"]
    PRELOAD = cfg.get("preload", [])
    # env var > pool.json > default
    IDLE_TTL = int(os.environ.get("IDLE_TTL", cfg.get("idle_ttl", IDLE_TTL)))
    IDLE_TTL_CMD = int(os.environ.get("IDLE_TTL_CMD", cfg.get("idle_ttl_cmd", IDLE_TTL_CMD)))
    REAP_INTERVAL = int(os.environ.get("REAP_INTERVAL", REAP_INTERVAL))
    MASTER_KEY = os.environ["MASTER_KEY"]
    _set_power_cap()


def _set_power_cap():
    """POWER_CAP_W (per-GPU watts, one of the powerbench.py tested caps) -> the GPUs'
    power1_cap sysfs (uW); unset = leave alone."""
    cap = os.environ.get("POWER_CAP_W")
    if not cap:
        return
    tested = (300, 270, 240, 210)
    try:
        watts = float(cap)
    except ValueError:
        watts = None
    if watts not in tested:
        sys.exit(f"POWER_CAP_W={cap} W is not one of the tested caps {tested}")
    cards = glob.glob("/sys/bus/pci/devices/*/hwmon/hwmon*/power1_cap")
    if not cards:
        sys.exit("POWER_CAP_W set but no power1_cap sysfs found")
    try:
        for f in cards:
            open(f, "w").write(str(int(watts * 1e6)))
    except PermissionError:
        sys.exit("POWER_CAP_W: no write access to power1_cap; run the unit as root "
                 "(or make the file group-writable for the pool user)")
    print(f"[pool] power1_cap = {cap} W on {len(cards)} card(s)", file=sys.stderr)


def idle_ttl(name):
    """Seconds an instance of `name` may sit idle before it's unloaded; 0 = never."""
    preset = PRESETS[name]
    if "idle_ttl" in preset:
        return preset["idle_ttl"]
    return IDLE_TTL_CMD if "cmd" in preset else IDLE_TTL


def authorized(headers):
    # Bearer is the normal OpenAI form; x-litellm-api-key carries a bare key,
    # for clients that can only send the key in a header of their choosing.
    return headers.get("authorization") == f"Bearer {MASTER_KEY}" \
        or headers.get("x-litellm-api-key") == MASTER_KEY


@app.middleware("http")
async def auth(request, call_next):
    if request.url.path != "/health" and not authorized(request.headers):
        return JSONResponse({"error": "invalid api key"}, status_code=401)
    return await call_next(request)


class Instance:
    def __init__(self, name, gpus):
        self.name, self.gpus = name, gpus
        self.port = 8080 + min(gpus)  # gpu sets are disjoint, so ports are too
        self.inflight = 0
        self.last_used = time.monotonic()
        self.container = None  # cmd presets: the podman container's name
        preset = PRESETS[name]
        gpu_list = ",".join(map(str, gpus))
        env = dict(os.environ, HIP_VISIBLE_DEVICES=gpu_list)
        if "cmd" in preset:
            # custom engine (e.g. radiance/vLLM): the command reads PORT / GPUS /
            # NAME from the environment and must serve /health and /v1 on PORT.
            # A launcher that runs a container names it NAME, so stop() can
            # stop it with podman.
            self.container = f"pool-{name}-{self.port}"
            env.update(PORT=str(self.port), GPUS=gpu_list,
                       GPU_IDS=gpu_list, NAME=self.container)
            cmd = ["bash", "-c", preset["cmd"]]
        else:
            cmd = [LLAMA_BIN, "-hf", preset["hf"], "-fa", "on", "--jinja",
                   "--host", "127.0.0.1", "--port", str(self.port)]
            cmd += shlex.split(preset["args"])
        self.proc = subprocess.Popen(cmd, env=env)
        self.loader = asyncio.create_task(self._wait_ready())

    @property
    def ready(self):
        return self.loader.done() and not self.loader.cancelled() \
            and self.loader.exception() is None

    async def _wait_ready(self):
        deadline = time.monotonic() + READY_TIMEOUT
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(
                    f"{self.name}: llama-server exited with {self.proc.returncode}"
                    " (see journalctl -u localllm)")
            try:
                r = await client.get(f"http://127.0.0.1:{self.port}/health")
                if r.status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            await asyncio.sleep(2)
        raise RuntimeError(f"{self.name}: not ready after {READY_TIMEOUT}s")

    def stop(self):
        self.loader.cancel()
        if self.container:
            # killing the launcher doesn't stop its container (conmon keeps it
            # running), so stop that by name first; -i: fine if there's none
            try:
                subprocess.run(["podman", "stop", "-i", "-t", "30", self.container],
                               stdout=subprocess.DEVNULL, timeout=60)
            except (OSError, subprocess.TimeoutExpired) as e:
                print(f"[pool] podman stop {self.container}: {e}", file=sys.stderr)
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def _alive(name):
    live = [i for i in instances.get(name, []) if i.proc.poll() is None]
    if live:
        instances[name] = live
    else:
        instances.pop(name, None)
    return live


def _free_gpus():
    used = {g for lst in instances.values() for i in lst for g in i.gpus}
    return sorted(g for g in GPUS if g not in used)


def _forget(inst):
    lst = instances.get(inst.name, [])
    if inst in lst:
        lst.remove(inst)
    if not lst:
        instances.pop(inst.name, None)


def _drop(inst):
    inst.stop()
    _forget(inst)


def _evict_one(min_idle=0.0, exclude=None):
    """Stop the best victim; duplicates go before a model's last instance."""
    now = time.monotonic()
    idle = [i for lst in instances.values() for i in lst
            if i.inflight == 0 and i.name != exclude
            and now - i.last_used >= min_idle]
    if not idle:
        return False
    idle.sort(key=lambda i: (len(instances[i.name]) == 1, i.last_used))
    _drop(idle[0])
    return True


def _downloaded(name):
    # ponytail: dir existence only — a half-downloaded repo still counts, in
    # which case the eager second instance may race the first one's download.
    if "cmd" in PRESETS[name]:
        return False  # custom engines never eager-pair; scale-out still works
    repo = PRESETS[name]["hf"].split(":")[0]
    return os.path.isdir(os.path.join(CACHE_HUB, "models--" + repo.replace("/", "--")))


async def acquire(name):
    """Return a ready Instance for `name`, or None if every GPU is busy."""
    async with lock:
        need = PRESETS[name]["gpus"]
        pool = _alive(name)
        if not pool:
            while len(_free_gpus()) < need:
                if not _evict_one():
                    return None
            free = _free_gpus()
            # eager pair: whole pool free and no download race possible
            count = 2 if need == 1 and len(free) >= 2 and _downloaded(name) else 1
            pool = [Instance(name, free[n * need:(n + 1) * need]) for n in range(count)]
            instances[name] = pool
        elif need == 1 and len(pool) < len(GPUS) and all(i.inflight > 0 for i in pool):
            # scale out: every instance is busy; use a free GPU, or one whose
            # model has sat idle a good while
            if not _free_gpus():
                _evict_one(min_idle=IDLE_SCALE_EVICT, exclude=name)
            free = _free_gpus()
            if free:
                pool.append(Instance(name, [free[0]]))
        ready = [i for i in pool if i.ready]
        inst = min(ready or pool, key=lambda i: i.inflight)
        inst.last_used = time.monotonic()
    try:
        await asyncio.shield(inst.loader)
    except Exception:
        async with lock:
            _drop(inst)
        raise
    return inst


@app.get("/health")
async def health():
    now = time.monotonic()
    return {"status": "ok",
            "loaded": {n: [{"gpus": i.gpus, "inflight": i.inflight,
                            "ready": i.ready,
                            "idle_s": int(now - i.last_used),
                            "idle_ttl": idle_ttl(n)} for i in lst]
                       for n, lst in instances.items()}}


def _ordered_presets():
    """Preloaded presets first: clients that default to the first listed model
    (the tools/ boxes do) then default to what the pool serves at startup."""
    return [n for n in dict.fromkeys([*PRELOAD, *PRESETS]) if n in PRESETS]


@app.get("/v1/models")
async def models():
    return {"object": "list",
            "data": [{"id": n, "object": "model", "owned_by": "pool"}
                     for n in _ordered_presets()]}


@app.get("/model/info")
async def model_info():
    """Context sizes per preset (shape kept from the LiteLLM era for clients)."""
    data = []
    for name in _ordered_presets():
        p = PRESETS[name]
        # llama-server presets carry `-c N`; cmd presets may carry MAXLEN=N
        ctx = re.search(r"(?:-c |MAXLEN=)(\d+)", p.get("args") or p.get("cmd", ""))
        data.append({"model_name": name,
                     "model_info": {"max_input_tokens": int(ctx.group(1))} if ctx else {}})
    return {"data": data}


DEFAULT_CTX = 32768
@app.get("/model_group/info")
async def model_group_info():
    """LiteLLM-shaped model metadata, as qm's model gateway expects."""
    data = []
    for name in _ordered_presets():
        p = PRESETS[name]
        ctx = re.search(r"(?:-c |MAXLEN=)(\d+)", p.get("args") or p.get("cmd", ""))
        max_in = int(ctx.group(1)) if ctx else DEFAULT_CTX
        data.append({
            "model_group": name,
            "mode": "chat",
            "supports_function_calling": True,
            "max_input_tokens": max_in,
            "max_output_tokens": min(8192, max_in // 4),
            "input_cost_per_token": 0,
            "output_cost_per_token": 0,
        })
    return {"data": data}


async def preload_all():
    for name in PRELOAD:
        try:
            await acquire(name)
        except Exception as e:
            print(f"[pool] preload {name} failed: {e}", file=sys.stderr)


async def reap_idle():
    """Unload every instance idle past its TTL. Once its engine exits, nothing
    holds the GPU open and the kernel can runtime-suspend it."""
    async with lock:
        now = time.monotonic()
        for name in list(instances):
            ttl = idle_ttl(name)
            if not ttl:
                continue
            for inst in list(_alive(name)):
                # skip in-flight work and instances still loading (a first
                # start may be downloading the model for a long time)
                if inst.inflight or not inst.loader.done() \
                        or now - inst.last_used < ttl:
                    continue
                print(f"[pool] unloading {name} on GPU {inst.gpus}: idle "
                      f"{int(now - inst.last_used)}s (ttl {ttl}s)", file=sys.stderr)
                # stop() blocks (podman stop, proc.wait); run it in a thread so
                # health checks and streams keep flowing. The lock stays held,
                # so no new instance lands on these GPUs until they're free.
                await asyncio.to_thread(inst.stop)
                _forget(inst)


async def reaper():
    while True:
        await asyncio.sleep(REAP_INTERVAL)
        try:
            await reap_idle()
        except Exception as e:
            print(f"[pool] reaper: {e}", file=sys.stderr)


@app.post("/v1/{path:path}")
async def proxy(path: str, request: Request):
    body = await request.body()
    try:
        name = json.loads(body).get("model")
    except json.JSONDecodeError:
        name = None
    if name not in PRESETS:
        return JSONResponse({"error": f"unknown model '{name}'"}, status_code=404)
    try:
        inst = await acquire(name)
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)
    if inst is None:
        return JSONResponse(
            {"error": "all GPUs have in-flight requests; retry shortly"}, status_code=503)

    inst.inflight += 1
    try:
        upstream = client.build_request(
            "POST", f"http://127.0.0.1:{inst.port}/v1/{path}", content=body,
            headers={"content-type": request.headers.get("content-type", "application/json")})
        resp = await client.send(upstream, stream=True)
    except Exception as e:
        inst.inflight -= 1
        return JSONResponse({"error": str(e)}, status_code=502)

    async def cleanup():
        await resp.aclose()
        inst.inflight -= 1
        inst.last_used = time.monotonic()

    return StreamingResponse(
        resp.aiter_raw(), status_code=resp.status_code,
        media_type=resp.headers.get("content-type"),
        background=BackgroundTask(cleanup))


def selftest():
    global GPUS, PRESETS, LLAMA_BIN, MASTER_KEY, CACHE_HUB
    import shutil
    import tempfile

    work = tempfile.mkdtemp()
    CACHE_HUB = work
    # GPU "indices" 70/71 -> fake ports 8150/8151, so a test run on the real
    # box can't collide with live llama-servers on 8080/8081
    GPUS = [70, 71]
    LLAMA_BIN = "/bin/true"
    MASTER_KEY = "sk-test"
    PRESETS = {"a": {"hf": "org/a-GGUF:Q4", "gpus": 1, "args": "-c 4096"},
               "b": {"hf": "org/b-GGUF:Q4", "gpus": 1, "args": ""},
               "big": {"hf": "org/big-GGUF", "gpus": 2, "args": ""},
               "rad": {"cmd": "MAXLEN=1234 ./fake-serve.sh", "gpus": 2}}
    for p in PRESETS.values():
        if "hf" in p:
            os.makedirs(os.path.join(work, "models--" + p["hf"].split(":")[0].replace("/", "--")))

    class FakeProc:
        returncode = None
        def poll(self): return self.returncode
        def terminate(self): pass
        def wait(self, *a): pass

    spawned = []
    def fake_popen(cmd, env=None, **kw):
        spawned.append((cmd, env or {}))
        return FakeProc()
    subprocess.Popen = fake_popen
    ran = []
    subprocess.run = lambda cmd, **kw: ran.append(cmd)
    async def instantly_ready(self): pass
    Instance._wait_ready = instantly_ready

    async def run():
        def names():
            return {n: len(lst) for n, lst in instances.items()}

        # 1. cold start of a 1-GPU model with the whole pool free: eager pair
        await acquire("a")
        assert names() == {"a": 2}, names()

        # 2. cold start of another model: evicts one duplicate of a, never its last
        await acquire("b")
        assert names() == {"a": 1, "b": 1}, names()

        # 3. a saturated, b long idle: scale-out evicts b for a second a
        instances["a"][0].inflight = 1
        instances["b"][0].last_used -= IDLE_SCALE_EVICT + 1
        await acquire("a")
        assert names() == {"a": 2}, names()
        instances["a"][0].inflight = 0

        # 4. a 2-GPU model evicts everything
        big = await acquire("big")
        assert names() == {"big": 1} and big.gpus == GPUS, names()

        # 5. nothing evictable while requests are in flight
        big.inflight = 1
        assert await acquire("a") is None
        big.inflight = 0

        # 6. crashed instance is pruned and respawned on next request
        big.proc.returncode = 1
        await acquire("big")
        assert names() == {"big": 1} and instances["big"][0] is not big

        # 7. failed load raises and leaves no half-dead instance behind
        async def load_fails(self):
            raise RuntimeError("boom")
        Instance._wait_ready = load_fails
        instances["big"][0].proc.returncode = 1  # force a fresh spawn
        try:
            await acquire("big")
            raise AssertionError("expected load failure")
        except RuntimeError:
            pass
        assert "big" not in instances
        Instance._wait_ready = instantly_ready

        # 8. cmd preset: spawned via bash -c with PORT/GPUS/NAME in the env,
        #    scheduled like any other instance
        rad = await acquire("rad")
        cmd, env = spawned[-1]
        assert cmd[:2] == ["bash", "-c"] and "fake-serve" in cmd[2]
        assert env["PORT"] == str(rad.port) and env["GPUS"] == "70,71"
        assert env["NAME"] == f"pool-rad-{rad.port}"
        # ...and stopping it stops its container too (only cmd presets do)
        _drop(rad)
        assert ran == [["podman", "stop", "-i", "-t", "30", env["NAME"]]], ran

        # 9. preload: the configured default loads at startup
        global PRELOAD
        PRELOAD = ["a"]
        await preload_all()
        assert "a" in instances

        # 10. HTTP layer: auth, model info, unknown model, busy pool,
        #    upstream down + bookkeeping
        api = httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                base_url="http://t",
                                headers={"Authorization": "Bearer sk-test"})
        anon = httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                 base_url="http://t")
        r = await anon.get("/v1/models")
        assert r.status_code == 401, r.status_code
        r = await anon.get("/health")
        assert r.status_code == 200, r.status_code  # health stays open
        litellm = httpx.AsyncClient(transport=httpx.ASGITransport(app=app),
                                    base_url="http://t",
                                    headers={"x-litellm-api-key": "sk-test"})
        r = await litellm.get("/v1/models")
        assert r.status_code == 200, r.status_code  # bare key header works too
        assert not authorized({"x-litellm-api-key": "sk-wrong"})
        assert not authorized({"authorization": "sk-test"})  # bare key, wrong header
        r = await api.get("/v1/models")
        listed = [m["id"] for m in r.json()["data"]]
        assert set(listed) == set(PRESETS)
        assert listed[0] == "a"  # PRELOAD=["a"] since scenario 9: preload lists first
        r = await api.get("/model/info")
        info = {m["model_name"]: m["model_info"] for m in r.json()["data"]}
        assert info["a"] == {"max_input_tokens": 4096} and info["b"] == {}
        assert info["rad"] == {"max_input_tokens": 1234}
        r = await api.post("/v1/chat/completions", json={"model": "nope"})
        assert r.status_code == 404, r.status_code
        a = await acquire("a")
        for lst in instances.values():
            for i in lst:
                i.inflight = 1
        r = await api.post("/v1/chat/completions", json={"model": "big"})
        assert r.status_code == 503, r.status_code
        a.inflight = 0
        # nothing listens on the fake port: 502, and inflight is rolled back
        r = await api.post("/v1/chat/completions", json={"model": "a"})
        assert r.status_code == 502, r.status_code
        assert a.inflight == 0
        await api.aclose()
        await anon.aclose()

        # 11. idle reaping: per-kind TTLs, busy and loading instances spared
        global IDLE_TTL, IDLE_TTL_CMD, REAP_INTERVAL
        IDLE_TTL, IDLE_TTL_CMD = 100, 1000
        for lst in list(instances.values()):
            for i in list(lst):
                _drop(i)
        assert idle_ttl("a") == 100 and idle_ttl("rad") == 1000
        PRESETS["b"]["idle_ttl"] = 0  # per-preset override: never unload
        assert idle_ttl("b") == 0
        await acquire("a")  # whole pool free: eager pair
        pair = list(instances["a"])
        assert len(pair) == 2
        for i in pair:
            i.last_used -= 101
        pair[0].inflight = 1
        await reap_idle()
        assert instances["a"] == [pair[0]]  # in flight: kept; idle twin unloaded
        pair[0].inflight = 0
        await reap_idle()
        assert "a" not in instances  # idle past ttl: unloaded
        rad = await acquire("rad")
        rad.last_used -= 101  # past the llama ttl, not the cmd one
        await reap_idle()
        assert "rad" in instances
        ran.clear()
        rad.last_used -= 1000
        await reap_idle()
        assert "rad" not in instances
        assert ran == [["podman", "stop", "-i", "-t", "30", rad.container]], ran
        b = await acquire("b")
        b.last_used -= 10**6
        await reap_idle()
        assert "b" in instances  # ttl 0: never unloaded
        _drop(b)
        # an instance still loading is never reaped, however long it takes
        loading = Instance("a", [GPUS[0]])
        loading.loader.cancel()
        loading.loader = asyncio.get_running_loop().create_future()
        loading.last_used -= 10**6
        instances["a"] = [loading]
        await reap_idle()
        assert instances["a"] == [loading]
        _drop(loading)

        # 12. load_config: env > pool.json > default, and MASTER_KEY gets set
        # (regression: a stranded line left MASTER_KEY unset -> 401 for all)
        cfg_path = os.path.join(HERE, "pool.json")
        with open(cfg_path, "w") as f:
            json.dump({"gpus": GPUS, "presets": PRESETS, "llama_bin": LLAMA_BIN,
                       "idle_ttl": 55, "idle_ttl_cmd": 66}, f)
        os.environ["MASTER_KEY"] = "sk-cfg"
        os.environ["REAP_INTERVAL"] = "7"
        load_config()
        assert (MASTER_KEY, IDLE_TTL, IDLE_TTL_CMD, REAP_INTERVAL) == \
            ("sk-cfg", 55, 66, 7), (MASTER_KEY, IDLE_TTL, IDLE_TTL_CMD, REAP_INTERVAL)
        os.environ.pop("REAP_INTERVAL")
        os.remove(cfg_path)

        # 13. POWER_CAP_W: written to every card's power1_cap, in uW
        capf = os.path.join(work, "power1_cap")
        real_glob = glob.glob
        glob.glob = lambda p: [capf]
        os.environ["POWER_CAP_W"] = "210"
        _set_power_cap()
        assert open(capf).read() == "210000000"
        os.environ.pop("POWER_CAP_W")
        glob.glob = real_glob
        # an untested or non-numeric cap is refused before any sysfs access
        for bad in ("250", "eco"):
            os.environ["POWER_CAP_W"] = bad
            try:
                _set_power_cap()
                raise AssertionError(f"expected SystemExit for {bad!r}")
            except SystemExit:
                pass
            os.environ.pop("POWER_CAP_W")

    asyncio.run(run())
    shutil.rmtree(work)
    print("pool self-test ok")


if __name__ == "__main__":
    if "--test" in sys.argv:
        selftest()
    else:
        load_config()
        try:
            uvicorn.run(app, host="0.0.0.0", port=4000, log_level="warning")
        finally:
            for lst in instances.values():
                for i in lst:
                    i.stop()
