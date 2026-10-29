#!/bin/bash
# scripts/setup-rds.sh
# Crea la RDS PostgreSQL (db.t3.micro, pública, puerto 5432 abierto: aceptable para el lab).
# Idempotente: si la instancia ya existe, solo sincroniza el password con DB_PASSWORD.
source "$(dirname "$0")/lib/common.sh"
require_db_password
check_aws

status=$(awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --query "DBInstances[0].DBInstanceStatus" --output text 2>/dev/null || echo "none")

if [ "$status" = "deleting" ]; then
    log "La RDS '$DB_INSTANCE_IDENTIFIER' se está borrando; esperando a que termine para recrearla..."
    aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
    status="none"
fi

if [ "$status" = "none" ]; then
    log "Creando instancia PostgreSQL '$DB_INSTANCE_IDENTIFIER' en RDS..."
    aws rds create-db-instance \
        --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --db-instance-class db.t3.micro \
        --engine postgres \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASSWORD" \
        --allocated-storage 20 \
        --db-name "$DB_NAME" \
        --publicly-accessible \
        --output text --query "DBInstance.DBInstanceIdentifier" >/dev/null
else
    log "La RDS '$DB_INSTANCE_IDENTIFIER' ya existe (estado: $status); sincronizando password con DB_PASSWORD..."
    aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"
    aws rds modify-db-instance \
        --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --master-user-password "$DB_PASSWORD" \
        --apply-immediately \
        --output text --query "DBInstance.DBInstanceIdentifier" >/dev/null
    # El cambio de estado a resetting-master-credentials no es inmediato
    sleep 20
fi

log "Esperando a que la instancia esté disponible (la primera vez tarda ~5-10 min)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_IDENTIFIER"

SG_ID=$(awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" --output text)

log "Abriendo el puerto $DB_PORT en el Security Group $SG_ID..."
if ! out=$(aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
        --protocol tcp --port "$DB_PORT" --cidr 0.0.0.0/0 2>&1); then
    grep -q "InvalidPermission.Duplicate" <<<"$out" || { echo "$out" >&2; exit 1; }
    echo "    La regla ya existía."
fi

log "RDS lista: DB_HOST=$(rds_host)"
