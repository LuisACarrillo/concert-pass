# ticket-api: recibe reservaciones, las registra en RDS como pending y las encola en SQS FIFO.
# Toda la configuración viene de variables de entorno (sección 1.9).
import json
import logging
import os
import threading
import uuid
from contextlib import asynccontextmanager, contextmanager

import boto3
from fastapi import FastAPI, HTTPException, status
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-api")


def require_env(name):
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Falta la variable de entorno {name}")
    return value


DB_HOST = require_env("DB_HOST")
DB_PORT = require_env("DB_PORT")
DB_NAME = require_env("DB_NAME")
DB_USER = require_env("DB_USER")
DB_PASSWORD = require_env("DB_PASSWORD")
AWS_REGION = require_env("AWS_REGION")
SQS_QUEUE_URL = require_env("SQS_QUEUE_URL")
DB_POOL_MAX = int(os.getenv("DB_POOL_MAX", "10"))

sqs = boto3.client("sqs", region_name=AWS_REGION)
pool = None
# El pool lanza PoolError si se agota; el semáforo hace que las peticiones esperen turno
pool_slots = threading.BoundedSemaphore(DB_POOL_MAX)


@asynccontextmanager
async def lifespan(app):
    global pool
    # minconn = maxconn: psycopg2 CIERRA al devolverla toda conexión que exceda minconn, así que
    # con minconn=1 casi cada petición abría una conexión nueva a RDS (TCP + SSL + auth, ~1 s).
    # Keepalives para que el NAT no corte las conexiones del pool mientras están inactivas.
    pool = ThreadedConnectionPool(
        DB_POOL_MAX, DB_POOL_MAX,
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD,
        keepalives=1, keepalives_idle=30, keepalives_interval=10, keepalives_count=3,
    )
    log.info("Conectado a RDS %s/%s", DB_HOST, DB_NAME)
    yield
    pool.closeall()


app = FastAPI(title="ticket-api", lifespan=lifespan)


@contextmanager
def db_cursor():
    """Cursor dentro de una transacción: commit al salir, rollback si hay excepción."""
    with pool_slots:
        conn = pool.getconn()
        try:
            with conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
                yield cur
        finally:
            pool.putconn(conn, close=conn.closed != 0)


class ReserveRequest(BaseModel):
    concert_id: str = Field(min_length=1)
    user_id: str = Field(min_length=1)
    ticket_type: str = Field(min_length=1)
    quantity: int = Field(gt=0)


@app.post("/reserve", status_code=status.HTTP_202_ACCEPTED)
def reserve(req: ReserveRequest):
    reservation_id = str(uuid.uuid4())

    # Se hace commit antes de encolar para que el worker siempre encuentre la fila
    with db_cursor() as cur:
        cur.execute(
            """INSERT INTO reservations
                   (reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at, updated_at)
               VALUES (%s, %s, %s, %s, %s, 'pending', NOW(), NOW())""",
            (reservation_id, req.concert_id, req.user_id, req.ticket_type, req.quantity),
        )

    message = {
        "reservation_id": reservation_id,
        "concert_id": req.concert_id,
        "user_id": req.user_id,
        "ticket_type": req.ticket_type,
        "quantity": req.quantity,
    }
    try:
        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(message),
            MessageGroupId=req.concert_id,
            MessageDeduplicationId=reservation_id,
        )
    except Exception:
        log.exception("No se pudo encolar %s; se elimina la reservación", reservation_id)
        with db_cursor() as cur:
            cur.execute("DELETE FROM reservations WHERE reservation_id = %s", (reservation_id,))
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "No se pudo encolar la reservación")

    log.info("Reservación %s encolada (concert_id=%s, %s x%d)",
             reservation_id, req.concert_id, req.ticket_type, req.quantity)
    return {"reservation_id": reservation_id, "status": "pending"}


@app.get("/reservation/{reservation_id}")
def get_reservation(reservation_id: uuid.UUID):
    with db_cursor() as cur:
        cur.execute(
            """SELECT reservation_id, concert_id, user_id, ticket_type, quantity, status,
                      created_at, updated_at
               FROM reservations WHERE reservation_id = %s""",
            (str(reservation_id),),
        )
        row = cur.fetchone()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Reservación no encontrada")
    return row


@app.get("/health")
def health():
    return {"status": "ok"}
