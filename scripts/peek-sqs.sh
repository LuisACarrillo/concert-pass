#!/bin/bash
# scripts/peek-sqs.sh
# Muestra los mensajes que hay en la cola FIFO sin consumirlos (VisibilityTimeout=0:
# vuelven a estar disponibles de inmediato). Útil con el worker detenido.
source "$(dirname "$0")/lib/common.sh"
check_aws

url=$(sqs_queue_url)
log "Cola $SQS_QUEUE_NAME"
aws sqs get-queue-attributes --queue-url "$url" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query "Attributes" --output table

log "Mensajes (hasta 10, sin consumir):"
messages=$(awsq sqs receive-message --queue-url "$url" \
    --max-number-of-messages 10 --visibility-timeout 0 --wait-time-seconds 1 \
    --attribute-names All \
    --query "Messages[].[Attributes.MessageGroupId, Attributes.MessageDeduplicationId, Body]" \
    --output text)

if [ -z "$messages" ] || [ "$messages" = "None" ]; then
    echo "    (la cola está vacía o los mensajes están en proceso por un worker)"
    exit 0
fi
while IFS=$'\t' read -r group dedup body; do
    echo "  MessageGroupId=$group  MessageDeduplicationId=$dedup"
    echo "    Body: $body"
done <<<"$messages"
