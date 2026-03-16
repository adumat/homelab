FROM python:3.14-alpine

RUN apk add --no-cache libnfs

WORKDIR /app
COPY canary.py /app/

USER 1000:1000
EXPOSE 9999

CMD ["python3", "-u", "/app/canary.py"]
