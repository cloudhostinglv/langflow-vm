#!/usr/bin/env bash
# firstboot.sh — one-shot first-boot provisioning for the Langflow per-client VM.
# Runs ONCE via langflow-firstboot.service. Idempotent; disables itself at the end.
# Vanilla product: brings up Langflow on its own standard port (:7860), no CloudHosting
# panel/Caddy layer. Login = admin / LANGFLOW_ADMIN_PASSWORD; provider config is done
# inside Langflow (avots = OpenAI-compatible).
#   1. Ensure LANGFLOW_SECRET_KEY + LANGFLOW_ADMIN_PASSWORD in .env (generate if absent).
#   2. docker compose pull && up -d ; 3. disable this oneshot.

set -euo pipefail

APP_DIR="/opt/langflow-vm"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"
touch "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"

# Generate LANGFLOW_SECRET_KEY (crypto/JWT) if absent — stable per VM.
if ! grep -q '^LANGFLOW_SECRET_KEY=.' "${ENV_FILE}" 2>/dev/null; then
  VAL="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -i '/^LANGFLOW_SECRET_KEY=$/d' "${ENV_FILE}" 2>/dev/null || true
  printf 'LANGFLOW_SECRET_KEY=%s\n' "${VAL}" >> "${ENV_FILE}"
  log "Generated LANGFLOW_SECRET_KEY"
fi

# Ensure an admin password (the provisioner normally writes one; generate + log a
# fallback so the product never comes up with an empty superuser password).
if ! grep -q '^LANGFLOW_ADMIN_PASSWORD=.' "${ENV_FILE}" 2>/dev/null; then
  PW="$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-20)"
  sed -i '/^LANGFLOW_ADMIN_PASSWORD=$/d' "${ENV_FILE}" 2>/dev/null || true
  printf 'LANGFLOW_ADMIN_PASSWORD=%s\n' "${PW}" >> "${ENV_FILE}"
  log "No LANGFLOW_ADMIN_PASSWORD provided; generated one: ${PW}  (login: admin / ${PW})"
fi

log "docker compose pull"; docker compose -f "${COMPOSE_FILE}" pull
log "docker compose up -d"; docker compose -f "${COMPOSE_FILE}" up -d

log "Disabling langflow-firstboot.service (provisioning complete)"
systemctl disable langflow-firstboot.service 2>/dev/null || true

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
log "First boot complete. Langflow: http://${IP:-<host>}:7860 (login: admin / LANGFLOW_ADMIN_PASSWORD)."
