#!/bin/bash
# scripts/apply-schema.sh
# Aplica scripts/sql/schema.sql en la RDS usando psql dentro de Docker (no requiere psql local).
# Si encuentra la tabla reservations de la parte 1 (id SERIAL, sin reservation_id), la elimina y la recrea.
source "$(dirname "$0")/lib/common.sh"
require_db_password
require_docker

if [ -z "${DB_HOST:-}" ]; then
    check_aws
    DB_HOST=$(rds_host)
fi

psql_rds() {
    docker run -i --rm -e PGPASSWORD="$DB_PASSWORD" postgres:16 \
        psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

log "Aplicando schema en $DB_HOST/$DB_NAME..."
{
    cat <<'SQL'
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'public' AND table_name = 'reservations')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = 'reservations'
                         AND column_name = 'reservation_id') THEN
        RAISE NOTICE 'Tabla reservations de la parte 1 (id SERIAL) detectada: se elimina y se recrea';
        DROP TABLE reservations;
    END IF;
END $$;
SQL
    cat scripts/sql/schema.sql
} | psql_rds -q

log "Estructura actual de reservations:"
psql_rds -c '\d reservations' </dev/null
