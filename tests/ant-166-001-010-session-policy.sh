#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$ROOT/tests/ant-166-session-policy.py"
