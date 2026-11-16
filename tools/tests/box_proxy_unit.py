#!/usr/bin/env python3
"""Dependency-free regression tests: python3 tools/tests/box_proxy_unit.py."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
CLI = runpy.run_path(str(TOOLS / "box-proxy"))

# Only the small HTTP surface used by request() is needed here.
mitm = types.ModuleType("mitmproxy")
mitm.ctx = types.SimpleNamespace(log=types.SimpleNamespace(info=lambda msg: None),
                                 options=types.SimpleNamespace(update=lambda **kw: None))
mitm.http = types.SimpleNamespace(
    HTTPFlow=object,
    Response=types.SimpleNamespace(make=lambda code, body, headers: types.SimpleNamespace(
        status_code=code, content=body)))
spec = importlib.util.spec_from_file_location("addon", TOOLS / "box-proxy-addon.py")
addon = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, mitmproxy=mitm):
    spec.loader.exec_module(addon)


class ProxyTests(unittest.TestCase):
    def flow(self, host="api.example.com"):
        return types.SimpleNamespace(request=types.SimpleNamespace(
            host=host, pretty_host=host, scheme="https", path="/", method="GET", headers={}), response=None)

    def test_header_controls_are_rejected_without_leaking_value(self):
        proxy = addon.BoxProxy()
        proxy.allow_all = True
        proxy.rules = [{"host": "*", "with": "{env:TOKEN}"}]
        for control in ("\r", "\n", "\t", "\x00", "\x1f", "\x7f"):
            with self.subTest(control=repr(control)):
                with patch.object(addon.CREDS, "get", return_value="secret" + control + "suffix"):
                    flow = self.flow()
                    proxy.request(flow)
                    self.assertEqual(flow.response.status_code, 502)
                    self.assertNotIn(b"secret", flow.response.content)
                    self.assertEqual(flow.request.headers, {})

    def test_host_matching_and_denial_json(self):
        proxy = addon.BoxProxy()
        proxy.calls = object()
        proxy.journal = {"calls": ["*.example.com"]}
        self.assertTrue(proxy._journals(self.flow()))
        self.assertFalse(proxy._journals(self.flow("other.com")))
        proxy.rules = [{"with": "secret"}]
        self.assertIsNone(proxy.rule(self.flow()))
        flow = self.flow('bad"\\host')
        proxy.request(flow)
        self.assertEqual(json.loads(flow.response.content)["host"], flow.request.pretty_host)

    def test_destination_spoofing_and_connect(self):
        proxy = addon.BoxProxy()
        proxy.allow = ["api.example.com"]
        proxy.rules = [{"host": "api.example.com", "with": "{env:TOKEN}"}]
        for target, claimed in (("attacker.example", "api.example.com"),
                                ("api.example.com", "attacker.example")):
            flow = self.flow(target)
            flow.request.pretty_host = claimed
            with patch.object(addon.CREDS, "get") as get:
                proxy.request(flow)
                self.assertEqual(flow.response.status_code, 403)
                get.assert_not_called()
            for hook in (proxy.http_connect, proxy.requestheaders):
                flow.response = None
                hook(flow)
                self.assertEqual(flow.response.status_code, 403)
        flow = self.flow()
        proxy.http_connect(flow)
        self.assertIsNone(flow.response)

    def test_http_passes_without_resolving_or_injecting_host_credentials(self):
        proxy = addon.BoxProxy()
        proxy.allow = ["api.example.com"]
        proxy.rules = [{"host": "api.example.com", "with": "Bearer {env:TOKEN}"}]
        for hook in (proxy.requestheaders, proxy.request):
            flow = self.flow()
            flow.request.scheme = "http"
            flow.request.headers["authorization"] = "Bearer placeholder"
            with patch.object(addon.CREDS, "get") as get:
                hook(flow)
                self.assertIsNone(flow.response)
                self.assertEqual(flow.request.headers, {"authorization": "Bearer placeholder"})
                get.assert_not_called()
        flow = self.flow()
        with patch.object(addon.CREDS, "get", return_value="real-token") as get:
            proxy.request(flow)
            self.assertEqual(flow.request.headers["authorization"], "Bearer real-token")
            get.assert_called_once()
        proxy.rules = [{"host": "api.example.com", "respond": {"token": "dummy"}}]
        flow = self.flow()
        flow.request.scheme = "http"
        proxy.request(flow)
        self.assertEqual(flow.response.status_code, 200)

    def test_rendered_secrets_are_not_reinterpreted(self):
        with tempfile.TemporaryDirectory() as tmp:
            value = "token{cmd:must-not-run}suffix"
            result = types.SimpleNamespace(stdout=value + "\n")
            with patch.object(subprocess, "run", return_value=result):
                rendered = CLI["render_template"]("Bearer {key}", tmp, [], 60)
            self.assertNotIn(value, rendered)
            files = list(Path(tmp).glob("secret-*"))
            self.assertEqual(len(files), 1)
            self.assertEqual(stat.S_IMODE(files[0].stat().st_mode), 0o600)
            template = rendered.replace("/etc/box-proxy", tmp)
            with patch.object(addon, "CREDS", addon.Creds()):
                self.assertEqual(addon.expand(template, 60), "Bearer " + value)

    def test_host_env_is_rendered_to_a_private_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            value = "real{cmd:not-a-template}token"
            refreshers = []
            with patch.dict(os.environ, LOCAL_LLM_API_KEY=value):
                rendered = CLI["render_template"]("Bearer {env:LOCAL_LLM_API_KEY}", tmp, refreshers, 60)
            self.assertEqual(refreshers, [])
            self.assertNotIn(value, rendered)
            files = list(Path(tmp).glob("secret-*"))
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].read_text(), value)
            self.assertEqual(stat.S_IMODE(files[0].stat().st_mode), 0o600)
            with patch.object(addon, "CREDS", addon.Creds()):
                self.assertEqual(addon.expand(rendered.replace("/etc/box-proxy", tmp), 60), "Bearer " + value)
            for value in ("", "\n"):
                with patch.dict(os.environ, EMPTY_TOKEN=value):
                    with self.assertRaisesRegex(SystemExit, "host variable EMPTY_TOKEN is empty or unset"):
                        CLI["render_template"]("{env:EMPTY_TOKEN}", tmp, [], 60)
            with patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(SystemExit, "host variable MISSING_TOKEN is empty or unset"):
                    CLI["render_template"]("{env:MISSING_TOKEN}", tmp, [], 60)

    def test_config_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            for allow, ttl in (([8080], 60), ([""], 60), ("all", "bad"),
                               ("all", None), ("all", float("inf")), ("all", -1)):
                path.write_text(json.dumps({"allow": allow, "rules": [
                    {"host": "api.example.com", "with": "{key}", "ttl": ttl, "fake_env": []}]}))
                with self.subTest(allow=allow, ttl=ttl), self.assertRaisesRegex(SystemExit, "box-proxy:"):
                    CLI["load_config"](str(path))
            path.write_text('{"allow":"all","rules":[{"host":"*","with":"{key}","ttl":"60","fake_env":[]}]}')
            self.assertEqual(CLI["load_config"](str(path))["rules"][0]["ttl"], 60)

    def test_fake_env_requires_explicit_valid_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            rule = {"host": "api.example.com", "with": "{env:HOST_TOKEN}"}
            path.write_text(json.dumps({"allow": "all", "rules": [rule]}))
            with self.assertRaisesRegex(SystemExit, 'credential rules need "fake_env"'):
                CLI["load_config"](str(path))
            for names in (None, "TOKEN", {}, [123], [""], ["A=B"], ["A-B"], ["A\nB"], ["é"], ["1TOKEN"]):
                path.write_text(json.dumps({"allow": "all", "rules": [dict(rule, fake_env=names)]}))
                with self.subTest(names=names), self.assertRaisesRegex(SystemExit, '"fake_env" must be a list'):
                    CLI["load_config"](str(path))
            for names in ([], ["CLIENT_TOKEN", "lower_case2", "_TOKEN"], ["TOKEN", "TOKEN"]):
                path.write_text(json.dumps({"allow": "all", "rules": [dict(rule, fake_env=names)]}))
                self.assertEqual(CLI["load_config"](str(path))["rules"][0]["fake_env"], names)
            path.write_text('{"allow":"all","rules":[{"host":"*","respond":{}}]}')
            CLI["load_config"](str(path))

    def test_responses_stream_and_nonstream(self):
        item = {"type": "function_call", "id": "fc_1", "call_id": "call_1",
                "name": "bash", "arguments": ""}
        parser = addon.Parser()
        parser.feed({"type": "response.output_item.added", "item": item})
        for delta in ('{"cmd":', '"ls"}'):
            parser.feed({"type": "response.function_call_arguments.delta", "item_id": "fc_1", "delta": delta})
        records = list(parser.records("host", "/v1/responses"))
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["id"], "call_1")
        self.assertEqual(records[0]["arguments"], '{"cmd":"ls"}')
        parser.feed({"type": "response.output_item.done", "item": dict(item, arguments='{"cmd":"ls"}')})
        self.assertEqual(list(parser.records("host", "/"))[0]["arguments"], '{"cmd":"ls"}')
        parser = addon.Parser()
        parser.feed({"output": [dict(item, arguments='{"cmd":"ls"}')]})
        self.assertEqual(list(parser.records("host", "/"))[0]["arguments"], '{"cmd":"ls"}')

    def test_credential_lookups_are_independent_and_single_flight(self):
        creds = addon.Creds()
        started, release, fast = threading.Event(), threading.Event(), threading.Event()
        calls = []
        def lookup(expr):
            calls.append(expr)
            if expr == "slow":
                started.set()
                release.wait(5)
            else:
                fast.set()
            return expr
        with patch.object(creds, "_run", side_effect=lookup):
            threads = [threading.Thread(target=creds.get, args=(expr, 60))
                       for expr in ("slow", "slow", "fast")]
            threads[0].start()
            try:
                self.assertTrue(started.wait(2))
                for t in threads[1:]:
                    t.start()
                self.assertTrue(fast.wait(2))
            finally:
                release.set()
                for t in threads:
                    if t.ident is not None:
                        t.join(5)
            self.assertEqual(calls.count("slow"), 1)

    def test_cli_permissions_and_failed_mint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg = root / "input.json"
            out = root / "state"
            cfg.write_text(json.dumps({"allow": "all", "rules": [
                {"host": "api.example.com", "with": "{cmd:printf token}", "fake_env": ["CLIENT_TOKEN"]}]}))
            args = types.SimpleNamespace(config=str(cfg), dir=str(out), out=None, session=None)
            old = os.umask(0)
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    CLI["cmd_render"](args)
                self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o700)
                for name in ("secret-0", "proxy.json"):
                    self.assertEqual(stat.S_IMODE((out / name).stat().st_mode), 0o600)
                # Run just one refresh iteration, without a long-lived background loop.
                script = (out / "refresh.sh").read_text()
                self.assertIn("umask 077", script)
                command = next(line.strip() for line in script.splitlines() if "base64 -d" in line)
                (out / "secret-0.tmp").write_text("old")
                os.chmod(out / "secret-0.tmp", 0o666)
                subprocess.run(["sh", "-c", "umask 077; " + command], check=True)
                self.assertEqual(stat.S_IMODE((out / "secret-0").stat().st_mode), 0o600)
                cfg.write_text(json.dumps({"allow": "all", "rules": [
                    {"host": "*", "with": "{cmd:echo sensitive >&2; exit 7}", "fake_env": []}]}))
                with self.assertRaises(SystemExit) as exc:
                    CLI["cmd_render"](args)
                self.assertIn("exit 7", str(exc.exception))
                self.assertNotIn("sensitive", str(exc.exception))
                cfg.write_text('{"allow":"all","rules":[{"with":"{token}"}]}')
                with self.assertRaises(SystemExit):
                    CLI["load_config"](str(cfg))
                ca_args = types.SimpleNamespace(confdir=str(root / "ca"))
                (root / "ca").mkdir()
                (root / "ca/mitmproxy-ca-cert.pem").write_text("certificate")
                (root / "ca/mitmproxy-ca-key.pem").write_text("private key")
                with contextlib.redirect_stdout(io.StringIO()):
                    CLI["cmd_ca"](ca_args)
                    for name in ("mitmproxy-ca-key.pem", "mitmproxy-ca.pem"):
                        os.chmod(root / "ca" / name, 0o666)
                    CLI["cmd_ca"](ca_args)
                for name in ("mitmproxy-ca-key.pem", "mitmproxy-ca.pem"):
                    self.assertEqual(stat.S_IMODE((root / "ca" / name).stat().st_mode), 0o600)
                cfg.write_text('{"allow":"none","session":"test"}')
                run_args = types.SimpleNamespace(config=str(cfg), session=None, bind="127.0.0.1:12345",
                    confdir=ca_args.confdir, insecure=False, print_bind=False)
                with patch.dict(CLI["cmd_run"].__globals__, mitmdump=lambda: "/fake/mitmdump"), patch.object(os, "execvpe") as execute:
                    CLI["cmd_run"](run_args)
                env = execute.call_args.args[2]
                runtime = Path(env["BOX_PROXY_CONFIG"])
                self.assertEqual(stat.S_IMODE(runtime.stat().st_mode), 0o600)
                with patch.dict(os.environ, env), patch.object(addon.ctx.options, "update") as update:
                    addon.BoxProxy().load(None)
                update.assert_called_once_with(connection_strategy="lazy", stream_large_bodies="10m")
                self.assertFalse(runtime.exists())
                with patch.dict(CLI["cmd_run"].__globals__, mitmdump=lambda: "/fake/mitmdump"), patch.object(os, "execvpe", side_effect=OSError("failed exec")):
                    with self.assertRaises(OSError):
                        CLI["cmd_run"](run_args)
                self.assertEqual(list((root / "ca").glob("run-*.json")), [])
            finally:
                os.umask(old)


if __name__ == "__main__":
    unittest.main()
