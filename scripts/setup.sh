#!/bin/bash
# scripts/setup.sh
# Crea toda la infraestructura del backend en orden y genera .env para docker compose.
# Uso: DB_PASSWORD='...' ./scripts/setup.sh   (o con DB_PASSWORD ya definido en .env)
# Requiere: aws CLI con credenciales válidas y Docker corriendo.
source "$(dirname "$0")/lib/common.sh"
require_db_password
check_aws
require_docker
export DB_PASSWORD

SCRIPTS="$ROOT_DIR/scripts"

log "[1/5] RDS PostgreSQL"
bash "$SCRIPTS/setup-rds.sh"
export DB_HOST
DB_HOST=$(rds_host)

log "[2/5] Schema de reservations"
bash "$SCRIPTS/apply-schema.sh"

log "[3/5] DynamoDB"
bash "$SCRIPTS/setup-dynamodb.sh"

log "[4/5] SQS FIFO"
bash "$SCRIPTS/setup-sqs.sh"
SQS_QUEUE_URL=$(sqs_queue_url)

log "[5/5] Secrets Manager"
bash "$SCRIPTS/setup-secrets.sh"

if [ -f .env ]; then
    cp .env .env.bak
    log "Respaldé el .env anterior en .env.bak"
fi
(umask 077; cat > .env <<ENV
# Generado por scripts/setup.sh — no versionar
AWS_REGION=$AWS_REGION
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_SECRET_NAME=$DB_SECRET_NAME
DYNAMODB_TABLE=$DYNAMODB_TABLE
SQS_QUEUE_URL=$SQS_QUEUE_URL
ENV
)

log "Infraestructura lista. .env generado:"
sed -E 's/^(DB_PASSWORD=).*/\1********/' .env
