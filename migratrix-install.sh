#!/usr/bin/env bash
#
# migratrix-install — one-shot local setup for the Migratrix agent (macOS / Linux).
#
# Prepares the working directory for `docker compose up`, tailored to a TLS mode:
#   localhost  mkcert-trusted cert for agent.localhost   (default on a machine with a desktop: the agent is
#              reached by a browser on this same machine only)
#   managed    Migratrix issues a subdomain + cert when the agent registers
#   custom     your domain; cert uploaded in Settings → Agents → Configure Agent, pushed on register
#   ip         direct IP;  cert uploaded in Settings → Agents → Configure Agent, pushed on register
#
# On a server without a desktop there is no default: choose --mode managed, custom or ip.
#
# Every mode lays down ./certs, ./traefik/dynamic/tls.yml (a bootstrap cert so
# Traefik serves TLS immediately) and .env. For non-localhost modes the agent
# hot-swaps the real certificate in after it connects to the orchestrator.
#
# Usage:
#   migratrix-install.sh [--api-key <KEY>] [--mode <MODE>] [--host <HOST>] [--orchestrator-url <URL>] \
#                        [--github-token <TOKEN>] [--github-user <USER>] [--no-pull]
#   migratrix-install.sh --upgrade [--github-token <TOKEN>] [--github-user <USER>] [--no-pull]
#
# Image versions: the installer writes the released image tags (versions.env, downloaded and checked by the
# bootstrap) into .env. They are fixed tags - nothing here follows "latest" - so the machine stays on them until
# the installer is run again with --upgrade, which keeps the key, the mode and the host of the install, writes
# the newly released tags, pulls them and restarts the containers.
#
# The agent key: --api-key, or the MIGRATRIX_API_KEY environment variable, or - with neither - the installer asks
# for it without echoing it (nothing in the shell history or the process list).
#
# Images: without --github-token the installer does not log in to the registry and pulls the images anonymously;
# when the registry refuses, it stops with a message saying so (it never logs in with a placeholder).
#
# No signing key is needed: the agent validates sign-in tokens with the public keys its orchestrator
# publishes at <orchestrator-url>/.well-known/jwks.json.
#
set -euo pipefail

MODE=""
HOST=""
API_KEY=""
ORCHESTRATOR_URL=""
GITHUB_TOKEN=""
GITHUB_USER="migratrix-bot"
PULL=1
UPGRADE=0

