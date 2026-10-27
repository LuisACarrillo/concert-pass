import os
import psycopg2
from fastapi import FastAPI, HTTPException, status
from pydantic import BaseModel
import uvicorn

app = FastAPI()

# Lectura estricta de variables de ambiente
DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )


def init_db():
    """Crea la tabla reservations si no existe"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS reservations (
                id SERIAL PRIMARY KEY,
                concert_id VARCHAR(100) NOT NULL,
                user_id VARCHAR(100) NOT NULL,
                ticket_type VARCHAR(50) NOT NULL,
                quantity INT NOT NULL,
                status VARCHAR(50) DEFAULT 'confirmed'
            );
        """)
        conn.commit()
        cur.close()
        conn.close()
    except Exception as e:
        print(f"Error al inicializar la base de datos: {e}")


@app.on_event("startup")
def startup_event():
    init_db()


class ReserveRequest(BaseModel):
    concert_id: str
    user_id: str
    ticket_type: str
    quantity: int


@app.post("/reserve", status_code=status.HTTP_201_CREATED)
async def reserve(data: ReserveRequest):
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            """INSERT INTO reservations (concert_id, user_id, ticket_type, quantity, status) 
               VALUES (%s, %s, %s, %s, 'confirmed') RETURNING id;""",
            (data.concert_id, data.user_id, data.ticket_type, data.quantity)
        )
        res_id = cur.fetchone()[0]
        conn.commit()
        cur.close()
        conn.close()

        return {
            "status": "success",
            "reservation_id": res_id,
            "message": "Reservación guardada con estado confirmed"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8080)