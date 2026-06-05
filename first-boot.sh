#!/usr/bin/env bash
# first-boot.sh — bring the Langflow stack up and materialize env-sourced global
# variables by performing one superuser login (works around upstream issue #11119,
# where LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT are not synced to the DB until
# the first superuser authentication).
#
# Idempotent: safe to re-run. Reads all credentials from the environment / .env.
#
# Usage:
#   cd /srv/avots-vm/langflow && ./first-boot.sh
# Credentials are read from .env (LANGFLOW_SUPERUSER / LANGFLOW_SUPERUSER_PASSWORD).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env so we have the superuser creds (without clobbering already-set env).
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${LANGFLOW_SUPERUSER:?LANGFLOW_SUPERUSER must be set (in .env)}"
: "${LANGFLOW_SUPERUSER_PASSWORD:?LANGFLOW_SUPERUSER_PASSWORD must be set (in .env)}"

# Langflow is reachable on the host loopback bind from docker-compose.yml.
LF_LOCAL="${LF_LOCAL:-http://127.0.0.1:7860}"

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"; else docker-compose "$@"; fi
}

echo "== 1) Bring the stack up =="
compose up -d

echo "== 2) Wait for Langflow to answer on ${LF_LOCAL} =="
ready=""
for i in $(seq 1 60); do
  # /health_check is the readiness probe; fall back to /health on older tags.
  if curl -fsS -o /dev/null "${LF_LOCAL}/health_check" 2>/dev/null \
     || curl -fsS -o /dev/null "${LF_LOCAL}/health" 2>/dev/null; then
    ready="yes"; break
  fi
  sleep 5
done
if [ -z "$ready" ]; then
  echo "ERROR: Langflow did not become ready in time." >&2
  compose logs --tail=50 langflow >&2 || true
  exit 1
fi
echo "  Langflow is up."

echo "== 3) Superuser login (materializes env-sourced global variables, issue #11119) =="
# POST /api/v1/login uses OAuth2 password form (x-www-form-urlencoded: username/password).
http_code="$(curl -sS -o /tmp/lf_login.json -w '%{http_code}' \
  -X POST "${LF_LOCAL}/api/v1/login" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "username=${LANGFLOW_SUPERUSER}" \
  --data-urlencode "password=${LANGFLOW_SUPERUSER_PASSWORD}")"

if [ "$http_code" = "200" ]; then
  echo "  Login OK (HTTP 200). Env-sourced global variables (e.g. AVOTS_API_KEY) are now synced."
else
  echo "ERROR: superuser login returned HTTP ${http_code}." >&2
  head -c 400 /tmp/lf_login.json >&2 || true; echo >&2
  echo "  Check LANGFLOW_SUPERUSER / LANGFLOW_SUPERUSER_PASSWORD in .env." >&2
  exit 1
fi
rm -f /tmp/lf_login.json

echo
echo "== READY =="
echo "  Public URL : https://${DOMAIN:-<DOMAIN-not-set>}/"
echo "  Login as   : ${LANGFLOW_SUPERUSER}"
echo "  avots base : ${OPENAI_API_BASE:-https://api.avots.ai/openai/v1}"
echo "  Note: Caddy may take ~30-60s on first boot to obtain the TLS certificate for ${DOMAIN:-<DOMAIN>}."