usage() {
  cat >&2 <<EOF
Usage: $0 [--api-key <KEY>] [--mode <MODE>] [--host <HOST>] [--orchestrator-url <URL>] [--github-token <TOKEN>] [--github-user <USER>] [--no-pull]
       $0 --upgrade [--github-token <TOKEN>] [--github-user <USER>] [--no-pull]

  --api-key       Migratrix agent API key, from Settings → Agents in the Platform. Without it the installer
                  reads MIGRATRIX_API_KEY from the environment, or asks for the key without echoing it.
  --mode          How the agent is reached: localhost | managed | custom | ip
                    localhost: a browser on this same machine only (default on a machine with a desktop)
                    a server without a desktop has no default: choose managed, custom or ip
  --host          Hostname Traefik serves the agent on
                    localhost: defaults to agent.localhost
                    custom/ip: required (your domain / public IP)
                    managed:   ignored (assigned by Migratrix at registration)
  --orchestrator-url  The orchestrator the agent connects to (default: https://api.migratrix.com;
                  on-premise: your own orchestrator's URL)
  --github-token  Registry read token for ghcr.io, when Migratrix gave you one (omit to pull anonymously)
  --github-user   User for the ghcr.io login (default: migratrix-bot)
  --no-pull       Do not pull the images now (local builds, or Docker not running yet)
  --upgrade       Move an installed agent to the released image versions: keeps its key, mode and host,
                  writes the new versions into .env, pulls them and restarts the containers
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
    --upgrade)      UPGRADE=1; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTS_DIR="$REPO_ROOT/certs"
DYNAMIC_DIR="$REPO_ROOT/traefik/dynamic"
TLS_FILE="$DYNAMIC_DIR/tls.yml"
ENV_FILE="$REPO_ROOT/.env"
VERSIONS_FILE="$REPO_ROOT/versions.env"

# The last value of a key in a KEY=value file; empty when the file or the key is not there.
value_of() { # value_of <file> <key>
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- | tr -d '\r' || true
}

# --- the released image versions --------------------------------------------
# Read before anything is written: a set that is missing or not made of fixed tags stops the install.
IMAGE_KEYS="AGENT_TAG RISK_TAG SQLGLOT_TAG JAVA_ANALYZER_TAG PYTHON_ANALYZER_TAG"
if [ ! -f "$VERSIONS_FILE" ]; then
  echo "error: $VERSIONS_FILE (the released image versions) is missing. Run the install command again:" >&2
  echo "       curl -fsSL https://get.migratrix.com/install.sh | bash -s -- ..." >&2
  exit 1
fi
for key in $IMAGE_KEYS; do
  value="$(value_of "$VERSIONS_FILE" "$key")"
  # A version X.Y.Z, or the commit an image was built from. Never a tag that moves.
  if ! printf '%s' "$value" | grep -Eq '^(v?[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]{40})$'; then
    echo "error: $key in $VERSIONS_FILE is '${value}', not a released version. Run the install command again;" >&2
    echo "       if it repeats, contact Migratrix support. Nothing was installed." >&2
    exit 1
  fi
done

# --- upgrade: the settings of the install that is already here -----------------
if [ "$UPGRADE" = "1" ]; then
  if [ -n "$MODE$HOST$API_KEY$ORCHESTRATOR_URL" ]; then
    echo "error: --upgrade keeps the settings of the install; leave out --mode, --host, --api-key and --orchestrator-url" >&2
    exit 1
  fi
  API_KEY="$(value_of "$ENV_FILE" MIGRATRIX_API_KEY)"
  MODE="$(value_of "$ENV_FILE" MIGRATRIX_MODE)"
  HOST="$(value_of "$ENV_FILE" AGENT_HOST)"
  if [ -z "$API_KEY" ] || [ -z "$MODE" ]; then
    echo "error: there is no installed agent in $REPO_ROOT to upgrade (no .env with a key and a mode)." >&2
    echo "       Run the installer without --upgrade to install one." >&2
    exit 1
  fi
fi

# A Linux machine without a graphical session: nobody will open a browser on it, so https://agent.localhost and a
# certificate trusted only by this machine are of no use (onboarding trials AGI-03).
is_headless() {
  [ "$(uname -s)" = "Linux" ] || return 1
  [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${XDG_CURRENT_DESKTOP:-}" ]
}

if [ -z "$MODE" ]; then
  if is_headless; then
    cat >&2 <<EOF
error: this machine has no desktop, so the default mode (localhost) would give an agent that only a browser on
       this machine could reach. Choose how the agent is reached:
         --mode managed                      Migratrix assigns a public name and certificate
         --mode custom --host <your domain>  your own name; upload its certificate in Settings → Agents
         --mode ip --host <address>          this machine's address; upload its certificate in Settings → Agents
       (--mode localhost still installs the local-only setup, if that is what you want.)
EOF
    exit 1
  fi
  MODE="localhost"
fi

case "$MODE" in
  localhost) [ -n "$HOST" ] || HOST="agent.localhost" ;;
  custom|ip) [ -n "$HOST" ] || { echo "error: --host is required for --mode $MODE" >&2; usage; } ;;
  managed)   : ;; # hostname is assigned by Migratrix when the agent registers
  *) echo "error: invalid --mode '$MODE' (localhost|managed|custom|ip)" >&2; usage ;;
esac

