#!/usr/bin/env bash
# Self-test for pool.py (no GPUs needed).
# Bootstraps a local .venv with the dependencies and runs pool.py --test.
# With mise, the python pinned in mise.toml is used automatically.
set -euo pipefail
cd "$(dirname "$0")"

python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
.venv/bin/python pool.py --test
