FROM node:20-alpine AS frontend-builder
WORKDIR /app/frontend
COPY frontend/package*.json ./
RUN npm install --legacy-peer-deps
COPY frontend/ ./
RUN npm run build

FROM python:3.11-slim AS backend-builder
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends gcc libffi-dev && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ ./

FROM python:3.11-slim AS backend-runtime
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=backend-builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=backend-builder /usr/local/bin /usr/local/bin
COPY --from=backend-builder /app /app
EXPOSE 8000

FROM nginx:alpine AS runtime
RUN apk add --no-cache python3 py3-pip && mkdir -p /run/nginx /etc/nginx/http.d /etc/nginx/conf.d
COPY --from=backend-runtime /app /usr/src/app
COPY --from=backend-runtime /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=backend-runtime /usr/local/bin /usr/local/bin
COPY --from=frontend-builder /app/frontend/dist /usr/share/nginx/html
RUN python3 -m pip install --no-cache-dir --break-system-packages uvicorn
RUN printf 'server {\n\
    listen 80;\n\
    server_name _;\n\
    root /usr/share/nginx/html;\n\
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
RUN mkdir -p /usr/src/app/data && adduser -D -u 1000 appuser && chown -R appuser:appuser /usr/src/app /var/lib/nginx /var/log/nginx
USER appuser
WORKDIR /usr/src/app/backend
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s CMD wget -qO- http://127.0.0.1/api/v1/health || exit 1
CMD ["sh", "-c", "mkdir -p /run/nginx /usr/src/app/backend && (uvicorn app.main:app --host 127.0.0.1 --port 8000 &) && nginx -g 'daemon off;'"]