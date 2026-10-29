# Utilidades HTTP para las pruebas de escenarios. Solo requieren curl (sin jq).
# Se carga con `source` después de common.sh.

BASE_URL="${BASE_URL:-http://localhost:8080}"
BASE_URL="${BASE_URL%/}"
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-120}"

json_field() {  # json_field <campo> <json>: extrae un campo string de un JSON plano
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$2"
}

check_api() {
    require_cmd curl "Instala curl."
    curl -fsS --max-time 5 "$BASE_URL/health" >/dev/null 2>&1 \
        || die "ticket-api no responde en $BASE_URL/health. ¿Está arriba? (docker compose ps)"
}

# reserve <concert_id> <user_id> <ticket_type> <quantity>  -> imprime reservation_id o regresa 1
reserve() {
    local body
    body=$(curl -sS --max-time 30 -X POST "$BASE_URL/reserve" \
        -H "Content-Type: application/json" \
        -d "{\"concert_id\":\"$1\",\"user_id\":\"$2\",\"ticket_type\":\"$3\",\"quantity\":$4}" \
        -w '\n%{http_code}') || return 1
    [ "$(tail -n1 <<<"$body")" = "202" ] || { echo "HTTP $(tail -n1 <<<"$body"): $(head -n1 <<<"$body")" >&2; return 1; }
    json_field reservation_id "$(head -n1 <<<"$body")"
}

# get_status <reservation_id> -> imprime el status actual, o "sin_respuesta" si la API no contestó
get_status() {
    local st
    st=$(json_field status "$(curl -s --max-time 10 "$BASE_URL/reservation/$1" 2>/dev/null)")
    echo "${st:-sin_respuesta}"
}

is_final() { [ "$1" = "confirmed" ] || [ "$1" = "rejected" ]; }
