# concert-pass

# ticket-api
docker build -t ticket-api ticket-api/

### 2. Ejecutar el contenedor pasando las variables de entorno de tu RDS
docker run -d -p 8080:8080 -e DB_HOST=TUNO_HOST_RDS -e DB_PORT=5432 -e DB_NAME=ticketdb -e DB_USER=postgres -e DB_PASSWORD='TuPasswordSeguro123!' --name ticket-api-container ticket-api
docker run -d -p 8080:8080 -e DB_HOST=ticket-rds-db.czdstlqamloj.us-east-1.rds.amazonaws.com -e DB_PORT=5432 -e DB_NAME=ticketdb -e DB_USER=postgres -e DB_PASSWORD='TuPasswordSeguro123!' --name ticket-api-container ticket-api

### 3. Probar con tu curl
curl -X POST "http://localhost:8080/reserve" \
  -H "Content-Type: application/json" \
  -d '{
    "concert_id": "bad-bunny-gdl",
    "user_id": "usr_123",
    "ticket_type": "vip",
    "quantity": 2
  }'