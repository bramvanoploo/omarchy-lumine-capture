#!/usr/bin/env bash
# Delegate preview rendering to the new preview generator in preview/
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$root/preview/generate-preview.sh" "$@"
