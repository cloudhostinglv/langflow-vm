#!/usr/bin/env bash
# firstboot.sh — one-shot first-boot provisioning for the Langflow per-client VM.
# Runs ONCE via langflow-firstboot.service. Idempotent; disables itself at the end.
# Brings up: langflow (product) + panel (CloudHosting setup UI) + caddy (TLS).
#   1. Generate LANGFLOW_SECRET_KEY into .env if absent (stable per-VM crypto/JWT key).
#   2. Ensure ./paneldata (panel HOME) owned by the panel uid.
#   3. Derive PANEL_DOMAIN from the primary IPv4 if blank.
#   4. docker compose pull && up -d ; 5. disable this oneshot.
# Langflow login = admin / PANEL_PASSWORD (set in compose). No host applier (builder).

set -euo pipefail

APP_DIR="/opt/langflow-vm"
ENV_FILE="${APP_DIR}/.env"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
PANEL_UID="${PANEL_UID:-1000}"
PANEL_GID="${PANEL_GID:-1000}"

log() { printf '[firstboot %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { printf '[firstboot ERROR] %s\n' "$*" >&2; exit 1; }

cd "${APP_DIR}" || die "missing ${APP_DIR}"
touch "${ENV_FILE}"; chmod 0600 "${ENV_FILE}"

if ! grep -q '^LANGFLOW_SECRET_KEY=.' "${ENV_FILE}" 2>/dev/null; then
  VAL="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed -i '/^LANGFLOW_SECRET_KEY=$/d' "${ENV_FILE}" 2>/dev/null || true
  printf 'LANGFLOW_SECRET_KEY=%s\n' "${VAL}" >> "${ENV_FILE}"
  log "Generated LANGFLOW_SECRET_KEY"
fi

mkdir -p "${APP_DIR}/paneldata"
chown -R "${PANEL_UID}:${PANEL_GID}" "${APP_DIR}/paneldata"
chmod 0700 "${APP_DIR}/paneldata"

# shellcheck disable=SC1090
set -a && . "${ENV_FILE}" && set +a || true

if [ -z "${PANEL_DOMAIN:-}" ]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -n1)"
  [ -n "${IP}" ] || IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "${IP}" ] || die "could not determine primary IPv4 to derive PANEL_DOMAIN"
  O3="$(printf '%s' "${IP}" | cut -d. -f3)"; O4="$(printf '%s' "${IP}" | cut -d. -f4)"
  PANEL_DOMAIN="vps-${O3}-${O4}.cloudhosting.lv"
  log "Derived PANEL_DOMAIN=${PANEL_DOMAIN} from IP ${IP}"
  if grep -q '^PANEL_DOMAIN=' "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=${PANEL_DOMAIN}|" "${ENV_FILE}"
  else
    printf 'PANEL_DOMAIN=%s\n' "${PANEL_DOMAIN}" >> "${ENV_FILE}"
  fi
else
  log "PANEL_DOMAIN already set: ${PANEL_DOMAIN}"
fi

log "docker compose pull"; docker compose -f "${COMPOSE_FILE}" pull
log "docker compose up -d"; docker compose -f "${COMPOSE_FILE}" up -d

# --- Install the host-side software updater (panel "Update software" button) ---------
# The panel (unprivileged) writes ./paneldata/.update-request; this host updater
# git-pulls the repo + docker compose pull/up. No applier (builders need no restart).
log "Installing updater units"
APPLIER_LIB="/usr/local/lib/cloudhosting"
install -d -m 0755 "${APPLIER_LIB}"
install -m 0755 "${APP_DIR}/applier/update.sh" "${APPLIER_LIB}/update.sh"
cp "${APP_DIR}/applier/cloudhosting-updater.path"    /etc/systemd/system/
cp "${APP_DIR}/applier/cloudhosting-updater.service" /etc/systemd/system/
cat > /etc/cloudhosting-panel.env <<EOF
PRODUCT=langflow
COMPOSE_FILE=${COMPOSE_FILE}
COMPOSE_PROJECT_DIR=${APP_DIR}
REPO_DIR=${APP_DIR}
DATA_DIR=${APP_DIR}/paneldata
UPDATE_BRANCH=main
EOF
chmod 0644 /etc/cloudhosting-panel.env
systemctl daemon-reload
systemctl enable --now cloudhosting-updater.path
log "Updater enabled (watching ${APP_DIR}/paneldata/.update-request)"
"${APPLIER_LIB}/update.sh" --stamp-only || log "WARN: initial version stamp failed"

log "Disabling langflow-firstboot.service (provisioning complete)"
systemctl disable langflow-firstboot.service 2>/dev/null || true

log "First boot complete. Panel: https://${PANEL_DOMAIN}:8443  ·  Langflow: https://${PANEL_DOMAIN} (admin / PANEL_PASSWORD)"
