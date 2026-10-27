# Build context: ticket-worker/
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ .

# -u: logs sin buffer para verlos en docker logs / kubectl logs
CMD ["python", "-u", "main.py"]
