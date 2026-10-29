#!/bin/bash
# scripts/setup-eks.sh
source "$(dirname "$0")/lib/common.sh"
check_aws
require_cmd eksctl "Instala eksctl: https://eksctl.io"
require_cmd kubectl "Instala kubectl: https://kubernetes.io/docs/tasks/tools/"

ACCOUNT=$(awsq sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/LabRole"
aws iam get-role --role-name LabRole >/dev/null 2>&1 \
    || die "No existe el rol LabRole. En AWS Academy es el rol del laboratorio."

TMP=$(mktemp --suffix=.yaml)
trap 'rm -f "$TMP"' EXIT
sed \
    -e "s|__ACCOUNT_ID__|${ACCOUNT}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    "$ROOT_DIR/k8s/cluster.yaml" > "$TMP"

status=$(awsq eks describe-cluster --name "$EKS_CLUSTER_NAME" \
    --query cluster.status --output text 2>/dev/null || echo "none")

case "$status" in
    none)
        log "Creando cluster '$EKS_CLUSTER_NAME' con rol $ROLE_ARN (tarda unos 15-20 min)..."
        eksctl create cluster -f "$TMP"
        ;;
    ACTIVE)
        log "El cluster '$EKS_CLUSTER_NAME' ya existe."
        aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
        ;;
    *)
        die "El cluster '$EKS_CLUSTER_NAME' está en estado '$status'. Espera o bórralo con teardown.sh."
        ;;
esac

log "Abriendo el puerto $EKS_NODE_PORT en los security groups de los nodos..."
sgs=$(aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=${EKS_CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].SecurityGroups[].GroupId" --output text \
    | tr -d '\r' | tr '\t' '\n' | sed '/^$/d' | sort -u)
[ -n "$sgs" ] || die "No encontré instancias del cluster '$EKS_CLUSTER_NAME'."

while IFS= read -r sg; do
    if ! out=$(aws ec2 authorize-security-group-ingress --group-id "$sg" \
            --protocol tcp --port "$EKS_NODE_PORT" --cidr 0.0.0.0/0 2>&1); then
        grep -q "InvalidPermission.Duplicate" <<<"$out" || { echo "$out" >&2; exit 1; }
        echo "    La regla ya existía en $sg."
    else
        echo "    Abierto en $sg."
    fi
done <<<"$sgs"

# eksctl 0.231 no acepta instanceMetadataOptions. Sin hop limit 2 los pods no ven el rol del nodo.
log "Subiendo el hop limit de IMDS a 2..."
ids=$(aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=${EKS_CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].InstanceId" --output text \
    | tr -d '\r' | tr '\t' '\n' | sed '/^$/d')
[ -n "$ids" ] || die "No encontré instancias del cluster '$EKS_CLUSTER_NAME'."
while IFS= read -r id; do
    aws ec2 modify-instance-metadata-options --instance-id "$id" \
        --http-tokens required --http-put-response-hop-limit 2 --http-endpoint enabled >/dev/null
    echo "    $id"
done <<<"$ids"

log "Esperando 2 nodos Ready..."
ready=0
for _ in $(seq 1 24); do
    ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d '[:space:]')
    [ "$ready" = "2" ] && break
    sleep 5
done
[ "$ready" = "2" ] || die "Se esperaban 2 nodos Ready y hay ${ready:-0}."

echo
kubectl get nodes
log "Cluster '$EKS_CLUSTER_NAME' listo."
