#!/usr/bin/env python3
"""Exercise the wrapper and its in-container shell command without GPUs or Podman."""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

WRAPPER = Path(__file__).with_name("serve-radiance.sh")


class RadianceTests(unittest.TestCase):
    def test_served_name_and_private_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "model.rad").touch()
            # Substitute only the deployment's fixed model directory.
            wrapper = root / "serve.sh"
            source = WRAPPER.read_text()
            self.assertIn("MODEL_DIR=/opt/localllm/models", source)
            wrapper.write_text(source.replace("MODEL_DIR=/opt/localllm/models", f'MODEL_DIR="{tmp}"'))
            commands = {
                "podman": """import json, sys
if sys.argv[1:3] != ['image', 'exists']:
    print(json.dumps(sys.argv[1:]))
""",
                "rad-yaml": "import json, sys; print(json.dumps(sys.argv[1:]))\n",
                "radiance": """import json, os, stat, sys
assert sys.argv[1] == '--config'
path = sys.argv[2]
print(json.dumps({'path': path, 'mode': stat.S_IMODE(os.stat(path).st_mode),
                  'args': json.load(open(path))}))
os.unlink(path)
""",
            }
            for name, body in commands.items():
                path = root / name
                path.write_text("#!/usr/bin/env python3\n" + body)
                path.chmod(0o700)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                       PORT="8080", GPUS="0,1", MAXLEN="262144", NAME="pool-flint-8080")
            result = subprocess.run(["bash", str(wrapper), "model.rad", "--kv-cache-dtype", "i8"],
                                    env=env, capture_output=True, text=True, check=True)
            args = json.loads(result.stdout)
            # The sh $0 placeholder is deliberately not Podman's '--' separator.
            i = args.index("-ec")
            self.assertEqual(args[i + 2], "_")
            self.assertEqual(args[i + 3:i + 5], ["--served-model-name", "flint"])
            self.assertEqual(args[args.index("--tp") + 1], "2")
            self.assertEqual(args[-2:], ["--kv-cache-dtype", "i8"])
            result = subprocess.run(["sh", *args[i:]], env=env, capture_output=True,
                                    text=True, check=True)
            config = json.loads(result.stdout)
            self.assertEqual(config["mode"], stat.S_IRUSR | stat.S_IWUSR)
            self.assertNotEqual(config["path"], "/tmp/radiance.yaml")
            self.assertEqual(config["args"], args[i + 3:])
            self.assertIn("radiance config:", result.stderr)
            self.assertIn("--served-model-name", result.stderr)
            for name in ("manual", "flint-8080", "pool-flint-8081", "pool--8080"):
                with self.subTest(name=name):
                    result = subprocess.run(["bash", str(wrapper), "model.rad"],
                                            env=dict(env, NAME=name), capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("must be pool-<preset>-8080", result.stderr)


if __name__ == "__main__":
    unittest.main()
