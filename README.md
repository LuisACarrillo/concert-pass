# concert-pass

```
ticket-api/        API de reservas (FastAPI, puerto 8080)
ticket-worker/     Worker que procesa la cola
ticket-checkout/   Servicio de checkout (FastAPI, puerto 8000)
k8s/               Manifiestos de Kubernetes (parte 3)
scripts/           Creación y borrado de infraestructura en AWS
```

Cada servicio tiene su propio `src/`, `requirements.txt` y `Dockerfile`; el build context es la carpeta del servicio.

## Infraestructura (scripts/)

Requisitos: AWS CLI v2 con credenciales válidas, Docker corriendo y bash (Git Bash en Windows).
Región por default `us-east-1` (`AWS_REGION` la cambia). Todos los scripts son idempotentes.

```bash
DB_PASSWORD='elige-un-password' ./scripts/setup.sh   # crea todo y genera .env
./scripts/teardown.sh                                # borra todo y verifica
```

| Script | Recurso |
|---|---|
| `setup-rds.sh` | RDS PostgreSQL `ticket-rds-db` (db.t3.micro, pública, puerto 5432) |
| `apply-schema.sh` | Aplica `sql/schema.sql` con `psql` de la imagen `postgres:16` |
| `setup-dynamodb.sh` | Tabla `concertpass-events` + seed de `data/concerts.json` |
| `setup-sqs.sh` | Cola FIFO `concertpass-reservations.fifo` (dedup por `MessageDeduplicationId`) |
| `setup-secrets.sh` | Secret `concertpass/rds` con `{username, password, host, port, dbname}` |

`.env` está en `.gitignore`: nunca subas contraseñas ni hosts al repo. `.env.example` documenta las variables.

## Servicios en local (docker compose)

Con la infraestructura arriba y el `.env` generado por `setup.sh`:

```bash
docker compose up --build
```

Los contenedores usan tus credenciales de AWS montando `~/.aws` (solo lectura) o las variables `AWS_*` de la terminal.

| Servicio | Puerto | Endpoints |
|---|---|---|
| ticket-api | 8080 | `POST /reserve`, `GET /reservation/{id}`, `GET /health` |
| ticket-checkout | 8000 | `POST /checkout`, `GET /health` |
| ticket-worker | — | Consume SQS; sin HTTP |

Flujo de estados: `pending` → `booked` → `confirmed`, o `pending` → `rejected` si no hay cupo.

```bash
curl -X POST "http://localhost:8080/reserve"   -H "Content-Type: application/json"   -d '{"concert_id": "bad-bunny-gdl", "user_id": "usr_123", "ticket_type": "vip", "quantity": 2}'
# {"reservation_id": "...", "status": "pending"}

curl "http://localhost:8080/reservation/<reservation_id>"
```

### Disponibilidad sin sobreventa

ticket-worker usa la transacción de la sección 1.6 con dos ajustes necesarios en PostgreSQL:

1. `FOR UPDATE` no se permite con `SUM(...)`, así que el bloqueo va en una subconsulta y la suma afuera.
2. Se bloquean todas las filas del concierto y tipo (no solo `booked`/`confirmed`) y en orden de `reservation_id`.
   Filtrar por status permitió sobreventa en pruebas concurrentes, y sin orden fijo aparecían deadlocks entre workers.
