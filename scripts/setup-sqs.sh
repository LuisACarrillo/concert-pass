#!/bin/bash
# scripts/setup-sqs.sh
# Crea la cola FIFO de reservaciones. La deduplicación es por MessageDeduplicationId
# explícito (ContentBasedDeduplication=false). Idempotente.
source "$(dirname "$0")/lib/common.sh"
check_aws

if url=$(sqs_queue_url 2>/dev/null); then
    log "La cola '$SQS_QUEUE_NAME' ya existe."
else
    log "Creando cola FIFO '$SQS_QUEUE_NAME'..."
    # Si la cola se borró hace menos de 60 s, AWS rechaza recrearla con el mismo nombre
    for attempt in 1 2 3; do
        if out=$(aws sqs create-queue --queue-name "$SQS_QUEUE_NAME" \
                --attributes FifoQueue=true,ContentBasedDeduplication=false 2>&1); then
            break
        fi
        grep -q "QueueDeletedRecently" <<<"$out" || { echo "$out" >&2; exit 1; }
        [ "$attempt" -lt 3 ] || { echo "$out" >&2; exit 1; }
        echo "    La cola se borró hace poco; reintentando en 60 s..."
        sleep 60
    done
    url=$(sqs_queue_url)
fi

aws sqs get-queue-attributes --queue-url "$url" \
    --attribute-names FifoQueue ContentBasedDeduplication --output table
log "SQS_QUEUE_URL=$url"
