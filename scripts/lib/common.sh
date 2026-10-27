# Utilidades compartidas por los scripts de infraestructura. Se carga con `source`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Carga .env si existe, sin pisar variables que ya vengan exportadas
if [ -f "$ROOT_DIR/.env" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        [ -n "${!key:-}" ] || export "$key=${value%$'\r'}"
    done < "$ROOT_DIR/.env"
fi

# Nombres de recursos (sobrescribibles por variable de entorno)
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
DB_INSTANCE_IDENTIFIER="${DB_INSTANCE_IDENTIFIER:-ticket-rds-db}"
DB_NAME="${DB_NAME:-ticketdb}"
DB_USER="${DB_USER:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DYNAMODB_TABLE="${DYNAMODB_TABLE:-concertpass-events}"
SQS_QUEUE_NAME="${SQS_QUEUE_NAME:-concertpass-reservations.fifo}"
DB_SECRET_NAME="${DB_SECRET_NAME:-concertpass/rds}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# aws CLI en Windows devuelve \r al final de cada línea en --output text
awsq() { aws "$@" | tr -d '\r'; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "No se encontró '$1' en el PATH. $2"
}

require_db_password() {
    : "${DB_PASSWORD:?Falta DB_PASSWORD. Defínela en .env (ver .env.example) o expórtala antes de correr el script.}"
}

# Falla rápido si no hay credenciales válidas (p. ej. ExpiredToken en AWS Academy)
check_aws() {
    require_cmd aws "Instala AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    local out
    if ! out=$(aws sts get-caller-identity --output text 2>&1); then
        echo "$out" >&2
        die "Las credenciales de AWS no son válidas o expiraron. Renuévalas y vuelve a intentar."
    fi
}

require_docker() {
    require_cmd docker "Instala Docker Desktop."
    docker info >/dev/null 2>&1 || die "Docker no está corriendo. Inicia Docker Desktop."
}

rds_host() {
    awsq rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_IDENTIFIER" \
        --query "DBInstances[0].Endpoint.Address" --output text
}

sqs_queue_url() {
    awsq sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --query QueueUrl --output text
}
