#!/bin/bash
# scripts/test-nicho.sh
# Escenario de nicho: pocas reservaciones a un concierto con capacidad holgada.
# Todas deben terminar en confirmed.
# Uso: BASE_URL=http://<host>:<puerto> ./scripts/test-nicho.sh [N]   (N entre 3 y 5, default 4)
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/http.sh"

N="${1:-4}"
[[ "$N" =~ ^[3-5]$ ]] || die "N debe estar entre 3 y 5"
CONCERT_ID="${CONCERT_ID:-cuarteto-cuerdas-cdmx}"
TYPES=(floor vip general)

check_api
log "Escenario de nicho: $N reservaciones a $CONCERT_ID vía $BASE_URL"

ids=(); users=(); types=(); qtys=()
for i in $(seq 1 "$N"); do
    user="usr_nicho_$i"
    type="${TYPES[$(( (i - 1) % 3 ))]}"
    qty=$(( (i - 1) % 2 + 1 ))
    id=$(reserve "$CONCERT_ID" "$user" "$type" "$qty") || die "Falló POST /reserve para $user"
    echo "    POST /reserve -> $id (pending)  $user $type x$qty"
    ids+=("$id"); users+=("$user"); types+=("$type"); qtys+=("$qty")
done

log "Esperando estado final (máx ${POLL_TIMEOUT_SECONDS}s)..."
start=$SECONDS
declare -A final elapsed
while :; do
    pending=0
    for id in "${ids[@]}"; do
        [ -n "${final[$id]:-}" ] && continue
        st=$(get_status "$id")
        if is_final "$st"; then
            final[$id]=$st; elapsed[$id]=$(( SECONDS - start ))
        else
            pending=$((pending + 1))
        fi
    done
    [ "$pending" -eq 0 ] && break
    [ $(( SECONDS - start )) -ge "$POLL_TIMEOUT_SECONDS" ] && break
    sleep 1
done

echo
printf '%-38s %-14s %-8s %-4s %-10s %s\n' RESERVATION_ID USER_ID TIPO QTY STATUS "SEG"
printf '%-38s %-14s %-8s %-4s %-10s %s\n' "$(printf -- '-%.0s' {1..36})" -------------- -------- ---- ---------- ---
ok=0
for i in "${!ids[@]}"; do
    id=${ids[$i]}
    st=${final[$id]:-$(get_status "$id")}
    printf '%-38s %-14s %-8s %-4s %-10s %s\n' "$id" "${users[$i]}" "${types[$i]}" "${qtys[$i]}" "$st" "${elapsed[$id]:--}"
    [ "$st" = "confirmed" ] && ok=$((ok + 1))
done
echo
if [ "$ok" -eq "$N" ]; then
    log "OK: $ok/$N reservaciones confirmed"
else
    log "FALLA: solo $ok/$N reservaciones confirmed"
    exit 1
fi
