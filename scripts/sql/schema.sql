-- Tabla de reservaciones en RDS PostgreSQL.
-- El status no tiene default: lo asigna siempre el servicio que escribe la fila.
CREATE TABLE IF NOT EXISTS reservations (
    reservation_id UUID         PRIMARY KEY,
    concert_id     VARCHAR(100) NOT NULL,
    user_id        VARCHAR(100) NOT NULL,
    ticket_type    VARCHAR(20)  NOT NULL,
    quantity       INTEGER      NOT NULL,
    status         VARCHAR(20)  NOT NULL,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
