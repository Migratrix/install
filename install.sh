#!/usr/bin/env bash
#
# Migratrix bootstrap (macOS / Linux).
#
# This is the PUBLIC one-liner entrypoint. It downloads the compose file, the
# .env template, the released image versions and the real installer into a working
# directory, then hands off to the installer. The installer pulls the container images (ghcr.io): anonymously,
# or with --github-token when Migratrix gave you a registry token.
#
# Usage:
#   curl -fsSL https://get.migratrix.com/install.sh | bash -s -- --api-key <key from Settings → Agents>
#   curl -fsSL https://get.migratrix.com/install.sh | bash -s -- --mode custom --host agent.acme.com
#       (without --api-key the installer asks for the key and does not echo it)
#   curl -fsSL https://get.migratrix.com/install.sh | bash -s -- --upgrade
#       (an installed agent: moves it to the released versions, keeps its key and settings)
#
# The files it downloads are checked against SHA256SUMS from the same place: a truncated or mixed-up download
# stops the install. (Same origin, so this is an integrity check of the transfer, not a signature.)
#
# Behind an outgoing proxy: curl reads HTTPS_PROXY (or https_proxy) of the environment, and --proxy <url> is
# used for the downloads too. A proxy that inspects TLS: give curl its CA yourself for the downloads
# (CURL_CA_BUNDLE=<pem>, also for the curl of the one-liner: curl --cacert <pem> ...), and pass --ca-file <pem>
# so that the agent trusts it.
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

# The installer's options are passed through untouched. Two of them matter here already: --proxy is also the
# proxy of the downloads below (curl reads HTTPS_PROXY / https_proxy by itself; the option is exported so that
# it does the same), and a relative --ca-file is relative to where the command was run, not to the working
# directory entered below.
# A proxy value is checked here, before anything is downloaded through it, with the installer's own rule and
# words (INST-4: a wrong --proxy used to surface as "could not download", or only after the downloads).
check_proxy_url() { # check_proxy_url <what> <value>
  [ -z "$2" ] && return 0
  case "$2" in
    http://*|https://*) : ;;
    *) echo "error: $1 must be a URL that starts with http:// or https:// (for example http://proxy.example.com:3128). Nothing was installed." >&2; exit 1 ;;
  esac
  case "$2" in
    *[[:space:]\$\'\"\`]*) echo "error: $1 holds a space, a quote or a \$ sign; write such characters of the user name or password percent-encoded (%24 for \$). Nothing was installed." >&2; exit 1 ;;
  esac
}
PROXY_OPTION=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --proxy)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "error: --proxy needs a value: the proxy's URL, or none. Nothing was installed." >&2; exit 1
      fi
      PROXY_OPTION=1
      [ "$2" = "none" ] || check_proxy_url "--proxy" "$2"
      if [ -n "${2:-}" ] && [ "$2" != "none" ]; then export HTTPS_PROXY="$2" HTTP_PROXY="$2" https_proxy="$2" http_proxy="$2"; fi
      if [ "${2:-}" = "none" ]; then unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy; ARGS+=("--proxy" "none"); fi
      shift; [ $# -gt 0 ] && shift ;;
    --ca-file)
      ca="${2:-}"
      case "$ca" in ""|none|/*) : ;; *) ca="$PWD/$ca" ;; esac
      ARGS+=("--ca-file" "$ca"); shift; [ $# -gt 0 ] && shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if [ -n "${MIGRATRIX_EXTRA_CA_FILE:-}" ]; then
  case "$MIGRATRIX_EXTRA_CA_FILE" in /*) : ;; *) export MIGRATRIX_EXTRA_CA_FILE="$PWD/$MIGRATRIX_EXTRA_CA_FILE" ;; esac
fi
# Without --proxy the installer takes the proxy from the environment: the same check, before the downloads.
if [ "$PROXY_OPTION" = "0" ]; then
  check_proxy_url "the HTTPS proxy of the environment (HTTPS_PROXY)" "${HTTPS_PROXY:-${https_proxy:-}}"
  check_proxy_url "the HTTP proxy of the environment (HTTP_PROXY)" "${HTTP_PROXY:-${http_proxy:-}}"
fi

# Everything is downloaded into a fresh temporary folder and checked THERE. Only files that passed the check
# are moved into the working directory: a failed download or a wrong checksum leaves the working directory (and
# an existing installation's compose file) exactly as it was, so "Nothing was installed" is true (N-R2A-6).
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/migratrix-bootstrap.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/scripts"

fetch() { curl -fsSL "$BASE/$1" -o "$STAGE/$2" && echo "  fetched $1"; }
fail_download() {
  echo "error: could not download $BASE/$1. Nothing was installed." >&2
  exit 1
}

fetch docker-compose.yml   docker-compose.yml           || fail_download docker-compose.yml
fetch .env.example         .env.example                 || fail_download .env.example
fetch versions.env         versions.env                 || fail_download versions.env
fetch migratrix-install.sh scripts/migratrix-install.sh || fail_download migratrix-install.sh

# --- integrity: every fetched file must match the published checksum ----------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo ""; fi
}
SUMS="$STAGE/SHA256SUMS"
if ! curl -fsSL "$BASE/SHA256SUMS" -o "$SUMS"; then
  echo "error: could not download $BASE/SHA256SUMS; the downloaded files cannot be checked. Nothing was installed." >&2
  exit 1
fi
verify() { # verify <published name> <path under the temporary folder>
  local want got
  want="$(awk -v n="$1" '$2 == n || $2 == "*" n { print $1 }' "$SUMS" | head -n1)"
  got="$(sha256_of "$STAGE/$2")"
  if [ -z "$got" ]; then
    echo "error: neither sha256sum nor shasum is installed; the downloaded files cannot be checked. Nothing was installed." >&2; exit 1
  fi
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "error: $1 does not match its published checksum (download damaged or changed). Nothing was installed." >&2
    exit 1
  fi
}
verify docker-compose.yml   docker-compose.yml
verify .env.example         .env.example
verify versions.env         versions.env
verify migratrix-install.sh scripts/migratrix-install.sh
echo "  checksums ok"

# --- checked: now, and only now, into the working directory -------------------
mkdir -p "$WORKDIR/scripts"
for f in docker-compose.yml .env.example versions.env scripts/migratrix-install.sh; do
  mv -f "$STAGE/$f" "$WORKDIR/$f"
done
chmod +x "$WORKDIR/scripts/migratrix-install.sh"
trap - EXIT
rm -rf "$STAGE"
cd "$WORKDIR"

echo "Running installer…"
exec ./scripts/migratrix-install.sh ${ARGS[@]+"${ARGS[@]}"}
