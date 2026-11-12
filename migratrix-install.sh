#!/usr/bin/env bash
#
# migratrix-install — one-shot local setup for the Migratrix agent (macOS / Linux).
#
# Prepares the working directory for `docker compose up`, tailored to a TLS mode:
#   localhost  mkcert-trusted cert for agent.localhost           (default; local dev)
#   managed    Migratrix issues a subdomain + cert when the agent registers
#   custom     your domain; cert uploaded in Account Settings, pushed on register
#   ip         direct IP;  cert uploaded in Account Settings, pushed on register
#
# Every mode lays down ./certs, ./traefik/dynamic/tls.yml (a bootstrap cert so
# Traefik serves TLS immediately) and .env. For non-localhost modes the agent
# hot-swaps the real certificate in after it connects to the orchestrator.
#
# Usage:
#   migratrix-install.sh --api-key <KEY> [--mode <MODE>] [--host <HOST>] [--orchestrator-url <URL>] \
#                        [--github-token <TOKEN>] [--github-user <USER>] [--no-pull]
#
# Images: without --github-token the installer does not log in to the registry and pulls the images anonymously;
# when the registry refuses, it stops with a message saying so (it never logs in with a placeholder).
#
# No signing key is needed: the agent validates sign-in tokens with the public keys its orchestrator
# publishes at <orchestrator-url>/.well-known/jwks.json.
#
set -euo pipefail

MODE="localhost"
HOST=""
API_KEY=""
ORCHESTRATOR_URL=""
GITHUB_TOKEN=""
GITHUB_USER="migratrix-bot"
PULL=1

usage() {
  cat >&2 <<EOF
Usage: $0 --api-key <KEY> [--mode <MODE>] [--host <HOST>] [--orchestrator-url <URL>] [--github-token <TOKEN>] [--github-user <USER>] [--no-pull]

  --api-key       Migratrix agent API key (required)
  --mode          TLS mode: localhost (default) | managed | custom | ip
  --host          Hostname Traefik serves the agent on
                    localhost: defaults to agent.localhost
                    custom/ip: required (your domain / public IP)
                    managed:   ignored (assigned by Migratrix at registration)
  --orchestrator-url  The orchestrator the agent connects to (default: https://api.migratrix.com;
                  on-premise: your own orchestrator's URL)
  --github-token  Registry read token for ghcr.io, when Migratrix gave you one (omit to pull anonymously)
  --github-user   User for the ghcr.io login (default: migratrix-bot)
  --no-pull       Do not pull the images now (local builds, or Docker not running yet)
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode)         MODE="${2:-}"; shift 2 ;;
    --host)         HOST="${2:-}"; shift 2 ;;
    --api-key)      API_KEY="${2:-}"; shift 2 ;;
    --orchestrator-url) ORCHESTRATOR_URL="${2:-}"; shift 2 ;;
    --github-token) GITHUB_TOKEN="${2:-}"; shift 2 ;;
    --github-user)  GITHUB_USER="${2:-}"; shift 2 ;;
    --no-pull)      PULL=0; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

case "$MODE" in
  localhost) [ -n "$HOST" ] || HOST="agent.localhost" ;;
  custom|ip) [ -n "$HOST" ] || { echo "error: --host is required for --mode $MODE" >&2; usage; } ;;
  managed)   : ;; # hostname is assigned by Migratrix when the agent registers
  *) echo "error: invalid --mode '$MODE' (localhost|managed|custom|ip)" >&2; usage ;;
esac
[ -n "$API_KEY" ] || { echo "error: --api-key is required" >&2; usage; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$REPO_ROOT/certs"
DYNAMIC_DIR="$REPO_ROOT/traefik/dynamic"
TLS_FILE="$DYNAMIC_DIR/tls.yml"
ENV_FILE="$REPO_ROOT/.env"
mkdir -p "$CERTS_DIR" "$DYNAMIC_DIR"

# Point Traefik's file provider at /certs/<basename> (+ matching -key.pem).
write_tls() {
  cat > "$TLS_FILE" <<EOF
tls:
  certificates:
    - certFile: /certs/$1
      keyFile: /certs/${1%.pem}-key.pem
EOF
}

ensure_mkcert() {
  command -v mkcert >/dev/null 2>&1 && return 0
  echo "mkcert not found — attempting to install…"
  case "$(uname -s)" in
    Darwin)
      command -v brew >/dev/null 2>&1 || { echo "error: Homebrew not found. Install mkcert: https://github.com/FiloSottile/mkcert#installation" >&2; exit 1; }
      brew install mkcert nss ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y libnss3-tools mkcert
      elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y nss-tools mkcert
      elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm nss mkcert
      else echo "error: no supported package manager. Install mkcert: https://github.com/FiloSottile/mkcert#installation" >&2; exit 1; fi ;;
    *) echo "error: unsupported OS '$(uname -s)'. Install mkcert manually." >&2; exit 1 ;;
  esac
  command -v mkcert >/dev/null 2>&1 || { echo "error: mkcert still not on PATH after install" >&2; exit 1; }
}

