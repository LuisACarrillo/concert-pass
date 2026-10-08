from fastapi import FastAPI
import uvicorn

app = FastAPI()

@app.post("/checkout")
async def checkout():
    return {"status": "success", "message": "Checkout recibido correctamente"}

if __name__ == '__main__':
    # Uvicorn reemplaza a app.run()
    uvicorn.run("ticket_checkout:app", host="0.0.0.0", port=8000, reload=True)