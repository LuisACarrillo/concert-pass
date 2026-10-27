#!/bin/bash
# scripts/teardown.sh
# Borra TODA la infraestructura creada por setup.sh y verifica que ya no exista.
# No truena si algún recurso ya no está. Sale con código 1 si algo sigue existiendo.
source "$(dirname "$0")/lib/common.sh"
check_aws

# ---------------------------------------------------------------------------
# PARTE 3: agregar aquí, ANTES de borrar los recursos de abajo, el borrado de
#   - EKS: node groups y cluster (eksctl delete cluster --wait, o
#     aws eks delete-nodegroup + aws eks delete-cluster con sus waits)
#   - ECR: aws ecr delete-repository --force por cada servicio
# y sus líneas correspondientes en la sección de verificación al final.
# ---------------------------------------------------------------------------

log "Secrets Manager: '$DB_SECRET_NAME'"
if aws secretsmanager describe-secret --secret-id "$DB_SECRET_NAME" >/dev/null 2>&1; then
    aws secretsmanager delete-secret --secret-id "$DB_SECRET_NAME" \
        --force-delete-without-recovery >/dev/null
    echo "    borrado solicitado"
else
    echo "    no existe, se omite"
fi

log "SQS: '$SQS_QUEUE_NAME'"
if url=$(sqs_queue_url 2>/dev/null); then
    aws sqs delete-queue --queue-url "$url"
    echo "    borrado solicitado"
else
    echo "    no existe, se omite"
fi

log "DynamoDB: '$DYNAMODB_TABLE'"
table_status=$(awsq dynamodb describe-table --table-name "$DYNAMODB_TABLE" \
    --query "Table.TableStatus" --output text 2>/dev/null || echo "none")
case "$table_status" in
    none)     echo "    no existe, se omite" ;;
    DELETING) echo "    ya se está borrando" ;;
    *)        aws dynamodb delete-table --table-name "$DYNAMODB_TABLE" >/dev/null
              echo "    borrado solicitado" ;;
esac

log "RDS: '$DB_INSTANCE_IDENTIFIER'"
rds_status=$(awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "none")
case "$rds_status" in
    none)     echo "    no existe, se omite" ;;
    deleting) echo "    ya se está borrando" ;;
    *)        aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
                  --skip-final-snapshot --delete-automated-backups >/dev/null
              echo "    borrado solicitado" ;;
esac

if [ "$table_status" != "none" ]; then
    log "Esperando a que se borre la tabla DynamoDB..."
    aws dynamodb wait table-not-exists --table-name "$DYNAMODB_TABLE"
fi
if [ "$rds_status" != "none" ]; then
    log "Esperando a que se borre la RDS (tarda varios minutos)..."
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
fi

# --- Verificación -----------------------------------------------------------
# SQS y Secrets Manager pueden seguir respondiendo unos segundos después del
# borrado, así que se reintenta hasta 90 s antes de declarar que algo quedó.
NOT_FOUND='ResourceNotFoundException|NonExistentQueue|QueueDoesNotExist|DBInstanceNotFound'
# 0 = confirmado que no existe; 1 = sigue existiendo; 2 = error inesperado (p. ej. ExpiredToken)
gone() {
    local i out
    for i in $(seq 1 10); do
        if ! out=$("$@" 2>&1 >/dev/null); then
            grep -qE "$NOT_FOUND" <<<"$out" && return 0
            echo "    $out" >&2
            return 2
        fi
        sleep 9
    done
    return 1
}

echo
echo "================ Verificación de teardown ($AWS_REGION) ================"
failed=0
check() {
    local label=$1; shift
    local rc=0
    gone "$@" || rc=$?
    case $rc in
        0) printf '  [OK]    %-48s no existe\n' "$label" ;;
        1) printf '  [FALLA] %-48s TODAVÍA EXISTE\n' "$label"; failed=1 ;;
        *) printf '  [ERROR] %-48s no se pudo verificar\n' "$label"; failed=1 ;;
    esac
}
check "Secrets Manager  $DB_SECRET_NAME" aws secretsmanager describe-secret --secret-id "$DB_SECRET_NAME"
check "SQS              $SQS_QUEUE_NAME" aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME"
check "DynamoDB         $DYNAMODB_TABLE" aws dynamodb describe-table --table-name "$DYNAMODB_TABLE"
check "RDS              $DB_INSTANCE_IDENTIFIER" aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
# PARTE 3: agregar aquí los check de EKS y ECR.
echo "======================================================================="

exit "$failed"
