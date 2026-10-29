#!/bin/bash
# scripts/setup-ecr.sh
source "$(dirname "$0")/lib/common.sh"
check_aws
require_docker

ACCOUNT=$(awsq sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log "Login en ECR ($REGISTRY)..."
aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY"

for svc in ticket-api ticket-worker ticket-checkout; do
    if aws ecr describe-repositories --repository-names "$svc" >/dev/null 2>&1; then
        log "El repositorio '$svc' ya existe."
    else
        log "Creando repositorio '$svc'..."
        aws ecr create-repository --repository-name "$svc" \
            --query repository.repositoryUri --output text >/dev/null
    fi
    log "Construyendo $REGISTRY/$svc:latest ..."
    docker build -t "$REGISTRY/$svc:latest" "$svc"
    log "Publicando $REGISTRY/$svc:latest ..."
    docker push "$REGISTRY/$svc:latest"
done

log "Imágenes publicadas en $REGISTRY"
