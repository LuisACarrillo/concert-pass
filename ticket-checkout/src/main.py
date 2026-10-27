# ticket-checkout: simula un procesador de pagos externo (Stripe, PayPal).
# Autoriza siempre la compra con 200 OK; ticket-worker confirma la reservación al recibirlo.
import logging
import uuid

from fastapi import FastAPI
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-checkout")

app = FastAPI(title="ticket-checkout")


class CheckoutRequest(BaseModel):
    reservation_id: uuid.UUID
    quantity: int = Field(gt=0)


@app.post("/checkout")
def checkout(req: CheckoutRequest):
    log.info("Pago autorizado: reservation_id=%s quantity=%d", req.reservation_id, req.quantity)
    return {"status": "authorized", "reservation_id": str(req.reservation_id), "quantity": req.quantity}


@app.get("/health")
def health():
    return {"status": "ok"}
