#!/bin/bash
# scripts/test-alta-demanda.sh
# Escenario de alta demanda: muchas reservaciones concurrentes a una sección con poca capacidad.
# Espera a que todas terminen, imprime el conteo por status y verifica que no haya sobreventa.
# Corre ./scripts/reset-db.sh antes para partir de la sección vacía.
# Uso: BASE_URL=http://<host>:<puerto> ./scripts/test-alta-demanda.sh
# Variables: TOTAL (40), CONCURRENCY (20), CONCERT_ID (bad-bunny-gdl), TICKET_TYPE (vip), CAPACITY (10)
# Sale con 1 si hay sobreventa y con 2 si alguna reservación no terminó a tiempo.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/http.sh"

TOTAL="${TOTAL:-40}"
CONCURRENCY="${CONCURRENCY:-20}"
CONCERT_ID="${CONCERT_ID:-bad-bunny-gdl}"
TICKET_TYPE="${TICKET_TYPE:-vip}"
CAPACITY="${CAPACITY:-10}"

check_api
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
touch "$WORK/reservations.txt" "$WORK/errors.txt"

log "Alta demanda: $TOTAL reservaciones a $CONCERT_ID/$TICKET_TYPE (capacidad $CAPACITY), $CONCURRENCY en paralelo, vía $BASE_URL"

# Cada línea de reservations.txt: <reservation_id> <quantity>
post_one() {
    local i=$1 qty=$(( $1 % 2 + 1 )) id
    if id=$(reserve "$CONCERT_ID" "usr_alta_$i" "$TICKET_TYPE" "$qty" 2>>"$WORK/errors.txt"); then
        echo "$id $qty" >>"$WORK/reservations.txt"
    fi
}
export -f post_one reserve json_field
export BASE_URL CONCERT_ID TICKET_TYPE WORK

t0=$SECONDS
seq 1 "$TOTAL" | xargs -P "$CONCURRENCY" -I{} bash -c 'post_one {}'
sent=$(wc -l <"$WORK/reservations.txt")
log "POST /reserve aceptados: $sent/$TOTAL en $(( SECONDS - t0 ))s"
lost=$(( TOTAL - sent ))
if [ "$lost" -gt 0 ]; then
    echo "    $lost POST sin respuesta 202:"
    sed -E 's/after [0-9]+ milliseconds/after N ms/' "$WORK/errors.txt" | sort | uniq -c | sed 's/^/    /'
    echo "    Un POST que expira en el cliente pudo guardarse en RDS: compara con ./scripts/show-rds.sh"
fi
[ "$sent" -gt 0 ] || die "Ninguna reservación fue aceptada"

log "Esperando a que todas lleguen a estado final (máx ${POLL_TIMEOUT_SECONDS}s)..."
check_one() {
    local id=$1 qty=$2
    echo "$id $qty $(get_status "$id")"
}
export -f check_one get_status
start=$SECONDS
while :; do
    xargs -P "$CONCURRENCY" -L1 bash -c 'check_one "$0" "$1"' <"$WORK/reservations.txt" >"$WORK/status.txt"
    pending=$(awk '$3 != "confirmed" && $3 != "rejected"' "$WORK/status.txt" | wc -l)
    no_answer=$(awk '$3 == "sin_respuesta"' "$WORK/status.txt" | wc -l)
    echo "    $(( SECONDS - start ))s: $pending sin estado final ($no_answer GET sin respuesta)"
    [ "$pending" -eq 0 ] && break
    [ $(( SECONDS - start )) -ge "$POLL_TIMEOUT_SECONDS" ] && break
    sleep 2
done

echo
echo "=== Conteo por status ($CONCERT_ID/$TICKET_TYPE) ==="
printf '  %-14s %14s %8s\n' STATUS RESERVACIONES BOLETOS
awk '{n[$3]++; q[$3]+=$2} END {for (s in n) printf "  %-14s %14d %8d\n", s, n[s], q[s]}' "$WORK/status.txt" | sort
sold=$(awk '$3 == "booked" || $3 == "confirmed" {s += $2} END {print s + 0}' "$WORK/status.txt")
requested=$(awk '{s += $2} END {print s + 0}' "$WORK/status.txt")
echo
echo "  Boletos solicitados: $requested"
echo "  Boletos vendidos:    $sold / capacidad $CAPACITY"
echo

if [ "$sold" -gt "$CAPACITY" ]; then
    log "FALLA: SOBREVENTA ($sold > $CAPACITY)"
    exit 1
fi
if [ "$pending" -gt 0 ]; then
    if [ "$no_answer" -gt 0 ]; then
        log "INCOMPLETO: ticket-api no respondió $no_answer GET; revisa docker compose logs ticket-api y show-rds.sh"
    else
        log "INCOMPLETO: $pending reservaciones siguen pending tras ${POLL_TIMEOUT_SECONDS}s (¿worker arriba?)"
    fi
    exit 2
fi
log "OK: sin sobreventa ($sold <= $CAPACITY)"
if [ "$lost" -gt 0 ]; then
    echo "    Ojo: $lost POST sin respuesta no entran en este conteo; la cifra definitiva está en show-rds.sh"
fi
