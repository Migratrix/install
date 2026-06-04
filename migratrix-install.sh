#!/usr/bin/env bash
#
# migratrix-install — one-shot local setup for the Migratrix agent (macOS / Linux).
#
# It will:
#   1. install mkcert (via your package manager) if it isn't already present
#   2. install mkcert's local CA into the system + browser trust stores
#   3. generate a TLS cert for HOST into ./certs
#   4. point Traefik's file provider (traefik-tls.yml) at that cert
#   5. add a /etc/hosts entry for non-*.localhost hosts
#   6. write HOST + API key into .env (consumed by both compose files)
#
# Usage:
#   scripts/migratrix-install.sh --host <HOST> --api-key <API_KEY>
#
# Defaults: HOST=agent.localhost
#
set -euo pipefail

HOST="agent.localhost"
API_KEY=""
GITHUB_TOKEN=""
GITHUB_USER="migratrix-bot"

usage() {
  cat >&2 <<EOF
Usage: $0 --host <HOST> --api-key <API_KEY> [--github-token <PAT>] [--github-user <USER>]

  --host          Public hostname Traefik serves the agent on (default: agent.localhost)
  --api-key       Migratrix agent API key (required)
  --github-token  GitHub PAT for ghcr.io (required to pull prod images; omit for local builds)
  --github-user   GitHub user for ghcr.io login (default: migratrix-bot)
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)         HOST="${2:-}"; shift 2 ;;
    --api-key)      API_KEY="${2:-}"; shift 2 ;;
    --github-token) GITHUB_TOKEN="${2:-}"; shift 2 ;;
    --github-user)  GITHUB_USER="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$HOST" ]    || { echo "error: --host cannot be empty" >&2; usage; }
[ -n "$API_KEY" ] || { echo "error: --api-key is required" >&2; usage; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$REPO_ROOT/certs"
TLS_FILE="$REPO_ROOT/traefik-tls.yml"
ENV_FILE="$REPO_ROOT/.env"

# --- 1. ensure mkcert is installed -----------------------------------------
if ! command -v mkcert >/dev/null 2>&1; then
  echo "mkcert not found — attempting to install…"
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install mkcert nss
      else
        echo "error: Homebrew not found. Install mkcert manually:" >&2
        echo "       https://github.com/FiloSottile/mkcert#installation" >&2
        exit 1
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y libnss3-tools mkcert
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y nss-tools mkcert
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy --noconfirm nss mkcert
      else
        echo "error: no supported package manager (apt/dnf/pacman) found." >&2
        echo "       Install mkcert manually: https://github.com/FiloSottile/mkcert#installation" >&2
        exit 1
      fi
      ;;
    *)
      echo "error: unsupported OS '$(uname -s)'. Install mkcert manually:" >&2
      echo "       https://github.com/FiloSottile/mkcert#installation" >&2
      exit 1
      ;;
  esac
fi
command -v mkcert >/dev/null 2>&1 || { echo "error: mkcert still not on PATH after install" >&2; exit 1; }

# --- 2. install the local CA into system + browser trust stores ------------
mkcert -install

# --- 3. generate a cert for HOST -------------------------------------------
mkdir -p "$CERTS_DIR"
CERT_PEM="$CERTS_DIR/$HOST.pem"
KEY_PEM="$CERTS_DIR/$HOST-key.pem"
mkcert -cert-file "$CERT_PEM" -key-file "$KEY_PEM" "$HOST" "*.localhost" localhost 127.0.0.1 ::1
echo "Generated $CERT_PEM"

# --- 4. point Traefik's file provider at the new cert ----------------------
cat > "$TLS_FILE" <<EOF
tls:
  certificates:
    - certFile: /certs/$HOST.pem
      keyFile: /certs/$HOST-key.pem
EOF
echo "Updated $TLS_FILE"

# --- 5. /etc/hosts entry for non-*.localhost hosts -------------------------
case "$HOST" in
  *.localhost)
    : # *.localhost resolves to loopback automatically on macOS/Linux
    ;;
  *)
    if ! grep -qE "[[:space:]]${HOST}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
      echo "Adding 127.0.0.1 $HOST to /etc/hosts (sudo)…"
      printf '127.0.0.1\t%s\n' "$HOST" | sudo tee -a /etc/hosts >/dev/null
    fi
    ;;
esac

# --- 6. write env ----------------------------------------------------------
if [ ! -f "$ENV_FILE" ] && [ -f "$REPO_ROOT/.env.example" ]; then
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  echo "Seeded $ENV_FILE from .env.example"
fi
touch "$ENV_FILE"
set_env() {
  local key="$1" val="$2" tmp
  if grep -qE "^${key}=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    grep -vE "^${key}=" "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
}
set_env AGENT_HOST "$HOST"
set_env MIGRATRIX_API_KEY "$API_KEY"
echo "Updated $ENV_FILE (AGENT_HOST, MIGRATRIX_API_KEY)"

# --- 7. log in to ghcr.io (only when a token is supplied) ------------------
if [ -n "$GITHUB_TOKEN" ]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "error: --github-token given but docker is not installed" >&2
    exit 1
  fi
  printf '%s' "$GITHUB_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin
  echo "Logged in to ghcr.io as $GITHUB_USER"
else
  echo "No --github-token supplied — skipping ghcr.io login (fine for local builds)"
fi

cat <<EOF

✅ Done. Start the agent:
   cd "$REPO_ROOT"
   docker compose up -d

   Agent will be reachable at: https://$HOST
EOF
