#!/bin/bash
# scripts/init.sh
# Crea la infraestructura AWS del proyecto (por ahora: RDS PostgreSQL).
# Uso: set -a; source .env; set +a; ./scripts/init.sh
set -euo pipefail

: "${DB_PASSWORD:?Falta DB_PASSWORD. Defínela en .env (ver .env.example) o expórtala antes de correr el script.}"

DB_INSTANCE_IDENTIFIER=${DB_INSTANCE_IDENTIFIER:-"ticket-rds-db"}
DB_NAME=${DB_NAME:-"ticketdb"}
DB_USER=${DB_USER:-"postgres"}
AWS_REGION=${AWS_REGION:-"us-east-1"}

echo "Creando instancia PostgreSQL en RDS..."

aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASSWORD" \
    --allocated-storage 20 \
    --db-name "$DB_NAME" \
    --publicly-accessible \
    --region "$AWS_REGION"

echo "Esperando a que la instancia esté disponible..."
aws rds wait db-instance-available \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$AWS_REGION"

# Obtener Endpoint y Security Group ID
DB_HOST=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text)

SG_ID=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
    --region "$AWS_REGION" \
    --query "DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId" \
    --output text)

echo "Configurando Security Group ($SG_ID) para permitir el puerto 5432..."

aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 5432 \
    --cidr 0.0.0.0/0 \
    --region "$AWS_REGION" 2>/dev/null || echo "La regla del Security Group ya existía."

echo "----------------------------------------"
echo "DB_HOST=$DB_HOST"
echo "Copia este valor a DB_HOST en tu .env"
echo "----------------------------------------"
