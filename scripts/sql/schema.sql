-- Tabla de reservaciones en RDS PostgreSQL (enunciado, sección 1.6).
-- El status no tiene default: lo asigna siempre el servicio que escribe la fila.
CREATE TABLE IF NOT EXISTS reservations (
    reservation_id  UUID       PRIMARY KEY,
    concert_id      VARCHAR    NOT NULL,
    user_id         VARCHAR    NOT NULL,
    ticket_type     VARCHAR    NOT NULL,
    quantity        INTEGER    NOT NULL,
    status          VARCHAR    NOT NULL,
    created_at      TIMESTAMP  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMP  NOT NULL DEFAULT now()
);
