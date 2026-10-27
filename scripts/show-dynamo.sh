#!/bin/bash
# scripts/show-dynamo.sh
# Muestra los conciertos de la tabla de eventos en DynamoDB con su capacidad por sección.
source "$(dirname "$0")/lib/common.sh"
check_aws

log "Scan de DynamoDB '$DYNAMODB_TABLE' ($AWS_REGION)"
aws dynamodb scan --table-name "$DYNAMODB_TABLE" \
    --query "Items[].{concert_id: concert_id.S, name: name.S, date: date.S, recinto: recinto.S, floor: capacity.M.floor.N, vip: capacity.M.vip.N, general: capacity.M.general.N}" \
    --output table
