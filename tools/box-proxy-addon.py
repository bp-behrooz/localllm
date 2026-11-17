"""The mitmproxy addon behind box-proxy: a host allow-list, header rules, and a
journal of the tool calls the model asked for.

Loaded by mitmdump, which box-proxy starts for one launch. The config (JSON)
comes in through BOX_PROXY_CONFIG. Nothing here decides policy on its own: the
config says which hosts may be reached and what to put in a header, and every
host it does not name is refused before a connection is made.

`allow` is a list of hosts, `"all"` (the box's normal, unfiltered network), or
`"none"` (nothing through the proxy at all).

    {
      "session": "20261115-0802-localllm-a3f1",
      "allow": ["api.github.com", "*.googleapis.com", "api.tavily.com"],
      "rules": [
        {"host": "api.github.com", "header": "authorization",
         "with": "Bearer {gh}", "fake_env": ["GH_TOKEN"]},
        {"host": "bigquery.googleapis.com", "header": "authorization",
         "with": "Bearer {cmd:gcloud auth print-access-token}", "ttl": 600,
         "fake_env": ["BQ_TOKEN", "CLOUDSDK_AUTH_ACCESS_TOKEN"]},
        {"host": "oauth2.googleapis.com", "path": "/token",
         "respond": {"access_token": "dummy", "token_type": "Bearer",
                     "expires_in": 3600}}
      ],
      "journal": {"path": "/home/me/.local/state/agent-box/calls.jsonl",
                  "calls": ["llm.example.com"]}
    }

`{name}` asks the host keychain (`box-secret get name`); `{cmd:...}` runs a
command and takes its stdout, cached for `ttl` seconds (default 600) so a token
that expires mid-launch is minted again without touching the box. `replace` is
optional: without it the header's whole value becomes `with`.

A `respond` rule never reaches the upstream. It exists for the credential
dances a client insists on doing: hand it an identity with a token endpoint we
own and a syntactically valid answer, and the real secret never enters its
process.
"""

import fnmatch
import json
import os
import subprocess
import threading
import time

from mitmproxy import ctx, http

HERE = os.path.dirname(os.path.abspath(__file__))


def log(msg):
    ctx.log.info(msg)


def host_match(host, pattern):
    """A host against an allow/rule/journal glob, the way DNS compares names:
    case-insensitive, a trailing dot ignored."""
    return fnmatch.fnmatchcase(host.lower().rstrip("."), pattern.lower().rstrip("."))


def bare_path(flow):
    """The request path without its query string, which may carry a token
    (Google APIs accept access_token= and key=): what matching, the journal
    and the log see."""
    return flow.request.path.split("?")[0]


