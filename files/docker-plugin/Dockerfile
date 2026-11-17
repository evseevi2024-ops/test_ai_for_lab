# Кастомный плагин мониторинга (ЛР 4): лёгкий HTTP-экспортёр метрик.
FROM python:3.12-alpine
RUN adduser -D plugin && apk add --no-cache curl procps
COPY plugin.py /app/plugin.py
USER plugin
EXPOSE 8888
HEALTHCHECK --interval=30s --timeout=3s CMD curl -fs http://127.0.0.1:8888/health || exit 1
CMD ["python", "/app/plugin.py"]
