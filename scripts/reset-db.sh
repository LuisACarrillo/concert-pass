#!/bin/bash
# scripts/reset-db.sh
# Vacía la tabla reservations entre corridas de prueba. DynamoDB no cambia (es solo lectura).
# Uso: ./scripts/reset-db.sh [-y]   (-y omite la confirmación)
source "$(dirname "$0")/lib/common.sh"

if [ "${1:-}" != "-y" ]; then
    read -r -p "Esto borra TODAS las filas de reservations en $DB_NAME. ¿Continuar? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]] || { echo "Cancelado."; exit 0; }
fi

psql_rds <<'SQL'
\echo 'Filas antes:'
SELECT COUNT(*) FROM reservations;
TRUNCATE reservations;
\echo 'Filas después:'
SELECT COUNT(*) FROM reservations;
SQL
