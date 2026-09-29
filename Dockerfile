#syntax=docker/dockerfile:1.6

###############################################################################
# Stage 1: Frontend builder (Vite + React + TypeScript)
###############################################################################
FROM node:20-alpine AS frontend-builder
WORKDIR /app/frontend

COPY frontend/package.json ./

RUN npm install --legacy-peer-deps

COPY frontend/ ./

RUN npm run build

###############################################################################
# Stage 2: Backend builder (FastAPI + SQLModel, Python 3.10 per pip-compile header)
###############################################################################
FROM python:3.10-slim AS backend-builder
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app/backend

COPY backend/requirements.txt ./

RUN pip install --no-cache-dir -r requirements.txt

COPY backend/ ./

###############################################################################
# Stage 3: Final unified runtime (nginx serving SPA + proxying /api to uvicorn)
###############################################################################
FROM python:3.10-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/nginx /etc/nginx/conf.d /var/log/app

# Non-root service user for the API process
RUN groupadd --system app && useradd --system --gid app --create-home app

# Backend application (entire backend tree: app package, migrations, assets)
COPY --from=backend-builder /usr/local/lib/python3.10/site-packages /usr/local/lib/python3.10/site-packages
COPY --from=backend-builder /usr/local/bin /usr/local/bin
COPY --from=backend-builder --chown=app:app /app/backend /app/backend

# Frontend static bundle
COPY --from=frontend-builder /app/frontend/dist /usr/share/nginx/html

# Nginx: serve SPA on port 80, proxy /api to uvicorn on 127.0.0.1:8000
RUN rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default \
    && printf '%s\n' \
'server {' \
'    listen 80;' \
'    server_name _;' \
'' \
'    root /usr/share/nginx/html;' \
'    index index.html;' \
'' \
'    gzip on;' \
'    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;' \
'' \
'    location /api/ {' \
'        proxy_pass http://127.0.0.1:8000;' \
'        proxy_http_version 1.1;' \
'        proxy_set_header Host $host;' \
'        proxy_set_header X-Real-IP $remote_addr;' \
'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
'        proxy_set_header X-Forwarded-Proto $scheme;' \
'        proxy_read_timeout 60s;' \
'    }' \
'' \
'    location / {' \
'        try_files $uri $uri/ /index.html;' \
'    }' \
'}' > /etc/nginx/conf.d/default.conf

# Entrypoint: bootstrap writable SQLite dir, launch uvicorn in background, nginx foreground
RUN printf '%s\n' \
'#!/bin/sh' \
'set -e' \
'' \
'mkdir -p /run/nginx /var/log/app' \
'' \
'# Resolve SQLite database path (relative paths are CWD-relative -> /app/backend)' \
'case "${SQL_CONNECTION_STRING:-}" in' \
'  sqlite:*)' \
'    DB_PATH="$(printf "%s" "${SQL_CONNECTION_STRING}" | sed "s|^sqlite:///|/app/backend/|; s|^sqlite://||")"' \
'    if [ -n "${DB_PATH}" ] && [ "${DB_PATH}" != ":memory:" ]; then' \
'      DB_DIR="$(dirname "${DB_PATH}")"' \
'      mkdir -p "${DB_DIR}"' \
'      touch "${DB_PATH}"' \
'      chown -R app:app "${DB_DIR}"' \
'    fi' \
'    ;;' \
'esac' \
'' \
'# Start FastAPI backend on the loopback interface (nginx proxies /api)' \
'( cd /app/backend && exec uvicorn app.main:app --host 127.0.0.1 --port 8000 >> /var/log/app/uvicorn.log 2>&1 & )' \
'' \
'# Start nginx in the foreground as the container PID 1 process' \
'exec nginx -g "daemon off;"' > /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /app/backend

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/api/v1/health || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]