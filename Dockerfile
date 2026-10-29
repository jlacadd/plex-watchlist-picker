FROM python:3.12-slim

# Refuse a stale base image predating the October 2026 security release.
RUN python -c "import sys; assert sys.version_info >= (3, 12, 16), 'Pull an updated Python base image'"

WORKDIR /app

COPY webapp/server.py /app/server.py
COPY webapp/static /app/static

ENV CONFIG_PATH=/data/plex-watchlist-config.json
ENV CACHE_PATH=/data/plex-watchlist-runtime-cache.json
ENV PORT=8787

EXPOSE 8787

CMD ["python", "/app/server.py"]
