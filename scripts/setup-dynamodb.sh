#!/bin/bash
# scripts/setup-dynamodb.sh
# Crea la tabla de eventos (PK concert_id, PAY_PER_REQUEST) y carga scripts/data/concerts.json.
# Idempotente: no recrea la tabla ni sobrescribe conciertos que ya existan
# (para reiniciar el inventario: teardown.sh y setup.sh).
source "$(dirname "$0")/lib/common.sh"
check_aws
require_docker

status=$(awsq dynamodb describe-table --table-name "$DYNAMODB_TABLE" \
    --query "Table.TableStatus" --output text 2>/dev/null || echo "none")

if [ "$status" = "DELETING" ]; then
    log "La tabla '$DYNAMODB_TABLE' se está borrando; esperando para recrearla..."
    aws dynamodb wait table-not-exists --table-name "$DYNAMODB_TABLE"
    status="none"
fi

if [ "$status" = "none" ]; then
    log "Creando tabla DynamoDB '$DYNAMODB_TABLE'..."
    aws dynamodb create-table \
        --table-name "$DYNAMODB_TABLE" \
        --attribute-definitions AttributeName=concert_id,AttributeType=S \
        --key-schema AttributeName=concert_id,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --output text --query "TableDescription.TableName" >/dev/null
else
    log "La tabla '$DYNAMODB_TABLE' ya existe (estado: $status)."
fi
aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE"

# Convierte el JSON plano a formato tipado de DynamoDB, un item por línea
TO_DDB_JSON='
import json, sys
def ddb(v):
    if isinstance(v, bool): return {"BOOL": v}
    if isinstance(v, (int, float)): return {"N": str(v)}
    if isinstance(v, dict): return {"M": {k: ddb(x) for k, x in v.items()}}
    if isinstance(v, list): return {"L": [ddb(x) for x in v]}
    return {"S": str(v)}
for item in json.load(sys.stdin):
    print(json.dumps({k: ddb(v) for k, v in item.items()}, separators=(",", ":")))
'

log "Cargando conciertos desde scripts/data/concerts.json..."
docker run -i --rm python:3.11-slim python -c "$TO_DDB_JSON" < scripts/data/concerts.json | tr -d '\r' |
while IFS= read -r item; do
    id=$(sed -E 's/.*"concert_id":\{"S":"([^"]*)"\}.*/\1/' <<<"$item")
    if out=$(aws dynamodb put-item --table-name "$DYNAMODB_TABLE" --item "$item" \
            --condition-expression "attribute_not_exists(concert_id)" 2>&1); then
        echo "    + $id"
    elif grep -q "ConditionalCheckFailedException" <<<"$out"; then
        echo "    = $id (ya existía, no se sobrescribe)"
    else
        echo "$out" >&2; exit 1
    fi
done

log "Conciertos en '$DYNAMODB_TABLE':"
aws dynamodb scan --table-name "$DYNAMODB_TABLE" \
    --query "Items[].[concert_id.S, capacity.M.floor.N, capacity.M.vip.N, capacity.M.general.N]" \
    --output table
