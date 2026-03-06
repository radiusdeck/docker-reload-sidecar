FROM python:3.12-alpine

LABEL org.opencontainers.image.title="docker-reload-sidecar" \
      org.opencontainers.image.description="Tiny sidecar to restart/signal Docker containers" \
      org.opencontainers.image.source="https://github.com/radiusdeck/docker-reload-sidecar" \
      org.opencontainers.image.licenses="MIT"

COPY server.py /server.py

EXPOSE 9090

ENV PYTHONUNBUFFERED=1

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9090/health')" || exit 1

CMD ["python", "/server.py"]