# ticket-worker: consume reservaciones de SQS FIFO, decide si hay cupo y las confirma con ticket-checkout.
# Toda la configuración viene de variables de entorno (sección 1.9).
import json
import logging
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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
DB_PORT = require_env("DB_PORT")
DB_NAME = require_env("DB_NAME")
DB_USER = require_env("DB_USER")
DB_PASSWORD = require_env("DB_PASSWORD")
AWS_REGION = require_env("AWS_REGION")
SQS_QUEUE_URL = require_env("SQS_QUEUE_URL")
DYNAMODB_TABLE = require_env("DYNAMODB_TABLE")
CHECKOUT_URL = require_env("CHECKOUT_URL").rstrip("/")

# Ajustes opcionales
SQS_WAIT_SECONDS = int(os.getenv("SQS_WAIT_SECONDS", "20"))
# Cubre un lote de 10 mensajes aunque checkout agote sus reintentos; si vence, SQS reentrega
SQS_VISIBILITY_TIMEOUT = int(os.getenv("SQS_VISIBILITY_TIMEOUT", "120"))
CHECKOUT_TIMEOUT_SECONDS = float(os.getenv("CHECKOUT_TIMEOUT_SECONDS", "5"))
CHECKOUT_RETRIES = int(os.getenv("CHECKOUT_RETRIES", "3"))
HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8081"))
HEALTH_MAX_AGE_SECONDS = int(os.getenv("HEALTH_MAX_AGE_SECONDS", "120"))

sqs = boto3.client("sqs", region_name=AWS_REGION)
events_table = boto3.resource("dynamodb", region_name=AWS_REGION).Table(DYNAMODB_TABLE)

SOLD_STATUSES = ("booked", "confirmed")

# Transacción de inventario (sección 1.6), adaptada porque el SQL literal no sirve:
# - PostgreSQL rechaza FOR UPDATE junto con SUM(): "FOR UPDATE is not allowed with aggregate
#   functions". Se bloquean las filas y la suma se calcula en Python.
# - Se bloquean TODAS las filas de la sección, sin filtrar por status. Si solo se bloquearan
#   booked/confirmed, con nada vendido no se bloquea ninguna fila y dos workers sobrevenden.
#   Funciona porque ticket-api inserta la fila pending ANTES de encolar: cada worker encuentra
#   al menos su propia fila, y todos los que compiten por la misma sección bloquean el mismo
#   conjunto, así que se forman en fila y cada uno ve lo que el anterior ya vendió.
# - ORDER BY reservation_id: todos bloquean en el mismo orden. Sin él, dos workers pueden
#   tomar las filas en orden cruzado y PostgreSQL aborta uno por deadlock (visto en pruebas).
LOCK_SECTION_FOR_UPDATE = """
    SELECT reservation_id, status, quantity
    FROM   reservations
    WHERE  concert_id  = %s
    AND    ticket_type = %s
    ORDER BY reservation_id
    FOR UPDATE
"""

running = True
last_heartbeat = time.monotonic()


def heartbeat():
    global last_heartbeat
    last_heartbeat = time.monotonic()


def stop(signum, frame):
    global running
    log.info("Señal %s recibida: termino el lote actual y salgo", signum)
    running = False


class HealthHandler(BaseHTTPRequestHandler):
    """GET /health: 200 mientras el loop de SQS siga avanzando, 503 si se atoró."""

    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        age = time.monotonic() - last_heartbeat
        healthy = age < HEALTH_MAX_AGE_SECONDS
        body = json.dumps({"status": "ok" if healthy else "stalled", "last_loop_seconds_ago": round(age, 1)})
        self.send_response(200 if healthy else 503)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass  # sin un log por cada probe de k8s


