FROM node:20-alpine AS frontend-builder
WORKDIR /build
COPY frontend/package*.json ./
RUN npm install --legacy-peer-deps
COPY frontend/ ./
RUN npm run build

FROM python:3.11-slim AS backend-builder
WORKDIR /app
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    JWT_SECRET_KEY=change-me \
    JWT_REFRESH_SECRET_KEY=change-me-too \
    SQL_CONNECTION_STRING=sqlite:////data/database.db

RUN apt-get update && apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /run/nginx /etc/nginx/http.d /var/www/html /data

COPY --from=backend-builder /install /usr/local
COPY backend/ /app/backend/
COPY --from=frontend-builder /build/dist /var/www/html

RUN rm -f /etc/nginx/sites-enabled/default

RUN printf 'server {\n\
    listen 80;\n\
    server_name _;\n\
    root /var/www/html;\n\
    index index.html;\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
    location /api/ {\n\
        proxy_pass http://127.0.0.1:8000/api/;\n\
        proxy_set_header Host $host;\n\
        proxy_set_header X-Real-IP $remote_addr;\n\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n\
        proxy_set_header X-Forwarded-Proto $scheme;\n\
    }\n\
}\n' > /etc/nginx/http.d/default.conf

EXPOSE 80

WORKDIR /app/backend

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl -fsS http://127.0.0.1:8000/api/v1/health || exit 1

CMD ["sh", "-c", "mkdir -p /run/nginx /data && (uvicorn app.main:app --host 127.0.0.1 --port 8000 &) && nginx -g 'daemon off;'"]