# The agent key: the option, the environment, or a prompt that does not echo.
[ -n "$API_KEY" ] || [ "$UPGRADE" = "1" ] || API_KEY="${MIGRATRIX_API_KEY:-}"
[ -n "$GITHUB_TOKEN" ] || GITHUB_TOKEN="${MIGRATRIX_GITHUB_TOKEN:-}"
if [ -z "$API_KEY" ] && ( : > /dev/tty ) 2>/dev/null; then
  printf 'Migratrix agent API key (Settings → Agents in the Platform; input is hidden): ' > /dev/tty
  IFS= read -rs API_KEY < /dev/tty || API_KEY=""
  printf '\n' > /dev/tty
fi
[ -n "$API_KEY" ] || { echo "error: no agent API key: pass --api-key, or set MIGRATRIX_API_KEY" >&2; usage; }

# Placeholders copied from an example are refused before anything is installed or written.
case "$API_KEY" in
  *xxxx*|"<"*">"|mgx_xxx) echo "error: the API key is a placeholder; copy the real key from Settings → Agents in the Platform" >&2; exit 1 ;;
esac
case "$GITHUB_TOKEN" in
  *xxxx*|"<"*">") echo "error: --github-token is a placeholder; leave it out to pull anonymously, or pass the token Migratrix gave you" >&2; exit 1 ;;
esac

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
if [ "$UPGRADE" = "1" ]; then
  echo "Upgrade: the certificate and the settings of the install (mode: $MODE) are kept."
elif [ "$MODE" = "localhost" ]; then
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
# .env holds the agent key: its owner only (SEC-06).
( umask 077; touch "$ENV_FILE" )
chmod 600 "$ENV_FILE"
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
# The released image versions. What ran before is kept for the summary of an upgrade.
VERSION_SUMMARY=""
VERSIONS_CHANGED=0
for key in $IMAGE_KEYS; do
  new="$(value_of "$VERSIONS_FILE" "$key")"
  old="$(value_of "$ENV_FILE" "$key")"
  if [ "$old" = "$new" ]; then
    VERSION_SUMMARY="$VERSION_SUMMARY   $key=$new (unchanged)
"
  else
    VERSIONS_CHANGED=1
    VERSION_SUMMARY="$VERSION_SUMMARY   $key=$new${old:+ (was $old)}
"
    set_env "$key" "$new"
  fi
done
chmod 600 "$ENV_FILE"
echo "Updated $ENV_FILE (MIGRATRIX_MODE=$MODE${HOST:+, AGENT_HOST=$HOST}; readable by its owner only)"
echo "Image versions:"
printf '%s' "$VERSION_SUMMARY"

# --- registry login (only with a real token) ------------------------------
# The registry the compose file pulls from (REGISTRY in .env, e.g. ghcr.io/migratrix/).
REGISTRY_PREFIX="$(grep -E '^REGISTRY=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
REGISTRY_HOST="${REGISTRY_PREFIX%%/*}"
[ -n "$REGISTRY_HOST" ] || REGISTRY_HOST="ghcr.io"
# A login to the registry that Docker already holds on this machine (docker login done earlier).
STORED_LOGIN=0
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
if [ -f "$DOCKER_CONFIG_FILE" ] && grep -q "\"$REGISTRY_HOST\"" "$DOCKER_CONFIG_FILE" 2>/dev/null; then
  STORED_LOGIN=1
fi
if [ -n "$GITHUB_TOKEN" ]; then
  command -v docker >/dev/null 2>&1 || { echo "error: --github-token given but docker is not installed" >&2; exit 1; }
  if printf '%s' "$GITHUB_TOKEN" | docker login "$REGISTRY_HOST" -u "$GITHUB_USER" --password-stdin >/dev/null; then
    echo "Logged in to $REGISTRY_HOST as $GITHUB_USER"
  else
    echo "error: $REGISTRY_HOST refused the registry token given with --github-token (expired or wrong?)." >&2
    echo "       Run the installer again with a valid token, or without --github-token to pull anonymously." >&2
    exit 1
  fi
