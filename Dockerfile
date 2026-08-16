FROM python:3.11-alpine

WORKDIR /app

COPY app.py .
COPY index.html .

RUN mkdir -p /app/data

EXPOSE 3000

ENV PYTHONUNBUFFERED=1
ENV DB_PATH=/app/data/urls.db

CMD ["python", "app.py"]
