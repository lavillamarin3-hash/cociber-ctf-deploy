#!/usr/bin/env bash
set -Eeuo pipefail
set +x
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec python3 "$ROOT_DIR/tools/bootstrap_database.py" "$@"