def start_health_server():
    server = ThreadingHTTPServer(("0.0.0.0", HEALTH_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("Health check en :%d/health", HEALTH_PORT)


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
    """Transacción de inventario. Regresa 'booked', 'no_capacity' o 'not_pending'."""
    try:
        with conn.cursor() as cur:
            cur.execute(LOCK_SECTION_FOR_UPDATE, (concert_id, ticket_type))
            rows = cur.fetchall()
            sold = sum(qty for _, status, qty in rows if status in SOLD_STATUSES)
            own_status = next((status for rid, status, _ in rows if str(rid) == reservation_id), None)

            if own_status != "pending":
                # Otro worker ya la procesó (reentrega de SQS)
                conn.rollback()
                log.info("reservation_id=%s ya no está pending (%s); no se toca el inventario",
                         reservation_id, own_status)
                return "not_pending"

            if sold + quantity > capacity:
                conn.rollback()
                log.info("reservation_id=%s decisión=SIN_CUPO %s/%s vendidos=%d solicitados=%d capacidad=%d",
                         reservation_id, concert_id, ticket_type, sold, quantity, capacity)
                return "no_capacity"

            cur.execute(
                "UPDATE reservations SET status = 'booked', updated_at = NOW() "
                "WHERE reservation_id = %s AND status = 'pending'",
                (reservation_id,),
            )
        conn.commit()
        log.info("reservation_id=%s decisión=BOOKED %s/%s vendidos=%d solicitados=%d capacidad=%d",
                 reservation_id, concert_id, ticket_type, sold, quantity, capacity)
        return "booked"
    except Exception:
        conn.rollback()
        raise


def checkout(reservation_id, quantity):
    """POST a ticket-checkout con timeout y reintentos; lanza la última excepción si todos fallan."""
    url = f"{CHECKOUT_URL}/checkout"
    for attempt in range(1, CHECKOUT_RETRIES + 2):
        try:
            resp = requests.post(
                url,
                json={"reservation_id": reservation_id, "quantity": quantity},
                timeout=CHECKOUT_TIMEOUT_SECONDS,
            )
            resp.raise_for_status()
            return
        except requests.RequestException as exc:
            if attempt > CHECKOUT_RETRIES:
                raise
            wait = 2 ** (attempt - 1)
            log.warning("reservation_id=%s checkout falló (intento %d): %s; reintento en %ds",
                        reservation_id, attempt, exc, wait)
            time.sleep(wait)


def process(conn, reservation_id):
    """Lleva la reservación a su estado final. Idempotente ante reentregas de SQS:
    pending -> flujo completo; booked -> solo checkout; confirmed/rejected -> nada."""
    reservation = fetch_reservation(conn, reservation_id)
    if reservation is None:
        log.warning("reservation_id=%s no existe en RDS; se descarta el mensaje", reservation_id)
        return
    status = reservation["status"]

    if status == "pending":
        concert_id, ticket_type = reservation["concert_id"], reservation["ticket_type"]
        capacity = get_capacity(concert_id, ticket_type)
        if capacity is None:
            log.info("reservation_id=%s decisión=REJECTED: %s/%s no existe en DynamoDB",
                     reservation_id, concert_id, ticket_type)
            result = "no_capacity"
        else:
            result = try_book(conn, reservation_id, concert_id, ticket_type, reservation["quantity"], capacity)

        if result == "no_capacity":
            # Transacción separada, como indica la sección 1.6
            set_status(conn, reservation_id, "rejected", "pending")
            log.info("reservation_id=%s status=rejected", reservation_id)
            return
        if result == "booked":
            status = "booked"
        else:
            status = fetch_reservation(conn, reservation_id)["status"]

    if status == "booked":
        # Si checkout falla, la excepción deja el mensaje en la cola y SQS lo reentrega
        checkout(reservation_id, reservation["quantity"])
        set_status(conn, reservation_id, "confirmed", "booked")
        log.info("reservation_id=%s status=confirmed", reservation_id)
        return

    log.info("reservation_id=%s ya estaba en %s; se descarta el mensaje", reservation_id, status)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    start_health_server()
    log.info("ticket-worker escuchando %s", SQS_QUEUE_URL)
    conn = None

    while running:
        heartbeat()
        try:
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=SQS_WAIT_SECONDS,
                VisibilityTimeout=SQS_VISIBILITY_TIMEOUT,
            )
        except Exception:
            log.exception("Error leyendo de SQS; reintento en 5 s")
            time.sleep(5)
            continue

        # Si un mensaje falla, los siguientes del mismo concierto se saltan para no romper
        # el orden FIFO: vuelven a la cola al vencer su visibility timeout.
        failed_groups = set()
        for msg in resp.get("Messages", []):
            heartbeat()
            body = json.loads(msg["Body"])
            reservation_id = body.get("reservation_id")
            group = body.get("concert_id")
            if group in failed_groups:
                continue
            try:
                if conn is None or conn.closed:
                    conn = connect()
                process(conn, reservation_id)
            except Exception:
                log.exception("reservation_id=%s error al procesar; SQS lo reentregará", reservation_id)
                failed_groups.add(group)
                conn = reset_after_error(conn)
                continue
            sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])

    if conn is not None:
        conn.close()
    log.info("ticket-worker detenido")


if __name__ == "__main__":
    main()
