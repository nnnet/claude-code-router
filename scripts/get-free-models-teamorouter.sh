#!/usr/bin/env bash
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
exec "$SCRIPT_DIR/free-models-provider-common.sh" teamorouter "$@"