elif [ "$STORED_LOGIN" = "1" ]; then
  echo "No --github-token: the images are pulled with the $REGISTRY_HOST login already stored on this machine"
else
  echo "No --github-token: not logging in to $REGISTRY_HOST; the images are pulled anonymously"
fi

# --- pull the images ---------------------------------------------------------
if [ "$PULL" = "1" ]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if [ "$UPGRADE" = "1" ]; then
      echo "error: Docker is not installed or not running, so the new images were not pulled and the containers" >&2
      echo "       still run the versions they had. .env already names the new versions: start Docker and run" >&2
      echo "       docker compose pull && docker compose up -d   in $REPO_ROOT" >&2
      exit 1
    fi
    echo "Docker is not installed or not running: the images are pulled when you run docker compose up -d"
  elif ! (cd "$REPO_ROOT" && docker compose pull); then
    echo "" >&2
    echo "error: could not pull the Migratrix images from ${REGISTRY_PREFIX:-$REGISTRY_HOST}." >&2
    if [ -z "$GITHUB_TOKEN" ] && [ "$STORED_LOGIN" = "1" ]; then
      echo "       The registry refused the $REGISTRY_HOST login stored on this machine, or the images do not exist there." >&2
      echo "       If Migratrix gave you a registry token, run the installer again with --github-token <token>." >&2
    elif [ -z "$GITHUB_TOKEN" ]; then
      echo "       The registry refused anonymous access. If Migratrix gave you a registry token, run the installer" >&2
      echo "       again with --github-token <token>; otherwise contact Migratrix support." >&2
    else
      echo "       The registry refused the token given with --github-token, or the images do not exist there." >&2
    fi
    exit 1
  fi
fi

# --- upgrade: restart on the new images ---------------------------------------
if [ "$UPGRADE" = "1" ]; then
  if [ "$PULL" = "0" ]; then
    echo ""
    echo "✅ .env names the released versions (--no-pull: nothing was pulled or restarted). To move the containers to them:"
    echo "   cd \"$REPO_ROOT\""
    echo "   docker compose pull && docker compose up -d"
    exit 0
  fi
  if ! (cd "$REPO_ROOT" && docker compose up -d --remove-orphans); then
    echo "error: the new images were pulled but the containers could not be restarted; see the message above." >&2
    echo "       Run   docker compose up -d   in $REPO_ROOT   once it is solved." >&2
    exit 1
  fi
  echo ""
  if [ "$VERSIONS_CHANGED" = "1" ]; then
    echo "✅ Upgraded. The agent restarts and reconnects by itself; Settings → Agents on the Platform shows its version."
  else
    echo "✅ Already on the released versions; nothing to upgrade."
  fi
  echo "   docker compose logs -f agent   shows the agent starting."
  exit 0
fi

# --- next steps ------------------------------------------------------------
cat <<EOF

✅ Done (mode: $MODE). Start the agent:
   cd "$REPO_ROOT"
   docker compose up -d
EOF
case "$MODE" in
  localhost) echo "   Agent will be reachable at: https://$HOST - from a browser on this machine only."
             if is_headless; then
               echo "   This machine has no desktop: for a browser on another machine, run the installer again with"
               echo "   --mode managed, --mode custom --host <your domain> or --mode ip --host <address>."
             fi ;;
  custom|ip) echo "   Reachable at: https://$HOST once the agent connects and its certificate is applied."
             echo "   The HTTPS port (HTTPS_PORT in .env, 443 by default) must be open to the browsers that use the Platform." ;;
  managed)   echo "   Migratrix will assign a subdomain + certificate after the agent connects." ;;
esac
cat <<EOF

   Then check that the agent connected - a wrong key or an unreachable orchestrator is said there, in words:
   docker compose logs -f agent
   and on the Platform: Settings → Agents shows the agent as Connected.

   The agent stays on the versions installed now. To move it to a newer release, run the install command again
   with --upgrade in place of its other options.
EOF