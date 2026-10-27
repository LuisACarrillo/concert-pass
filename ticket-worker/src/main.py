# Esqueleto del ticket-worker. La lógica (consumir SQS, escribir en RDS)
# se implementa en el siguiente paso.
import time


def main():
    print("ticket-worker iniciado (sin lógica todavía)")
    while True:
        time.sleep(30)


if __name__ == "__main__":
    main()