# --- TLS bootstrap (mode-specific) -----------------------------------------
if [ "$MODE" = "localhost" ]; then
  ensure_mkcert
  mkcert -install
  # The real cert. Written as agent.crt/agent.key so the agent adopts it.
  mkcert -cert-file "$CERTS_DIR/agent.crt" -key-file "$CERTS_DIR/agent.key" \
    "$HOST" "*.localhost" localhost 127.0.0.1 ::1
  # Seed Traefik with the same cert so it serves immediately.
  cp "$CERTS_DIR/agent.crt" "$CERTS_DIR/live-bootstrap.pem"
  cp "$CERTS_DIR/agent.key" "$CERTS_DIR/live-bootstrap-key.pem"
  write_tls live-bootstrap.pem
  echo "Generated mkcert certificate for $HOST; wrote $TLS_FILE"
else
  # managed/custom/ip: the agent generates a temporary self-signed cert on first
  # boot and hot-swaps the real one (orchestrator-issued / uploaded) after it
  # connects. Traefik serves its built-in default cert until then.
  echo "No local certificate for mode '$MODE' — the agent provisions it after it connects."
fi

# No /etc/hosts entry needed on macOS/Linux: *.localhost auto-resolves to
# loopback, and custom/managed hosts use real DNS (an IP, or your domain).

# --- env -------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ] && [ -f "$REPO_ROOT/.env.example" ]; then
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  echo "Seeded $ENV_FILE from .env.example"
fi
touch "$ENV_FILE"
set_env() {
  local key="$1" val="$2" tmp
  if grep -qE "^${key}=" "$ENV_FILE"; then
    tmp="$(mktemp)"; grep -vE "^${key}=" "$ENV_FILE" > "$tmp"; mv "$tmp" "$ENV_FILE"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
}
set_env MIGRATRIX_MODE "$MODE"
[ -n "$HOST" ] && set_env AGENT_HOST "$HOST"
set_env MIGRATRIX_API_KEY "$API_KEY"
[ -n "$ORCHESTRATOR_URL" ] && set_env MIGRATRIX_ORCHESTRATOR_URL "${ORCHESTRATOR_URL%/}"
# The Risk Assessment API's GitHub webhook secret: generated once, kept on later runs (GitHub holds the same value).
if ! grep -qE "^MIGRATRIX_GITHUB_WEBHOOK_SECRET=.+" "$ENV_FILE"; then
  set_env MIGRATRIX_GITHUB_WEBHOOK_SECRET "$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  echo "Generated MIGRATRIX_GITHUB_WEBHOOK_SECRET in $ENV_FILE (use it as the GitHub webhook secret)"
fi
# Left over from installs that required a shared signing key; the agent no longer reads it.
if grep -qE "^MIGRATRIX_JWT_KEY=" "$ENV_FILE"; then
  tmp="$(mktemp)"; grep -vE "^MIGRATRIX_JWT_KEY=" "$ENV_FILE" > "$tmp"; mv "$tmp" "$ENV_FILE"
fi
echo "Updated $ENV_FILE (MIGRATRIX_MODE=$MODE${HOST:+, AGENT_HOST=$HOST})"

# --- registry login (only with a real token) ------------------------------
# The registry the compose file pulls from (REGISTRY in .env, e.g. ghcr.io/migratrix/).
REGISTRY_PREFIX="$(grep -E '^REGISTRY=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
REGISTRY_HOST="${REGISTRY_PREFIX%%/*}"
[ -n "$REGISTRY_HOST" ] || REGISTRY_HOST="ghcr.io"
case "$GITHUB_TOKEN" in
  *xxxx*|"<"*">") echo "error: --github-token is a placeholder; leave it out to pull anonymously, or pass the token Migratrix gave you" >&2; exit 1 ;;
esac
if [ -n "$GITHUB_TOKEN" ]; then
  command -v docker >/dev/null 2>&1 || { echo "error: --github-token given but docker is not installed" >&2; exit 1; }
  if printf '%s' "$GITHUB_TOKEN" | docker login "$REGISTRY_HOST" -u "$GITHUB_USER" --password-stdin >/dev/null; then
    echo "Logged in to $REGISTRY_HOST as $GITHUB_USER"
  else
    echo "error: $REGISTRY_HOST refused the registry token given with --github-token (expired or wrong?)." >&2
    echo "       Run the installer again with a valid token, or without --github-token to pull anonymously." >&2
    exit 1
  fi
else
  echo "No --github-token: not logging in to $REGISTRY_HOST; the images are pulled anonymously"
fi

# --- pull the images ---------------------------------------------------------
if [ "$PULL" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker is not installed or not running: the images are pulled when you run docker compose up -d"
  elif ! (cd "$REPO_ROOT" && docker compose pull); then
    echo "" >&2
    echo "error: could not pull the Migratrix images from ${REGISTRY_PREFIX:-$REGISTRY_HOST}." >&2
    if [ -z "$GITHUB_TOKEN" ]; then
      echo "       The registry refused anonymous access. If Migratrix gave you a registry token, run the installer" >&2
      echo "       again with --github-token <token>; otherwise contact Migratrix support." >&2
    else
      echo "       The registry refused the token given with --github-token, or the images do not exist there." >&2
    fi
    exit 1
  fi
fi

# --- next steps ------------------------------------------------------------
cat <<EOF

✅ Done (mode: $MODE). Start the agent:
   cd "$REPO_ROOT"
   docker compose up -d
EOF
case "$MODE" in
  localhost) echo "   Agent will be reachable at: https://$HOST" ;;
  custom|ip) echo "   Reachable at: https://$HOST once the agent connects and its certificate is applied." ;;
  managed)   echo "   Migratrix will assign a subdomain + certificate after the agent connects." ;;
esac