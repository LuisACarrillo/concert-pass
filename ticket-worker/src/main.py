# ticket-worker: consume reservaciones de SQS FIFO, decide si hay cupo y las confirma con ticket-checkout.
# Toda la configuración viene de variables de entorno (sección 1.9).
import json
import logging
import os
import signal

import boto3
import psycopg2
import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-worker")


def require_env(name):
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Falta la variable de entorno {name}")
    return value


DB_HOST = require_env("DB_HOST")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = require_env("DB_NAME")
DB_USER = require_env("DB_USER")
DB_PASSWORD = require_env("DB_PASSWORD")
AWS_REGION = require_env("AWS_REGION")
SQS_QUEUE_URL = require_env("SQS_QUEUE_URL")
DYNAMODB_TABLE = require_env("DYNAMODB_TABLE")
CHECKOUT_URL = require_env("CHECKOUT_URL")
SQS_WAIT_SECONDS = int(os.getenv("SQS_WAIT_SECONDS", "20"))
CHECKOUT_TIMEOUT_SECONDS = float(os.getenv("CHECKOUT_TIMEOUT_SECONDS", "5"))

sqs = boto3.client("sqs", region_name=AWS_REGION)
events_table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(DYNAMODB_TABLE)

# Versión de la consulta de la sección 1.6 que sí acepta PostgreSQL y no permite sobreventa:
# - "FOR UPDATE is not allowed with aggregate functions": el bloqueo va en la subconsulta
#   y la suma afuera.
# - Se bloquean TODAS las filas del concierto y tipo, no solo booked/confirmed. Si se filtrara
#   por status, una fila pending que otro worker está pasando a booked no quedaría bloqueada
#   y ambos workers podrían ver el mismo cupo libre.
# - ORDER BY reservation_id: todos los workers bloquean las filas en el mismo orden; sin él,
#   dos workers pueden bloquearse en orden cruzado y PostgreSQL aborta uno por deadlock.
SOLD_TICKETS_FOR_UPDATE = """
    SELECT COALESCE(SUM(quantity) FILTER (WHERE status IN ('booked', 'confirmed')), 0)
    FROM (
        SELECT quantity, status
        FROM   reservations
        WHERE  concert_id  = %s
        AND    ticket_type = %s
        ORDER BY reservation_id
        FOR UPDATE
    ) AS locked
"""

running = True


def stop(signum, frame):
    global running
    log.info("Señal %s recibida: termino el lote actual y salgo", signum)
    running = False


def connect():
    conn = psycopg2.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER, password=DB_PASSWORD)
    log.info("Conectado a RDS %s/%s", DB_HOST, DB_NAME)
    return conn


def reset_after_error(conn):
    """Deja la conexión usable tras un error, o regresa None si hay que reconectar."""
    if conn is None or conn.closed:
        return None
    try:
        conn.rollback()
        return conn
    except psycopg2.Error:
        conn.close()
        return None


def fetch_reservation(conn, reservation_id):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT concert_id, ticket_type, quantity, status FROM reservations WHERE reservation_id = %s",
            (reservation_id,),
        )
        row = cur.fetchone()
    conn.commit()
    if row is None:
        return None
    return dict(zip(("concert_id", "ticket_type", "quantity", "status"), row))


def get_capacity(concert_id, ticket_type):
    """Capacidad máxima de la sección según DynamoDB, o None si el concierto o la sección no existen."""
    item = events_table.get_item(Key={"concert_id": concert_id}).get("Item")
    if item is None:
        return None
    capacity = item.get("capacity", {}).get(ticket_type)
    return None if capacity is None else int(capacity)


def set_status(conn, reservation_id, new_status, expected_status):
    """Cambia el status solo si sigue en expected_status; no toca ninguna otra fila."""
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE reservations SET status = %s, updated_at = NOW() "
            "WHERE reservation_id = %s AND status = %s",
            (new_status, reservation_id, expected_status),
        )
    conn.commit()


def try_book(conn, reservation_id, concert_id, ticket_type, quantity, capacity):
    """Transacción de la sección 1.6. Regresa True si quedó booked."""
    try:
        with conn.cursor() as cur:
            cur.execute(SOLD_TICKETS_FOR_UPDATE, (concert_id, ticket_type))
            sold = cur.fetchone()[0]
            if sold + quantity > capacity:
                conn.rollback()
                log.info("Sin cupo para %s: %s/%s vendidos %d + %d > %d",
                         reservation_id, concert_id, ticket_type, sold, quantity, capacity)
                return False
            cur.execute(
                "UPDATE reservations SET status = 'booked', updated_at = NOW() "
                "WHERE reservation_id = %s AND status = 'pending'",
                (reservation_id,),
            )
        conn.commit()
        log.info("Booked %s: %s/%s vendidos %d + %d <= %d",
                 reservation_id, concert_id, ticket_type, sold, quantity, capacity)
        return True
    except Exception:
        conn.rollback()
        raise


def checkout(reservation_id, quantity):
    resp = requests.post(
        CHECKOUT_URL,
        json={"reservation_id": reservation_id, "quantity": quantity},
        timeout=CHECKOUT_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()


def process(conn, reservation_id):
    """Lleva la reservación a su estado final. Es idempotente: si el mensaje se
    reprocesa, retoma desde el status actual en RDS."""
    reservation = fetch_reservation(conn, reservation_id)
    if reservation is None:
        log.warning("Reservación %s no existe en RDS; se descarta el mensaje", reservation_id)
        return
    status = reservation["status"]

    if status == "pending":
        capacity = get_capacity(reservation["concert_id"], reservation["ticket_type"])
        if capacity is None:
            log.info("Rechazada %s: el concierto o la sección %s/%s no existe en DynamoDB",
                     reservation_id, reservation["concert_id"], reservation["ticket_type"])
            booked = False
        else:
            booked = try_book(conn, reservation_id, reservation["concert_id"],
                              reservation["ticket_type"], reservation["quantity"], capacity)
        if not booked:
            # Transacción separada, como indica la sección 1.6
            set_status(conn, reservation_id, "rejected", "pending")
            log.info("Rejected %s", reservation_id)
            return
        status = "booked"

    if status == "booked":
        # Si checkout falla, la excepción deja el mensaje en la cola y se reintenta desde booked
        checkout(reservation_id, reservation["quantity"])
        set_status(conn, reservation_id, "confirmed", "booked")
        log.info("Confirmed %s", reservation_id)
        return

    log.info("Reservación %s ya estaba en %s; nada que hacer", reservation_id, status)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log.info("ticket-worker escuchando %s", SQS_QUEUE_URL)
    conn = None

    while running:
        resp = sqs.receive_message(
            QueueUrl=SQS_QUEUE_URL,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=SQS_WAIT_SECONDS,
        )
        # Si un mensaje falla, los siguientes del mismo concierto se saltan para no romper
        # el orden FIFO: vuelven a la cola al vencer su visibility timeout.
        failed_groups = set()
        for msg in resp.get("Messages", []):
            body = json.loads(msg["Body"])
            group = body.get("concert_id")
            if group in failed_groups:
                continue
            try:
                if conn is None or conn.closed:
                    conn = connect()
                process(conn, body["reservation_id"])
            except Exception:
                log.exception("Error procesando %s; se reintentará", body.get("reservation_id"))
                failed_groups.add(group)
                conn = reset_after_error(conn)
                continue
            sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])

    if conn is not None:
        conn.close()
    log.info("ticket-worker detenido")


if __name__ == "__main__":
    main()
