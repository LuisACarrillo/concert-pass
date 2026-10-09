#!/bin/bash
# scripts/teardown_rds.sh

DB_INSTANCE_IDENTIFIER=${DB_INSTANCE_IDENTIFIER:-"ticket-rds-db"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

echo "Eliminando instancia RDS '$DB_INSTANCE_IDENTIFIER'..."

aws rds delete-db-instance \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --skip-final-snapshot \
    --delete-automated-backups \
    --region "$AWS_REGION"

echo "Esperando a que la instancia sea eliminada por completo..."
aws rds wait db-instance-deleted \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$AWS_REGION"

echo "RDS eliminada con éxito!"