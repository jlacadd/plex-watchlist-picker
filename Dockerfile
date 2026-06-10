FROM python:3.12-slim

WORKDIR /app

COPY webapp/server.py /app/server.py
COPY webapp/static /app/static

ENV CONFIG_PATH=/data/plex-watchlist-config.json
ENV CACHE_PATH=/data/plex-watchlist-runtime-cache.json
ENV PORT=8787

EXPOSE 8787

CMD ["python", "/app/server.py"]
