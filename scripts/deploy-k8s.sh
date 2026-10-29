#!/bin/bash
# scripts/deploy-k8s.sh
check_aws
require_cmd kubectl "Instala kubectl: https://kubernetes.io/docs/tasks/tools/"
require_cmd python3 "Hace falta python3 para leer el JSON del secret."
: "${SQS_QUEUE_URL:?Falta SQS_QUEUE_URL. Corre scripts/setup.sh primero.}"

kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl no apunta a un cluster. Corre scripts/setup-eks.sh primero."

ACCOUNT=$(awsq sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log "Leyendo '$DB_SECRET_NAME' desde Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_NAME" \
    --query SecretString --output text)

eval "$(
    printf '%s' "$SECRET_JSON" | python3 -c '
import json, shlex, sys
data = json.load(sys.stdin)
pairs = {
    "SECRET_DB_HOST": data["host"],
    "SECRET_DB_PORT": str(data["port"]),
    "SECRET_DB_NAME": data["dbname"],
    "SECRET_DB_USER": data["username"],
    "SECRET_DB_PASSWORD": data["password"],
}
for key, value in pairs.items():
    print(f"{key}={shlex.quote(str(value))}")
'
)"

log "Creando Secret de Kubernetes concertpass-rds (sin mostrar valores)..."
kubectl create secret generic concertpass-rds \
    --from-literal=DB_HOST="$SECRET_DB_HOST" \
    --from-literal=DB_PORT="$SECRET_DB_PORT" \
    --from-literal=DB_NAME="$SECRET_DB_NAME" \
    --from-literal=DB_USER="$SECRET_DB_USER" \
    --from-literal=DB_PASSWORD="$SECRET_DB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
unset SECRET_JSON SECRET_DB_PASSWORD

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() {
    sed \
        -e "s|__ECR_REGISTRY__|${REGISTRY}|g" \
        -e "s|__AWS_REGION__|${AWS_REGION}|g" \
        -e "s|__SQS_QUEUE_URL__|${SQS_QUEUE_URL}|g" \
        -e "s|__DYNAMODB_TABLE__|${DYNAMODB_TABLE}|g" \
        -e "s|__NODE_PORT__|${EKS_NODE_PORT}|g" \
        "$1" > "$2"
}

log "Aplicando manifiestos (registro $REGISTRY)..."
render "$ROOT_DIR/k8s/configmap.yaml" "$TMP/configmap.yaml"
render "$ROOT_DIR/k8s/ticket-checkout.yaml" "$TMP/ticket-checkout.yaml"
render "$ROOT_DIR/k8s/ticket-api.yaml" "$TMP/ticket-api.yaml"
render "$ROOT_DIR/k8s/ticket-worker.yaml" "$TMP/ticket-worker.yaml"

kubectl apply -f "$TMP/configmap.yaml"
kubectl apply -f "$TMP/ticket-checkout.yaml"
kubectl apply -f "$TMP/ticket-api.yaml"
kubectl apply -f "$TMP/ticket-worker.yaml"

log "Esperando a que los Deployments estén listos..."
kubectl rollout status deployment/ticket-checkout --timeout=180s
kubectl rollout status deployment/ticket-api --timeout=180s
kubectl rollout status deployment/ticket-worker --timeout=180s

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' | tr -d '\r')
[ -n "$NODE_IP" ] || die "Ningún nodo tiene ExternalIP. El nodegroup debe crearse con privateNetworking: false."

echo
log "ticket-api: http://${NODE_IP}:${EKS_NODE_PORT}"
log "Prueba: BASE_URL=http://${NODE_IP}:${EKS_NODE_PORT} ./scripts/test-nicho.sh"
