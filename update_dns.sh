#!/bin/bash

# --- CARGA DE CONFIGURACIÓN EXTERNA ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    # Exporta automáticamente las variables definidas en .env
    set -a
    source "$ENV_FILE"
    set +a
fi

# Permite sobreescribir por variables de entorno o usa valor por defecto en TAG
TAG="${TAG:-ddns-cloudflare}"

if [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]]; then
    echo "[$TAG] ERROR: Faltan TG_BOT_TOKEN o TG_CHAT_ID. Configúralos en $ENV_FILE o como variables de entorno." >&2
    exit 1
fi

# --- FUNCIONES DE LOG Y ALERTA ---

function send_telegram() {
    local TEXT="$1"
    curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
         -d "chat_id=${TG_CHAT_ID}" \
         -d "parse_mode=Markdown" \
         --data-urlencode "text=${TEXT}" > /dev/null
}

function report_error() {
    local DOMAIN_CTX="${RECORD_NAME:-Desconocido}"
    local SHORT_MSG="$1"
    local DETAILS="$2"

    # Log a syslog
    logger -t "$TAG" -p user.err "[$DOMAIN_CTX] $SHORT_MSG | Detalle: $DETAILS"

    # Salida a stderr
    echo "[$TAG][$DOMAIN_CTX] ERROR: $SHORT_MSG" >&2
    [ -n "$DETAILS" ] && echo "Detalles: $DETAILS" >&2

    # Mensaje formateado para Telegram
    local TG_MSG="❌ *Error en ${TAG}*
*Dominio:* \`${DOMAIN_CTX}\`
*Fallo:* ${SHORT_MSG}"

    if [ -n "$DETAILS" ]; then
        TG_MSG="${TG_MSG}
*Detalle API:* \`${DETAILS}\`"
    fi

    # Envío parseado como Markdown simple
    curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
         -d "chat_id=${TG_CHAT_ID}" \
         -d "parse_mode=Markdown" \
         --data-urlencode "text=${TG_MSG}" > /dev/null
}

function log_info() {
    local DOMAIN_CTX="${RECORD_NAME:-General}"
    logger -t "$TAG" -p user.info "[$DOMAIN_CTX] $1"
    echo "[info][$DOMAIN_CTX] $1"
}

# --- 1. VALIDACIÓN DE ENTRADA ---

if [ "$#" -ne 3 ]; then
    echo "Uso: $0 <API_TOKEN> <ZONE_ID> <RECORD_NAME>" >&2
    echo "Ejemplo: $0 abc123token xyz789zone casa.tudominio.com" >&2
    exit 1
fi

TOKEN="${1}"
ZONE_ID="${2}"
RECORD_NAME="${3}"

if [[ -z "$TOKEN" || -z "$ZONE_ID" || -z "$RECORD_NAME" ]]; then
    report_error "Parámetros incompletos" "Uno o más argumentos están vacíos."
    exit 1
fi

# --- 2. OBTENCIÓN DE IP PÚBLICA ---

CURRENT_IP=$(dig @resolver1.opendns.com A myip.opendns.com +short -4 2>/dev/null)

if [[ ! $CURRENT_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    logger -t "$TAG" -p user.warn "[$RECORD_NAME] Fallo resolviendo IP pública vía OpenDNS. Abortando sin alertar."
    exit 1
fi

# --- 3. CONSULTA A CLOUDFLARE ---

HTTP_RESPONSE=$(curl -sS --max-time 15 --retry 2 --retry-delay 2 -w "\n%{http_code}" -X GET \
     "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${RECORD_NAME}" \
     -H "Authorization: Bearer ${TOKEN}" \
     -H "Content-Type: application/json")

HTTP_STATUS=$(tail -n1 <<< "${HTTP_RESPONSE}")
DNS_RECORD_INFO=$(sed '$d' <<< "${HTTP_RESPONSE}")

if [ "$HTTP_STATUS" == "000" ]; then
    logger -t "$TAG" -p user.warn "[$RECORD_NAME] Timeout o fallo de red alcanzando Cloudflare (HTTP 000). Reintentará en el próximo ciclo."
    exit 1
fi

if [ "$HTTP_STATUS" != "200" ]; then
    CF_ERROR=$(jq -r '.errors[] | "\(.code): \(.message)"' <<< "${DNS_RECORD_INFO}" 2>/dev/null | tr '\n' '; ')
    [ -z "$CF_ERROR" ] && CF_ERROR=$(tr '\n' ' ' <<< "${DNS_RECORD_INFO}" | cut -c 1-200)
    
    report_error "HTTP $HTTP_STATUS al consultar registro" "${CF_ERROR:-Sin respuesta}"
    exit 1
fi

IS_SUCCESS=$(jq -r '.success' <<< "${DNS_RECORD_INFO}" 2>/dev/null)
if [ "$IS_SUCCESS" != "true" ]; then
    CF_ERROR=$(jq -r '.errors[] | "\(.code): \(.message)"' <<< "${DNS_RECORD_INFO}" 2>/dev/null | tr '\n' '; ')
    report_error "API Cloudflare devolvió success=false" "${CF_ERROR:-Sin detalles}"
    exit 1
fi

RECORD_ID=$(jq -r '.result[0].id // empty' <<< "${DNS_RECORD_INFO}")
REGISTERED_IP=$(jq -r '.result[0].content // empty' <<< "${DNS_RECORD_INFO}")

if [ -z "$RECORD_ID" ]; then
    report_error "Registro no encontrado" "No existe ningún registro tipo A con el nombre exacto '${RECORD_NAME}' en la zona."
    exit 1
fi

# --- 4. COMPARACIÓN Y ACTUALIZACIÓN ---

if [ "$CURRENT_IP" != "$REGISTERED_IP" ]; then
    log_info "Cambio detectado: ${REGISTERED_IP} -> ${CURRENT_IP}. Actualizando..."

    UPDATE_RESPONSE=$(curl -sS --max-time 15 -w "\n%{http_code}" -X PUT \
         "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
         -H "Authorization: Bearer ${TOKEN}" \
         -H "Content-Type: application/json" \
         -d "{\"type\":\"A\",\"name\":\"${RECORD_NAME}\",\"content\":\"${CURRENT_IP}\",\"ttl\":120,\"proxied\":false}")

    UPDATE_HTTP_STATUS=$(tail -n1 <<< "${UPDATE_RESPONSE}")
    UPDATE_RESULT=$(sed '$d' <<< "${UPDATE_RESPONSE}")

    if [ "$UPDATE_HTTP_STATUS" == "200" ] && [[ $(jq -r '.success' <<< "${UPDATE_RESULT}" 2>/dev/null) == "true" ]]; then
        log_info "Registro actualizado correctamente a ${CURRENT_IP}."
        send_telegram "🚀 *IP Actualizada*
*Dominio:* \`${RECORD_NAME}\`
*Nueva IP:* \`${CURRENT_IP}\`
*Anterior:* \`${REGISTERED_IP}\`"
    else
        CF_UPDATE_ERR=$(jq -r '.errors[] | "\(.code): \(.message)"' <<< "${UPDATE_RESULT}" 2>/dev/null | tr '\n' '; ')
        [ -z "$CF_UPDATE_ERR" ] && CF_UPDATE_ERR=$(tr '\n' ' ' <<< "${UPDATE_RESULT}" | cut -c 1-200)
        report_error "Fallo en PUT (HTTP $UPDATE_HTTP_STATUS)" "$CF_UPDATE_ERR"
    fi
else
    log_info "IP sin cambios (${CURRENT_IP} vs ${REGISTERED_IP})."
    exit 0
fi
