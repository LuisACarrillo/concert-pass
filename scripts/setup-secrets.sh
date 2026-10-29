#!/bin/bash
# scripts/setup-secrets.sh
# Guarda las credenciales de la RDS en Secrets Manager como
# {username, password, host, port, dbname}. Idempotente: si el secret ya existe
# actualiza su valor; si estaba programado para borrarse, lo restaura.
source "$(dirname "$0")/lib/common.sh"
require_db_password
check_aws

DB_HOST="${DB_HOST:-$(rds_host)}"

json_escape() {
    local bs='\' q='"'
    local s="${1//"$bs"/"$bs$bs"}"
    printf '%s' "${s//"$q"/"$bs$q"}"
}
SECRET_JSON=$(printf '{"username":"%s","password":"%s","host":"%s","port":%s,"dbname":"%s"}' \
    "$(json_escape "$DB_USER")" "$(json_escape "$DB_PASSWORD")" "$DB_HOST" "$DB_PORT" "$DB_NAME")

# Se pasa por archivo (file://) y no como argumento: en Windows el argv del aws CLI
# puede alterar comillas y backslashes del password. Ruta relativa a ROOT_DIR.
SECRET_FILE=".secret-value.tmp.json"
trap 'rm -f "$SECRET_FILE"' EXIT
(umask 077; printf '%s' "$SECRET_JSON" > "$SECRET_FILE")

deleted=$(awsq secretsmanager describe-secret --secret-id "$DB_SECRET_NAME" \
    --query "DeletedDate" --output text 2>/dev/null || echo "none")

if [ "$deleted" = "none" ]; then
    log "Creando secret '$DB_SECRET_NAME'..."
    aws secretsmanager create-secret --name "$DB_SECRET_NAME" \
        --description "Credenciales de la RDS de concert-pass" \
        --secret-string "file://$SECRET_FILE" --query ARN --output text >/dev/null
else
    if [ "$deleted" != "None" ]; then
        log "El secret '$DB_SECRET_NAME' estaba programado para borrarse; restaurándolo..."
        aws secretsmanager restore-secret --secret-id "$DB_SECRET_NAME" >/dev/null
    fi
    log "El secret '$DB_SECRET_NAME' ya existe; actualizando su valor..."
    aws secretsmanager put-secret-value --secret-id "$DB_SECRET_NAME" \
        --secret-string "file://$SECRET_FILE" >/dev/null
fi

log "Secret listo (llaves guardadas, sin mostrar valores):"
awsq secretsmanager get-secret-value --secret-id "$DB_SECRET_NAME" --query SecretString --output text |
    grep -oE '"[a-z]+":' | tr -d '":' | paste -sd ' ' -
