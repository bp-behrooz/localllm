#!/usr/bin/env python3
"""End-to-end check of box-proxy against a throwaway upstream.

Runs only where mitmdump is installed (the bats wrapper skips otherwise). It
starts a TLS upstream and a box-proxy in a temp dir, then drives curl through
the proxy and checks what came out: the placeholder replaced, another host
refused, a `respond` rule answered without an upstream, and the tool call in
the journal.
"""
import http.server
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def real(name):
    """The test suite stubs curl by putting its own first on PATH; this wants
    the real one, and openssl."""
    for d in ("/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"):
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    return name
BOX_PROXY = os.path.join(TOOLS, "box-proxy")
CALLS = []


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        CALLS.append(self.headers.get("Authorization") or "")
        self._send(200, json.dumps({"auth": self.headers.get("Authorization")}).encode())

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        CALLS.append(self.headers.get("Authorization") or "")
        if not self.path.startswith("/v1/chat/completions"):
            return self._send(200, b"{}")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        events = [
            {"model": "test-model", "choices": [{"delta": {"tool_calls": [
                {"index": 0, "id": "call_1",
                 "function": {"name": "bash", "arguments": "{\"comm"}}]}}]},
            {"choices": [{"delta": {"tool_calls": [
                {"index": 0, "function": {"arguments": "and\":\"ls\"}"}}]}}]},
        ]
        for e in events:
            c = ("data: " + json.dumps(e) + "\n\n").encode()
            self.wfile.write(b"%x\r\n" % len(c) + c + b"\r\n")
            self.wfile.flush()
            time.sleep(0.02)
        self.wfile.write(b"0\r\n\r\n")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_port(port, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def main():
    tmp = tempfile.mkdtemp(prefix="box-proxy-e2e.")
    fail = []
    procs = []

    def check(name, cond, detail=""):
        print(("ok   " if cond else "FAIL ") + name + (f": {detail}" if detail and not cond else ""))
        if not cond:
            fail.append(name)

    try:
        pem = os.path.join(tmp, "up.pem")
        subprocess.run(
            [real("openssl"), "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", pem, "-out", pem + ".crt", "-days", "1",
             "-subj", "/CN=127.0.0.1",
             "-addext", "subjectAltName=IP:127.0.0.1,IP:127.0.0.2"],
            check=True, capture_output=True)
        with open(pem, "ab") as f:
            f.write(open(pem + ".crt", "rb").read())

        up_port = free_port()
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(pem)
        srv = http.server.ThreadingHTTPServer(("0.0.0.0", up_port), Upstream)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        threading.Thread(target=plain.serve_forever, daemon=True).start()
        http_port = plain.server_address[1]

        journal = os.path.join(tmp, "calls.jsonl")
        confdir = os.path.join(tmp, "mitm")

        def start(name, cfg_dict):
            cfg = os.path.join(tmp, f"proxy-{name}.json")
            with open(cfg, "w") as f:
                json.dump(cfg_dict, f)
            p = subprocess.Popen(
                [sys.executable, BOX_PROXY, "run", "--config", cfg,
                 "--bind", "127.0.0.1:0", "--confdir", confdir,
                 "--insecure", "--print-bind"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            procs.append(p)
            bind = p.stdout.readline().strip()
            if not bind:
                raise RuntimeError(f"proxy failed to start ({name}): {p.stderr.read().strip() or 'no bind line'}")
            port = int(bind.rsplit(":", 1)[1])
            check(f"proxy listens ({name})", wait_port(port), bind)
            ca = os.path.join(confdir, "mitmproxy-ca-cert.pem")
            for _ in range(200):
                if os.path.exists(ca) and not any(
                    n.startswith("run-") for n in os.listdir(confdir)
                ):
                    break
                time.sleep(0.05)
            check(f"mitm CA present ({name})", os.path.exists(ca), ca)
            if not os.path.exists(ca):
                raise RuntimeError(f"proxy did not create its CA ({name}): {ca}")
            check(f"runtime config removed ({name})",
                  not any(n.startswith("run-") for n in os.listdir(confdir)))
            return port, ca

        def fetch(port, ca, *args):
            return subprocess.run(
                [real("curl"), "-sS", "--max-time", "15", "--proxy", f"http://127.0.0.1:{port}",
                 "--cacert", ca, *args],
                capture_output=True, text=True).stdout

        def code(port, ca, url, *args):
            result = subprocess.run(
                [real("curl"), "-sS", "--max-time", "10", "-o", "/dev/null", "-w", "%{http_code} %{http_connect}",
                 "--proxy", f"http://127.0.0.1:{port}", "--cacert", ca, *args, url],
                capture_output=True, text=True)
            status, _, tunnel = result.stdout.strip().partition(" ")
            return tunnel if status == "000" else status

        rules = [
            {"host": "127.0.0.1", "path": "/token",
             "respond": {"access_token": "dummy", "expires_in": 3600}},
            {"host": "127.0.0.1", "header": "authorization",
             "replace": "XXX", "with": "{cmd:printf real-token}", "fake_env": []},
        ]
        port, ca = start("list", {"session": "e2e", "allow": ["127.0.0.1"],
                                  "rules": rules,
                                  "journal": {"path": journal, "calls": ["127.0.0.1"]}})

        got = fetch(port, ca, f"https://127.0.0.1:{up_port}/api/user",
                    "-H", "Authorization: Bearer XXX")
        check("placeholder replaced", '"auth": "Bearer real-token"' in got, got)
        got = fetch(port, ca, f"https://127.0.0.1:{up_port}/api/user")
        check("no placeholder, header left alone", '"auth": ""' in got, got)

        check("host not in the allow-list is refused",
              code(port, ca, f"https://127.0.0.2:{up_port}/") == "403")

        for label, request in (
            ("absolute URI", f"GET http://127.0.0.2:{up_port}/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
            ("CONNECT", f"CONNECT 127.0.0.2:{up_port} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),
        ):
            with socket.create_connection(("127.0.0.1", port), timeout=5) as conn:
                conn.sendall(request.encode())
                status = conn.recv(4096).split(b"\r\n", 1)[0]
            check(f"spoofed Host cannot bypass {label} destination", b" 403 " in status, status)
        check("Host spoofing inside an allowed TLS tunnel is refused",
              code(port, ca, f"https://127.0.0.1:{up_port}/", "-H", "Host: 127.0.0.2") == "403")

        got = fetch(port, ca, "-X", "POST", f"https://127.0.0.1:{up_port}/token", "-d", "{}")
        check("respond rule answers", '"access_token": "dummy"' in got, got)
        got = fetch(port, ca, f"http://127.0.0.1:{http_port}/api/user",
                    "-H", "Authorization: Bearer box-proxy-placeholder")
        check("HTTP passes through with the client placeholder, never the host token",
              got == json.dumps({"auth": "Bearer box-proxy-placeholder"}), got)
        check("HTTP synthetic responses still work",
              code(port, ca, f"http://127.0.0.1:{http_port}/token", "-X", "POST") == "200")

        fetch(port, ca, "-N", "-X", "POST", f"https://127.0.0.1:{up_port}/v1/chat/completions",
              "-d", "{}")
        time.sleep(0.5)
        records = [json.loads(l) for l in open(journal)] if os.path.exists(journal) else []
        check("tool call journaled", len(records) == 1, records)
        if records:
            r = records[0]
            check("journal names the call", r.get("tool") == "bash" and r.get("id") == "call_1", r)
            check("journal has the whole arguments", r.get("arguments") == '{"command":"ls"}', r)
            check("journal carries the session", r.get("session") == "e2e", r)
        check("the real token never reached the upstream as a placeholder",
              "Bearer real-token" in CALLS and "XXX" not in " ".join(CALLS), CALLS)

        # allow: "none" -- the box has no internet through the proxy, not even
        # the host it was fetching from a moment ago.
        port, ca = start("none", {"session": "e2e-none", "allow": "none"})
        check('allow "none" refuses every host',
              code(port, ca, f"https://127.0.0.1:{up_port}/") == "403")

        # allow: "all" -- the box's normal network, but still journalled and
        # still able to have a credential added.
        port, ca = start("all", {"session": "e2e-all", "allow": "all"})
        check('allow "all" passes a host in no list',
              code(port, ca, f"https://127.0.0.2:{up_port}/api/user") == "200")
        check('allow "all" also permits plain HTTP without injected credentials',
              code(port, ca, f"http://127.0.0.1:{http_port}/") == "200")

        # Exercise host env rendering through real TLS, including braces in a key.
        source = os.path.join(tmp, "env-source.json")
        rendered_dir = os.path.join(tmp, "rendered")
        with open(source, "w") as f:
            json.dump({"allow": ["127.0.0.1"], "rules": [
                {"host": "127.0.0.1", "with": "Bearer {env:LOCAL_LLM_API_KEY}",
                 "fake_env": ["LOCAL_LLM_API_KEY"]}]}, f)
        secret = "real{cmd:must-not-run}token"
        subprocess.run([sys.executable, BOX_PROXY, "render", "--config", source, "--dir", rendered_dir],
                       env=dict(os.environ, LOCAL_LLM_API_KEY=secret), check=True, capture_output=True)
        with open(os.path.join(rendered_dir, "proxy.json")) as f:
            # Stand in for the container's read-only /etc/box-proxy bind mount.
            rendered = json.loads(f.read().replace("/etc/box-proxy", rendered_dir))
        port, ca = start("env", rendered)
        got = fetch(port, ca, f"https://127.0.0.1:{up_port}/api/user",
                    "-H", "Authorization: Bearer box-proxy-placeholder")
        check("host env replaces the client placeholder without reinterpreting the key",
              got == json.dumps({"auth": "Bearer " + secret}), got)

        # A config that names no reach is a mistake, not "everything".
        bad = os.path.join(tmp, "bad.json")
        with open(bad, "w") as f:
            json.dump({"rules": []}, f)
        p = subprocess.run([sys.executable, BOX_PROXY, "run", "--config", bad],
                           capture_output=True, text=True)
        check("a config without allow is refused", p.returncode != 0 and "allow" in p.stderr,
              p.stderr)
    finally:
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass
        shutil.rmtree(tmp, ignore_errors=True)

    if fail:
        print("\nfailed: " + ", ".join(fail))
        return 1
    print("\nbox-proxy: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
