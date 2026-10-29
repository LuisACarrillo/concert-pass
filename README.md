# concert-pass

Sistema de reservación de boletos para conciertos con tres microservicios (Práctica 3, ver `docs/practica.md`).

## Arquitectura

```
                POST /reserve                 SQS FIFO                           POST /checkout
 cliente ──────────────────► ticket-api ──► concertpass-reservations.fifo ──► ticket-worker ──────────► ticket-checkout
         ◄────────────────── (FastAPI)       MessageGroupId = concert_id      (long polling)  ◄── 200 OK
          GET /reservation/{id}   │                                             │      │
                                  │ INSERT pending                              │      │ get_item (capacidad)
                                  ▼                                             ▼      ▼
                         RDS PostgreSQL  ◄──── FOR UPDATE, booked/rejected/confirmed   DynamoDB
                         (reservations)                                                (concertpass-events)
```

- **ticket-api**: guarda la reservación en RDS con status `pending`, la encola en SQS FIFO (`MessageGroupId = concert_id`) y regresa `reservation_id`. `GET /reservation/{id}` regresa el estado.
- **ticket-worker**: consume la cola y lee la capacidad de DynamoDB. Con `FOR UPDATE` calcula cuántos boletos se vendieron en RDS y marca `booked` o `rejected`. Si quedó `booked`, llama a ticket-checkout y marca `confirmed`.
- **ticket-checkout**: simula el procesador de pagos; responde 200 autorizando.
- **Secrets Manager** (`concertpass/rds`) guarda las credenciales de RDS. Los servicios leen toda su configuración de variables de entorno.

Estados: `pending` → `booked` → `confirmed`, o `pending` → `rejected` si no hay cupo o si el concierto o la sección no existen.

```
ticket-api/        API de reservas (FastAPI, puerto 8080)
ticket-worker/     Worker de SQS (health check en 8081)
ticket-checkout/   Simulador de pagos (FastAPI, puerto 8000)
k8s/               Manifiestos de Kubernetes y la config del cluster EKS
scripts/           Infraestructura, pruebas e inspección
docs/              Enunciado de la práctica
```

Cada servicio tiene su propio `src/`, `requirements.txt` y `Dockerfile`; el build context es la carpeta del servicio.

## 1. Levantar la infraestructura

Requisitos: AWS CLI v2 con credenciales válidas, Docker y bash (en Windows: WSL). Región por default `us-east-1`.
Todos los scripts son idempotentes y cargan `.env` solos.

```bash
DB_PASSWORD='elige-un-password' ./scripts/setup.sh   # crea todo y genera .env
./scripts/teardown.sh                                # borra todo y verifica que no quede nada
```

| Script | Recurso |
|---|---|
| `setup-rds.sh` | RDS PostgreSQL `ticket-rds-db` (db.t3.micro, pública, puerto 5432) |
| `apply-schema.sh` | Aplica `sql/schema.sql` con `psql` de la imagen `postgres:16` |
| `setup-dynamodb.sh` | Tabla `concertpass-events` + seed de `data/concerts.json` |
| `setup-sqs.sh` | Cola FIFO `concertpass-reservations.fifo` (dedup por `MessageDeduplicationId`) |
| `setup-secrets.sh` | Secret `concertpass/rds` con `{username, password, host, port, dbname}` |

Conciertos precargados:

| concert_id | floor | vip | general | Escenario |
|---|---|---|---|---|
| `cuarteto-cuerdas-cdmx` | 300 | 100 | 600 | Nicho |
| `bad-bunny-gdl` | 5 | 10 | 20 | Alta demanda |

## 2. Correr los servicios (docker compose)

```bash
docker compose up --build -d                       # 1 worker
docker compose up -d --scale ticket-worker=3       # 3 workers
docker compose ps
docker compose logs -f ticket-worker
docker compose down
```

Los contenedores usan el `.env` de `setup.sh` y las credenciales de AWS de `~/.aws` (montado en solo lectura). Si las variables `AWS_*` están definidas en la terminal, también se pasan.

| Servicio | Puerto | Endpoints |
|---|---|---|
| ticket-api | 8080 | `POST /reserve`, `GET /reservation/{id}`, `GET /health` |
| ticket-checkout | 8000 | `POST /checkout`, `GET /health` |
| ticket-worker | 8081 (interno) | `GET /health` (503 si el loop de SQS se atora) |

```bash
curl -X POST http://localhost:8080/reserve -H "Content-Type: application/json" \
  -d '{"concert_id": "bad-bunny-gdl", "user_id": "usr_123", "ticket_type": "vip", "quantity": 2}'
# {"reservation_id":"...","status":"pending"}

curl http://localhost:8080/reservation/<reservation_id>
```

