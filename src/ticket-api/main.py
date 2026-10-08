import os
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import create_engine, Column, String, Integer
from sqlalchemy.orm import declarative_base, sessionmaker
import uvicorn

# Configuración de variables de entorno (ideal para Docker/RDS)
DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://usuario:password@rds-endpoint.amazonaws.com:5432/nombre_db"
)

# Configuración de SQLAlchemy
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


# Modelo de Base de Datos
class ReservationModel(Base):
    __tablename__ = "reservations"

    id = Column(Integer, primary_key=True, index=True, autoincrement=True)
    concert_id = Column(String(100), nullable=False)
    user_id = Column(String(100), nullable=False)
    ticket_type = Column(String(50), nullable=False)
    quantity = Column(Integer, nullable=False)
    status = Column(String(50), default="confirmed")


# Crear tablas si no existen
Base.metadata.create_all(bind=engine)


# Schema de Pydantic para validar la entrada JSON
class ReserveRequest(BaseModel):
    concert_id: str
    user_id: str
    ticket_type: str
    quantity: int


app = FastAPI(title="Ticket API")


@app.post("/reserve", status_code=status.HTTP_201_CREATED)
async def reserve_ticket(payload: ReserveRequest):
    db = SessionLocal()
    try:
        new_reservation = ReservationModel(
            concert_id=payload.concert_id,
            user_id=payload.user_id,
            ticket_type=payload.ticket_type,
            quantity=payload.quantity,
            status="confirmed"
        )
        db.add(new_reservation)
        db.commit()
        db.refresh(new_reservation)

        return {
            "status": "success",
            "message": "Reservación confirmada y registrada en RDS",
            "reservation_id": new_reservation.id,
            "reservation": payload.model_dump()
        }
    except Exception as e:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error al escribir en la base de datos: {str(e)}"
        )
    finally:
        db.close()


if __name__ == '__main__':
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=True)