class Creds:
    """The values behind `{...}`, kept until their ttl runs out.

    Per-expression locks keep slow lookups from blocking unrelated credentials.
    `{file:...}` is the one the box-proxy
    container uses: the host renders a secret into a file and refreshes it, so a
    token that expires mid-launch is minted again without the container needing
    the keychain or the cloud CLI.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.cache = {}
        self.stamps = {}
        self.lookups = {}

    def get(self, expr, ttl):
        if expr.startswith("file:"):
            return self._file(expr[5:])
        with self.lock:
            lookup = self.lookups.setdefault(expr, threading.Lock())
        with lookup:
            with self.lock:
                hit = self.cache.get(expr)
                if hit and time.monotonic() - hit[0] < ttl:
                    return hit[1]
            value = self._run(expr)
            with self.lock:
                self.cache[expr] = (time.monotonic(), value)
            return value

    def _file(self, path):
        """Read on every call unless the file has not moved: the refresher
        rewrites it atomically, so mtime+size tells a new value from the same."""
        try:
            st = os.stat(path)
            stamp = (st.st_mtime_ns, st.st_size)
            with self.lock:
                if self.stamps.get(path) == stamp and path in self.cache:
                    return self.cache[path][1]
            with open(path, encoding="utf-8") as f:
                value = f.read().rstrip("\n")
            if not value:
                raise RuntimeError(f"{path}: the credential is empty")
            with self.lock:
                self.stamps[path] = stamp
                self.cache[path] = (time.monotonic(), value)
            return value
        except OSError as e:
            raise RuntimeError(f"{path}: no credential ({e})") from e

    @staticmethod
    def _run(expr):
        try:
            if expr.startswith("cmd:"):
                out = subprocess.run(expr[4:], shell=True, check=True,
                                     capture_output=True, text=True).stdout
            elif expr.startswith("env:"):
                out = os.environ.get(expr[4:], "")
            else:
                out = subprocess.run([os.path.join(HERE, "box-secret"), "get", expr],
                                     check=True, capture_output=True, text=True).stdout
        except (OSError, subprocess.CalledProcessError) as e:
            raise RuntimeError(f"{expr}: no credential ({e})") from e
        value = out.rstrip("\n")
        if not value:
            raise RuntimeError(f"{expr}: the credential is empty")
        return value


CREDS = Creds()


def expand(template, ttl):
    """`Bearer {gh}` -> `Bearer <the value>`, one {..} at a time."""
    out, i = [], 0
    while True:
        start = template.find("{", i)
        if start < 0:
            out.append(template[i:])
            return "".join(out)
        end = template.find("}", start)
        if end < 0:
            out.append(template[i:])
            return "".join(out)
        out.append(template[i:start])
        out.append(CREDS.get(template[start + 1:end].strip(), ttl))
        i = end + 1


class Calls:
    """Tool calls out of a model response, one JSON line each.

    OpenAI names a call once and streams its arguments in fragments by index;
    Anthropic opens a tool_use block and streams input_json_delta; the Responses
    API does both in one stream. They're accumulated by `kind:index` and flushed
    when the response ends.
    """

    def __init__(self, path, session):
        self.path = path
        self.session = session
        self.lock = threading.Lock()

    def write(self, record):
        record = dict(record, session=self.session)
        with self.lock:
            try:
                os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(record, ensure_ascii=False) + "\n")
            except OSError as e:
                # A journal that cannot be written must not take the proxy
                # down with it: say it once, keep proxying.
                if not getattr(self, "warned", False):
                    self.warned = True
                    log(f"journal {self.path}: {e}")


class Parser:
    def __init__(self):
        self.calls = {}
        self.order = []
        self.model = None

    def slot(self, key, **kw):
        if key not in self.calls:
            self.calls[key] = {"tool": "", "arguments": "", "id": None}
            self.order.append(key)
        for k, v in kw.items():
            if v:
                self.calls[key][k] = v
        return self.calls[key]

    def feed(self, obj):
        if not isinstance(obj, dict):
            return
        if not self.model:
            self.model = obj.get("model") or (obj.get("response") or {}).get("model")
        for choice in obj.get("choices") or []:
            for n, call in enumerate((choice.get("message") or {}).get("tool_calls") or []):
                fn = call.get("function") or {}
                s = self.slot(f"o:{n}", tool=fn.get("name"), id=call.get("id"))
                s["arguments"] += fn.get("arguments") or ""
            for call in (choice.get("delta") or {}).get("tool_calls") or []:
                fn = call.get("function") or {}
                s = self.slot(f"o:{call.get('index', 0)}", tool=fn.get("name"), id=call.get("id"))
                s["arguments"] += fn.get("arguments") or ""
        items = list(obj.get("output") or [])
        if obj.get("item"):
            items.append(obj["item"])
        for item in items:
            if item.get("type") == "function_call":
                key = item.get("id") or item.get("call_id")
                s = self.slot(f"r:{key}", tool=item.get("name"),
                              id=item.get("call_id") or item.get("id"))
                if item.get("arguments") is not None:
                    s["arguments"] = item["arguments"]
        if obj.get("type") == "response.function_call_arguments.delta":
            self.slot(f"r:{obj.get('item_id')}")["arguments"] += obj.get("delta") or ""
        for n, block in enumerate(obj.get("content") or []):
            if isinstance(block, dict) and block.get("type") == "tool_use":
                s = self.slot(f"a:{n}", tool=block.get("name"), id=block.get("id"))
                if block.get("input") not in (None, {}):
                    s["arguments"] = json.dumps(block["input"])
        block = obj.get("content_block") or {}
        if obj.get("type") == "content_block_start" and block.get("type") == "tool_use":
            s = self.slot(f"a:{obj.get('index', 0)}", tool=block.get("name"), id=block.get("id"))
            if block.get("input") not in (None, {}):
                s["arguments"] = json.dumps(block["input"])
        d = obj.get("delta") or {}
        if obj.get("type") == "content_block_delta" and d.get("type") == "input_json_delta":
            self.slot(f"a:{obj.get('index', 0)}")["arguments"] += d.get("partial_json") or ""

    def records(self, host, path):
        for key in self.order:
            s = self.calls[key]
            if s["tool"]:
                yield {"time": round(time.time(), 3), "host": host, "path": path,
                       "model": self.model, "tool": s["tool"],
                       "arguments": s["arguments"], "id": s["id"]}


class BoxProxy:
    def __init__(self):
        self.cfg = {}
        self.allow = []
        self.allow_all = False
        self.rules = []
        self.journal = None
        self.calls = None
        self.finishers = {}
        self.streaming = set()

    def load(self, loader):
        # Shared by host and container launches; deny before dialing upstream.
        ctx.options.update(connection_strategy="lazy", stream_large_bodies="10m")
        path = os.environ.get("BOX_PROXY_CONFIG")
        if not path:
            raise RuntimeError("box-proxy: BOX_PROXY_CONFIG is not set")
        try:
            with open(path, encoding="utf-8") as f:
                self.cfg = json.load(f)
        finally:
            if os.environ.get("BOX_PROXY_CONFIG_TEMP") == path:
                os.unlink(path)
        allow = self.cfg.get("allow")
        # "all" is the box's normal, unfiltered network; "none" is offline;
        # a list is the only internet the box has.
        self.allow_all = allow in ("all", "*")
        self.allow = [] if allow in ("all", "*", "none", None) else allow
        self.rules = self.cfg.get("rules") or []
        self.journal = self.cfg.get("journal") or {}
        if self.journal.get("path"):
            self.calls = Calls(self.journal["path"], self.cfg.get("session") or "unknown")
        if self.allow_all:
            reach = "everything"
        elif not self.allow:
            reach = "nothing"
        else:
            reach = ", ".join(self.allow)
        log(f"box-proxy: session {self.cfg.get('session')}, "
            f"{len(self.rules)} rule(s), allow {reach}")

    def allowed(self, host):
        if self.allow_all:
            return True
        return any(host_match(host, pat) for pat in self.allow)

    def rule(self, flow):
        host, path = flow.request.host, bare_path(flow)
        for r in self.rules:
            if not r.get("host") or not host_match(host, r["host"]):
                continue
            if r.get("path") and not fnmatch.fnmatchcase(path, r["path"]):
                continue
            if r.get("method") and r["method"].upper() != flow.request.method:
                continue
            return r
        return None

    def _check_destination(self, flow):
        host = flow.request.host
        # Host is client-controlled; only the routed destination may get a key.
        claimed = flow.request.pretty_host
        if not self.allowed(host) or claimed.lower().rstrip(".") != host.lower().rstrip("."):
            flow.response = http.Response.make(
                403, json.dumps({"error": "egress: not allowed", "host": host}).encode(),
                {"Content-Type": "application/json"})
            log(f"denied {flow.request.method} {host}{bare_path(flow)}")
            return False
        return True

    def http_connect(self, flow: http.HTTPFlow):
        self._check_destination(flow)

    def requestheaders(self, flow: http.HTTPFlow):
        # Streaming uploads may reach upstream before request() runs.
        self._check_destination(flow)

    def request(self, flow: http.HTTPFlow):
        if not self._check_destination(flow):
            return
        host = flow.request.host
        r = self.rule(flow)
        if not r:
            return
        if "respond" in r:
            body = json.dumps(r["respond"]).encode()
            flow.response = http.Response.make(
                r.get("status", 200), body, {"Content-Type": "application/json"})
            log(f"answered {host}{bare_path(flow)} for {self.cfg.get('session')}")
            return
        # HTTP may pass through, but never with credentials supplied by the host.
        if flow.request.scheme != "https":
            return
        header = r.get("header", "authorization")
        try:
            value = expand(r.get("with", ""), r.get("ttl", 600))
            if any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise RuntimeError("credential contains unsafe header characters")
        except RuntimeError as e:
            flow.response = http.Response.make(
                502, json.dumps({"error": str(e)}).encode(),
                {"Content-Type": "application/json"})
            log(f"no credential for {host}: {e}")
            return
        if r.get("replace"):
            old = flow.request.headers.get(header, "")
            flow.request.headers[header] = old.replace(r["replace"], value)
        else:
            flow.request.headers[header] = value

    def responseheaders(self, flow: http.HTTPFlow):
        if not self._journals(flow):
            return
        ctype = flow.response.headers.get("content-type", "")
        if "text/event-stream" in ctype:
            self.streaming.add(flow.id)
            flow.response.stream = self._tee(flow)

    def _journals(self, flow):
        return bool(self.calls) and any(
            host_match(flow.request.host, pat)
            for pat in self.journal.get("calls") or [])

    def _tee(self, flow):
        parser = Parser()
        buf = b""
        calls = self.calls

        def collect(chunk):
            nonlocal buf
            if not chunk:
                finish()
                return chunk
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if line.startswith(b"data:"):
                    payload = line[5:].strip()
                    if payload and payload != b"[DONE]":
                        # Journaling is a side channel: an odd payload costs
                        # its record, never the stream.
                        try:
                            parser.feed(json.loads(payload))
                        except Exception:
                            pass
            return chunk

        def finish():
            self.streaming.discard(flow.id)
            self.finishers.pop(flow.id, None)
            if calls is None:
                return
            for rec in parser.records(flow.request.host, bare_path(flow)):
                calls.write(rec)

        self.finishers[flow.id] = finish
        return collect

    def error(self, flow: http.HTTPFlow):
        # A stream that ends badly (the client hung up, the upstream dropped)
        # never sends the final empty chunk; flush what the model already said.
        finish = self.finishers.pop(flow.id, None)
        if finish:
            finish()
        self.streaming.discard(flow.id)

    def response(self, flow: http.HTTPFlow):
        if not self._journals(flow):
            return
        if flow.id in self.streaming:
            return  # the stream callback writes when the body ends
        calls = self.calls
        if calls is None:
            return
        parser = Parser()
        try:
            parser.feed(json.loads(flow.response.get_content() or b"{}"))
        except Exception:
            return
        for rec in parser.records(flow.request.host, bare_path(flow)):
            calls.write(rec)


addons = [BoxProxy()]
