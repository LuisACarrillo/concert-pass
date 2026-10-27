#!/bin/bash
# scripts/show-rds.sh
# Muestra el estado de reservations en RDS: conteo por concierto/sección/status y las últimas filas.
# Uso: ./scripts/show-rds.sh [N_ULTIMAS_FILAS]   (default 10)
source "$(dirname "$0")/lib/common.sh"
LIMIT="${1:-10}"
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die "N_ULTIMAS_FILAS debe ser un número"

psql_rds <<SQL
\echo '=== Reservaciones por concierto / sección / status ==='
SELECT concert_id, ticket_type, status, COUNT(*) AS reservaciones, SUM(quantity) AS boletos
FROM   reservations
GROUP  BY concert_id, ticket_type, status
ORDER  BY concert_id, ticket_type, status;

\echo '=== Boletos vendidos (booked + confirmed) por sección ==='
SELECT concert_id, ticket_type, COALESCE(SUM(quantity), 0) AS vendidos
FROM   reservations
WHERE  status IN ('booked', 'confirmed')
GROUP  BY concert_id, ticket_type
ORDER  BY concert_id, ticket_type;

\echo '=== Últimas $LIMIT reservaciones ==='
SELECT reservation_id, concert_id, user_id, ticket_type, quantity, status,
       to_char(created_at, 'HH24:MI:SS.MS') AS creada,
       to_char(updated_at, 'HH24:MI:SS.MS') AS actualizada
FROM   reservations
ORDER  BY created_at DESC
LIMIT  $LIMIT;
SQL