## 3. Variables de entorno

`.env` lo genera `setup.sh` y está en `.gitignore`. `.env.example` documenta todas las variables.
Las obligatorias hacen que el servicio no arranque si faltan.

| Variable | Servicios | Obligatoria | Descripción |
|---|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | api, worker | sí | Conexión a RDS (en k8s vienen del secret `concertpass/rds`) |
| `AWS_REGION` | api, worker | sí | Región de SQS y DynamoDB |
| `SQS_QUEUE_URL` | api, worker | sí | URL de la cola FIFO |
| `DYNAMODB_TABLE` | worker | sí | Tabla de eventos |
| `CHECKOUT_URL` | worker | sí | URL base de ticket-checkout (el worker agrega `/checkout`) |
| `DB_POOL_MAX` | api | no (10) | Conexiones máximas a RDS por réplica |
| `SQS_WAIT_SECONDS` / `SQS_VISIBILITY_TIMEOUT` | worker | no (20 / 120) | Long polling y tiempo antes de que SQS reentregue |
| `CHECKOUT_TIMEOUT_SECONDS` / `CHECKOUT_RETRIES` | worker | no (5 / 3) | Timeout y reintentos de checkout |
| `HEALTH_PORT` / `HEALTH_MAX_AGE_SECONDS` | worker | no (8081 / 120) | Health check del worker |
| `CHECKOUT_DELAY_MS` | checkout | no (0) | Latencia simulada del pago |

boto3 usa la cadena de credenciales por default (`~/.aws`, variables `AWS_*` o el rol del nodo en EKS): no hay llaves en el código.

## 4. Pruebas de escenarios

Los scripts de prueba solo necesitan bash y curl. Reciben `BASE_URL` (default `http://localhost:8080`), así que sirven igual contra el NodePort de EKS:

```bash
./scripts/test-nicho.sh                      # 3-5 reservaciones a cuarteto-cuerdas-cdmx; todas deben quedar confirmed
./scripts/reset-db.sh -y                     # vacía reservations
./scripts/test-alta-demanda.sh               # 40 concurrentes a bad-bunny-gdl/vip (capacidad 10); exit 1 si hay sobreventa
BASE_URL=http://<ip-nodo>:<nodeport> ./scripts/test-alta-demanda.sh
TOTAL=100 CONCURRENCY=30 ./scripts/test-alta-demanda.sh
```

Inspección:

| Script | Muestra |
|---|---|
| `show-rds.sh [N]` | Conteo por concierto/sección/status, vendidos por sección y las últimas N filas |
| `show-dynamo.sh` | Conciertos y capacidad por sección |
| `peek-sqs.sh` | Mensajes en la cola sin consumirlos (`MessageGroupId`, `MessageDeduplicationId`, body) |
| `reset-db.sh [-y]` | Vacía `reservations` entre corridas |

### Tip para el video: mostrar que el mensaje llega a SQS

Con el worker detenido, el mensaje se queda en la cola y se puede mostrar:

```bash
docker compose stop ticket-worker
curl -X POST http://localhost:8080/reserve -H "Content-Type: application/json" \
  -d '{"concert_id": "cuarteto-cuerdas-cdmx", "user_id": "usr_video", "ticket_type": "vip", "quantity": 1}'
./scripts/peek-sqs.sh                          # se ve el mensaje con MessageGroupId=cuarteto-cuerdas-cdmx
curl http://localhost:8080/reservation/<id>    # sigue en pending
docker compose start ticket-worker
curl http://localhost:8080/reservation/<id>    # confirmed
```

En EKS se hace lo mismo con `kubectl scale deployment ticket-worker --replicas=0`, y después `--replicas=1`.

### Disponibilidad sin sobreventa

ticket-worker usa la transacción de la sección 1.6 con tres ajustes que PostgreSQL necesita:

1. **El bloqueo va en las filas y la suma en el worker.** PostgreSQL no permite `FOR UPDATE` con `SUM(...)`.
2. **Se bloquean todas las filas del concierto y tipo, no solo `booked`/`confirmed`.** ticket-api inserta la fila `pending` antes de encolar, así que siempre existe al menos la propia fila, y todos los workers que compiten por la misma sección bloquean el mismo conjunto. Filtrar por status permitió sobreventa en pruebas concurrentes.
3. **Se bloquea en orden de `reservation_id`.** Sin un orden fijo aparecían deadlocks entre workers.

## Resultados (docker compose local contra AWS real)

`test-alta-demanda.sh`: 40 reservaciones concurrentes (20 en paralelo) a `bad-bunny-gdl/vip` con capacidad 10 y quantity de 1 o 2. Antes de cada corrida se vació `reservations` con `reset-db.sh`.

