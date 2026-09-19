#!/usr/bin/env python3
"""GPU pool server for llama-server.

The whole front end: an OpenAI-compatible, bearer-key-authenticated server on
0.0.0.0:4000. Requesting a model loads it on a free GPU (or both, for presets
that need them), LRU-evicting idle instances when no GPU is free. A
single-GPU model can run as two load-balanced instances: both are started up
front when the whole pool is free (and the model is already downloaded), and
a busy model scales out onto a free or long-idle GPU on demand. Config comes
from pool.json and the MASTER_KEY env var, both provided by setup.sh.

Self-test (no GPUs or config needed): python3 pool.py --test
"""
import asyncio
import json
import os
import re
import shlex
import subprocess
import sys
import time

import httpx
import uvicorn
from fastapi import FastAPI
from starlette.background import BackgroundTask
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_HUB = os.path.join(HERE, ".cache/huggingface/hub")
GPUS, PRESETS, LLAMA_BIN, MASTER_KEY = [], {}, "", ""
READY_TIMEOUT = 3600  # first start of a preset may have to download the model
IDLE_SCALE_EVICT = 600  # only sacrifice a model idle this long to duplicate a busy one

app = FastAPI()
client = httpx.AsyncClient(timeout=None)
lock = asyncio.Lock()
instances = {}  # name -> [Instance]


def load_config():
    global GPUS, PRESETS, LLAMA_BIN, MASTER_KEY
    cfg = json.load(open(os.path.join(HERE, "pool.json")))
    GPUS, PRESETS, LLAMA_BIN = cfg["gpus"], cfg["presets"], cfg["llama_bin"]
    MASTER_KEY = os.environ["MASTER_KEY"]


@app.middleware("http")
async def auth(request, call_next):
    if request.url.path != "/health" \
            and request.headers.get("authorization") != f"Bearer {MASTER_KEY}":
        return JSONResponse({"error": "invalid api key"}, status_code=401)
    return await call_next(request)


class Instance:
    def __init__(self, name, gpus):
        self.name, self.gpus = name, gpus
        self.port = 8080 + min(gpus)  # gpu sets are disjoint, so ports are too
        self.inflight = 0
        self.last_used = time.monotonic()
        preset = PRESETS[name]
        env = dict(os.environ, HIP_VISIBLE_DEVICES=",".join(map(str, gpus)))
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


def _drop(inst):
    inst.stop()
    lst = instances.get(inst.name, [])
    if inst in lst:
        lst.remove(inst)
    if not lst:
        instances.pop(inst.name, None)


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
    return {"status": "ok",
            "loaded": {n: [{"gpus": i.gpus, "inflight": i.inflight,
                            "ready": i.ready} for i in lst]
                       for n, lst in instances.items()}}


@app.get("/v1/models")
async def models():
    return {"object": "list",
            "data": [{"id": n, "object": "model", "owned_by": "pool"} for n in PRESETS]}


@app.get("/model/info")
async def model_info():
    """Context sizes per preset (shape kept from the LiteLLM era for clients)."""
    data = []
    for name, p in PRESETS.items():
        ctx = re.search(r"-c (\d+)", p["args"])
        data.append({"model_name": name,
                     "model_info": {"max_input_tokens": int(ctx.group(1))} if ctx else {}})
    return {"data": data}


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
               "big": {"hf": "org/big-GGUF", "gpus": 2, "args": ""}}
    for p in PRESETS.values():
        os.makedirs(os.path.join(work, "models--" + p["hf"].split(":")[0].replace("/", "--")))

    class FakeProc:
        returncode = None
        def poll(self): return self.returncode
        def terminate(self): pass
        def wait(self, *a): pass

    subprocess.Popen = lambda *a, **kw: FakeProc()
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

        # 8. HTTP layer: auth, model info, unknown model, busy pool,
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
        r = await api.get("/v1/models")
        assert {m["id"] for m in r.json()["data"]} == set(PRESETS)
        r = await api.get("/model/info")
        info = {m["model_name"]: m["model_info"] for m in r.json()["data"]}
        assert info["a"] == {"max_input_tokens": 4096} and info["b"] == {}
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
