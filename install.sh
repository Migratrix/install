#!/usr/bin/env bash
#
# Migratrix bootstrap (macOS / Linux).
#
# This is the PUBLIC one-liner entrypoint. It downloads the compose file, the
# .env template and the real installer into a working directory, then hands off
# to the installer. The installer pulls the container images (ghcr.io): anonymously,
# or with --github-token when Migratrix gave you a registry token.
#
# Usage:
#   curl -fsSL https://get.migratrix.com/install.sh | bash -s -- \
#     --host agent.acme.com --api-key mgx_xxx --github-token ghp_xxx
#
# Overridable via env:
#   MIGRATRIX_BASE_URL  where to fetch the public files (default: https://get.migratrix.com)
#   MIGRATRIX_DIR       working dir to install into     (default: $HOME/migratrix)
#
set -euo pipefail

BASE="${MIGRATRIX_BASE_URL:-https://get.migratrix.com}"
WORKDIR="${MIGRATRIX_DIR:-$HOME/migratrix}"

echo "Migratrix bootstrap"
echo "  source:      $BASE"
echo "  working dir: $WORKDIR"

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

mkdir -p "$WORKDIR/scripts"
cd "$WORKDIR"

fetch() { curl -fsSL "$BASE/$1" -o "$2" && echo "  fetched $1"; }

fetch docker-compose.yml   docker-compose.yml
fetch .env.example         .env.example
fetch migratrix-install.sh scripts/migratrix-install.sh
chmod +x scripts/migratrix-install.sh

echo "Running installer…"
exec ./scripts/migratrix-install.sh "$@"