| Workers | POST aceptados | Tiempo hasta estado final | confirmed | rejected | Vendidos en RDS | Decisiones por worker | Resultado |
|---|---|---|---|---|---|---|---|
| 1 | 40/40 en 2 s | ~49 s | 7 (10 boletos) | 33 (50 boletos) | 10 / 10 | 40 | Sin sobreventa |
| 3 | 40/40 en 2 s | ~49 s | 7 (10 boletos) | 33 (50 boletos) | 10 / 10 | 10 / 10 / 20 | Sin sobreventa |

### Por qué tarda lo mismo con 1 y con 3 workers

- **SQS FIFO serializa por `MessageGroupId`.** Las 40 reservaciones son del mismo concierto, así que todas van en el grupo `bad-bunny-gdl`. Mientras un worker tiene mensajes de ese grupo en proceso, SQS no entrega más mensajes del mismo grupo a nadie. Los 3 workers se turnan el grupo (10/10/20 decisiones) pero nunca lo procesan en paralelo. Con varios conciertos a la vez, cada grupo sí avanzaría en paralelo y más workers aumentarían el throughput.
- **`FOR UPDATE` sigue siendo necesario.** La serialización del grupo no evita que dos workers lean la misma disponibilidad: un mensaje reentregado por visibility timeout, o reservaciones de la misma sección en otro grupo, pueden competir. En pruebas concurrentes contra PostgreSQL local, bloquear solo las filas `booked`/`confirmed` produjo 12 boletos vendidos de 10. Con el bloqueo de toda la sección nunca hubo sobreventa.
- **El cuello de botella es la lógica de inventario, no la recepción.** ticket-api aceptó las 40 en 2 s, mientras que el worker procesa unos 0.8 mensajes por segundo. Cada mensaje hace 6 o 7 viajes de ida y vuelta a RDS (leer, bloquear, actualizar, confirmar), y desde WSL a `us-east-1` cada viaje cuesta unos 150-200 ms. En EKS, dentro de la misma región, la latencia a RDS es mucho menor y el throughput por grupo debería subir.

## 5. Correr en EKS

Requisitos extra, en WSL: `eksctl` y `kubectl`. El cluster se llama `concertpass`, usa el rol `LabRole` de AWS Academy y 2 nodos `t3.medium` en subred pública para que el NodePort sea alcanzable. No está enganchado a `setup.sh` porque se cobra mientras exista.

```bash
./scripts/setup-eks.sh     # al final, kubectl get nodes muestra 2 nodos Ready
./scripts/setup-ecr.sh     # build y push de ticket-api, ticket-worker y ticket-checkout
./scripts/deploy-k8s.sh    # Secret desde concertpass/rds, apply de k8s/ e imprime la URL
```

`deploy-k8s.sh` crea el Secret `concertpass-rds` (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`) y aplica:

| Manifiesto | Recurso |
|---|---|
| `k8s/ticket-api.yaml` | Deployment + Service NodePort `30080` (contenedor 8080, probes `GET /health`) |
| `k8s/ticket-worker.yaml` | Deployment con 1 réplica (health en 8081, sin Service) |
| `k8s/ticket-checkout.yaml` | Deployment + Service ClusterIP `ticket-checkout:8000` |
| `k8s/configmap.yaml` | `AWS_REGION`, `SQS_QUEUE_URL`, `DYNAMODB_TABLE`, `CHECKOUT_URL` |

Los pods de la API y el worker leen AWS por el rol del nodo (IMDS con hop limit 2). La contraseña de RDS no se versiona: sale de Secrets Manager al desplegar.

```bash
BASE_URL=http://<ip-nodo>:30080 ./scripts/test-nicho.sh
./scripts/reset-db.sh -y
kubectl scale deployment ticket-worker --replicas=3
BASE_URL=http://<ip-nodo>:30080 ./scripts/test-alta-demanda.sh
```

Volver a correr `deploy-k8s.sh` deja el worker en 1 réplica, que es lo que declara el manifiesto.

Para el video, con el worker detenido el mensaje se queda en la cola:

```bash
kubectl scale deployment ticket-worker --replicas=0
curl -X POST "$BASE_URL/reserve" -H "Content-Type: application/json" \
  -d '{"concert_id": "cuarteto-cuerdas-cdmx", "user_id": "usr_video", "ticket_type": "vip", "quantity": 1}'
./scripts/peek-sqs.sh
kubectl scale deployment ticket-worker --replicas=1
```

`./scripts/teardown.sh` borra primero el cluster y los tres repositorios ECR, y después el resto. Verifica que ya no existan.
