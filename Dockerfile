FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

# Apunta a la carpeta src y al archivo ticket-checkout.py (reemplazando el guion por guion bajo si es necesario)
CMD ["uvicorn", "src.ticket-checkout:app", "--host", "0.0.0.0", "--port", "8000"]