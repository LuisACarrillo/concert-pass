# concert-pass

```
ticket-api/        API de reservas (FastAPI, puerto 8080)
ticket-worker/     Worker que procesa la cola
ticket-checkout/   Servicio de checkout (FastAPI, puerto 8000)
k8s/               Manifiestos de Kubernetes (parte 3)
scripts/           Creación y borrado de infraestructura en AWS
```

Cada servicio tiene su propio `src/`, `requirements.txt` y `Dockerfile`; el build context es la carpeta del servicio.

## Configuración

```bash
cp .env.example .env   # y llena los valores (DB_PASSWORD es obligatorio)
```

`.env` está en `.gitignore`: nunca subas contraseñas ni hosts al repo.

## Infraestructura

```bash
set -a; source .env; set +a
./scripts/init.sh       # crea la RDS e imprime DB_HOST (cópialo a .env)
./scripts/teardown.sh   # borra todo
```

## ticket-api

```bash
docker build -t ticket-api ticket-api/
docker run -d -p 8080:8080 --env-file .env --name ticket-api-container ticket-api
```

Probar:

```bash
curl -X POST "http://localhost:8080/reserve" \
  -H "Content-Type: application/json" \
  -d '{
    "concert_id": "bad-bunny-gdl",
    "user_id": "usr_123",
    "ticket_type": "vip",
    "quantity": 2
  }'
```
