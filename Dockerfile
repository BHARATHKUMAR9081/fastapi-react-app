# =============================================================================
# Production Multi-Stage Dockerfile
# FastAPI (Python 3.10) + React/Vite SPA, unified behind Nginx on port 80
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Frontend builder (Vite/React/TypeScript)
# -----------------------------------------------------------------------------
FROM node:20-alpine AS frontend-builder

WORKDIR /app/frontend

# Dependency manifests first for layer caching
COPY frontend/package.json ./

# Lockfile is not committed; --legacy-peer-deps avoids strict peer resolution failures
RUN npm install --legacy-peer-deps

# Copy frontend sources and build production assets (tsc && vite build -> dist/)
COPY frontend/ ./

RUN npm run build

# -----------------------------------------------------------------------------
# Stage 2: Backend builder (FastAPI / SQLModel)
# -----------------------------------------------------------------------------
FROM python:3.11-slim AS backend-builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app/backend

# Install pinned runtime dependencies first for layer caching
COPY backend/requirements.txt ./

RUN pip install --no-cache-dir -r requirements.txt

# Copy the entire backend application tree (app package, configs, etc.)
COPY backend/ ./

# -----------------------------------------------------------------------------
# Stage 3: Unified runtime (Nginx + Python backend)
# -----------------------------------------------------------------------------
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Nginx for static SPA serving + reverse proxy; curl for healthcheck
RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend

# Backend runtime dependencies (installed from compiled lock-style requirements)
COPY --from=backend-builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=backend-builder /usr/local/bin /usr/local/bin

# Entire backend application directory (all modules, routes, models, services)
COPY --from=backend-builder /app/backend /app/backend

# Pre-built frontend static assets
COPY --from=frontend-builder /app/frontend/dist /usr/share/nginx/html

# SQLite database lives on a writable path (container filesystem is read-only-safe otherwise)
RUN mkdir -p /data && \
    sed -i 's|user www-data;|user root;|g' /etc/nginx/nginx.conf

# Nginx site config: SPA fallback at /, API reverse proxy to uvicorn on 127.0.0.1:8000
RUN printf 'server {\n\
    listen 80;\n\
    server_name _;\n\
\n\
    root /usr/share/nginx/html;\n\
    index index.html;\n\
\n\
    location /api/ {\n\
        proxy_pass http://127.0.0.1:8000;\n\
        proxy_http_version 1.1;\n\
        proxy_set_header Host $host;\n\
        proxy_set_header X-Real-IP $remote_addr;\n\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n\
        proxy_set_header X-Forwarded-Proto $scheme;\n\
        proxy_read_timeout 60s;\n\
    }\n\
\n\
    location / {\n\
        try_files $uri $uri/ /index.html;\n\
    }\n\
}\n' > /etc/nginx/conf.d/default.conf && \
    rm -f /etc/nginx/sites-enabled/default

# Runtime configuration (secrets injected at deploy time, never baked in)
ENV JWT_SECRET_KEY="" \
    JWT_REFRESH_SECRET_KEY="" \
    SQL_CONNECTION_STRING="sqlite:////data/database.db" \
    BACKEND_CORS_ORIGINS="http://localhost,http://localhost:5173"

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fs http://127.0.0.1:8000/api/v1/health || exit 1

# Start uvicorn in the background, Nginx in the foreground
CMD ["sh", "-c", "(uvicorn app.main:app --host 127.0.0.1 --port 8000 &) && nginx -g 'daemon off;'"]