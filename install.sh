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
#   curl -fsSL https://get.migratrix.com/install.sh | bash -s -- --api-key <key from Settings → Agents>
#   curl -fsSL https://get.migratrix.com/install.sh | bash -s -- --mode custom --host agent.acme.com
#       (without --api-key the installer asks for the key and does not echo it)
#
# The files it downloads are checked against SHA256SUMS from the same place: a truncated or mixed-up download
# stops the install. (Same origin, so this is an integrity check of the transfer, not a signature.)
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

# --- integrity: every fetched file must match the published checksum ----------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo ""; fi
}
SUMS="$(mktemp)"
trap 'rm -f "$SUMS"' EXIT
if ! curl -fsSL "$BASE/SHA256SUMS" -o "$SUMS"; then
  echo "error: could not download $BASE/SHA256SUMS; the downloaded files cannot be checked. Nothing was installed." >&2
  exit 1
fi
verify() { # verify <published name> <local path>
  local want got
  want="$(awk -v n="$1" '$2 == n || $2 == "*" n { print $1 }' "$SUMS" | head -n1)"
  got="$(sha256_of "$2")"
  if [ -z "$got" ]; then
    echo "error: neither sha256sum nor shasum is installed; the downloaded files cannot be checked." >&2; exit 1
  fi
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "error: $1 does not match its published checksum (download damaged or changed). Nothing was installed." >&2
    exit 1
  fi
}
verify docker-compose.yml   docker-compose.yml
verify .env.example         .env.example
verify migratrix-install.sh scripts/migratrix-install.sh
echo "  checksums ok"
trap - EXIT
rm -f "$SUMS"

echo "Running installer…"
exec ./scripts/migratrix-install.sh "$@"
