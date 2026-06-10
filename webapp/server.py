import json
import math
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CONFIG_PATH = Path(os.environ.get("CONFIG_PATH", "/data/config.json"))
CACHE_PATH = Path(os.environ.get("CACHE_PATH", "/data/runtime-cache.json"))
PORT = int(os.environ.get("PORT", "8787"))


INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Plex Movie Picker</title>
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <main>
    <section class="topbar">
      <div>
        <h1>What fits tonight?</h1>
      </div>
      <div class="summary" id="summary">Loading watchlist...</div>
    </section>

    <section class="controls">
      <div class="preset-grid">
        <button data-minutes="90">90 min</button>
        <button data-minutes="110">1h 50m</button>
        <button data-minutes="120">2 hours</button>
        <button data-minutes="150">2.5 hours</button>
      </div>
      <div class="custom-row">
        <input id="customTime" placeholder="Custom time, e.g. 1:45, 105, 2h">
        <button id="customButton">Find</button>
      </div>
    </section>

    <div class="status" id="status"></div>
    <section class="results" id="results"></section>
  </main>

  <script>
    const statusEl = document.getElementById('status');
    const resultsEl = document.getElementById('results');
    const summaryEl = document.getElementById('summary');
    const customTimeEl = document.getElementById('customTime');

    function setStatus(text) {
      statusEl.textContent = text;
    }

    function renderMovies(data) {
      summaryEl.textContent = `${data.source}: ${data.movieCount} movies · shortest ${data.shortest.runtime} · longest ${data.longest.runtime}`;
      resultsEl.innerHTML = '';

      if (!data.movies.length) {
        const empty = document.createElement('div');
        empty.className = 'empty';
        empty.textContent = `No movies fit within ${data.limitRuntime}. Shortest available is ${data.shortest.title} at ${data.shortest.runtime}.`;
        resultsEl.appendChild(empty);
        setStatus('');
        return;
      }

      setStatus(`${data.movies.length} movies fit within ${data.limitRuntime}.`);
      for (const movie of data.movies) {
        const row = document.createElement('article');
        row.className = 'movie';
        row.innerHTML = `
          <div class="runtime">${movie.runtime}</div>
          <div>
            <div class="title"></div>
            <div class="meta"></div>
          </div>
          <a href="${movie.plexUrl}" target="_blank" rel="noreferrer">Open</a>
        `;
        row.querySelector('.title').textContent = movie.title;
        row.querySelector('.meta').textContent = movie.year || '';
        resultsEl.appendChild(row);
      }
    }

    async function findMovies(value) {
      setStatus('Checking the watchlist...');
      resultsEl.innerHTML = '';
      const url = `/api/movies?time=${encodeURIComponent(value)}`;
      const response = await fetch(url);
      const data = await response.json();
      if (!response.ok) {
        setStatus(data.error || 'Something went wrong.');
        return;
      }
      renderMovies(data);
    }

    for (const button of document.querySelectorAll('[data-minutes]')) {
      button.addEventListener('click', () => findMovies(button.dataset.minutes));
    }

    document.getElementById('customButton').addEventListener('click', () => {
      findMovies(customTimeEl.value);
    });

    customTimeEl.addEventListener('keydown', event => {
      if (event.key === 'Enter') {
        findMovies(customTimeEl.value);
      }
    });

    findMovies('120');
  </script>
</body>
</html>
"""


def load_json(path, default):
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(value, file, indent=2, sort_keys=True)


def parse_time_limit(value):
    text = (value or "").strip().lower()
    if not text:
        raise ValueError("Enter a time like 90, 1:30, or 2h.")
    if ":" in text:
        hours, minutes = text.split(":", 1)
        return int(hours) * 60 + int(minutes)
    if text.endswith(("hours", "hour", "hrs", "hr", "h")):
        number = "".join(ch for ch in text if ch.isdigit() or ch == ".")
        return math.floor(float(number) * 60)
    if text.endswith(("minutes", "minute", "mins", "min", "m")):
        number = "".join(ch for ch in text if ch.isdigit())
        return int(number)
    return int(text)


def format_runtime(minutes):
    hours = minutes // 60
    remainder = minutes % 60
    return f"{hours}h {remainder:02d}m"


def http_get(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read()


def get_plex_movies(config):
    token = config.get("plexToken")
    if not token:
        raise RuntimeError("Missing plexToken in config.json.")

    base_url = "https://discover.provider.plex.tv/library/sections/watchlist/all"
    query = urllib.parse.urlencode({
        "includeCollections": "1",
        "includeExternalMedia": "1",
        "type": "1",
        "sort": "watchlistedAt:desc",
    })
    url = f"{base_url}?{query}"
    start = 0
    size = 100
    movies = []

    while True:
        headers = {
            "X-Plex-Token": token,
            "X-Plex-Container-Start": str(start),
            "X-Plex-Container-Size": str(size),
        }
        root = ET.fromstring(http_get(url, headers=headers))
        total = int(root.attrib.get("totalSize", "0"))

        for item in root.findall("Video"):
            if item.attrib.get("type") != "movie":
                continue
            duration = item.attrib.get("duration")
            runtime_minutes = math.ceil(int(duration) / 60000) if duration else None
            movies.append({
                "id": item.attrib.get("guid") or item.attrib.get("ratingKey"),
                "title": item.attrib.get("title", "Untitled"),
                "year": item.attrib.get("year", ""),
                "runtimeMinutes": runtime_minutes,
                "plexUrl": item.attrib.get("publicPagesURL", ""),
                "source": "Plex",
            })

        start += size
        if start >= total:
            break

    return movies, "Plex API"


def get_movies():
    config = load_json(CONFIG_PATH, {})
    movies, source = get_plex_movies(config)
    now = datetime.now(timezone.utc).isoformat()
    cache = load_json(CACHE_PATH, {})

    current_ids = set()
    for movie in movies:
        current_ids.add(movie["id"])
        existing = cache.get(movie["id"], {})
        cache[movie["id"]] = {
            "title": movie["title"],
            "year": movie["year"],
            "runtimeMinutes": movie["runtimeMinutes"],
            "plexUrl": movie["plexUrl"],
            "source": movie["source"],
            "inCurrentFeed": True,
            "firstSeenAt": existing.get("firstSeenAt", now),
            "lastSeenAt": now,
        }

    for movie_id, cached in cache.items():
        if movie_id not in current_ids:
            cached["inCurrentFeed"] = False

    save_json(CACHE_PATH, cache)
    return movies, source


def make_payload(limit_minutes):
    movies, source = get_movies()
    movies_with_runtime = [m for m in movies if m.get("runtimeMinutes")]
    if not movies_with_runtime:
        raise RuntimeError("No movies have runtime data.")

    shortest = min(movies_with_runtime, key=lambda m: (m["runtimeMinutes"], m["title"]))
    longest = max(movies_with_runtime, key=lambda m: (m["runtimeMinutes"], m["title"]))
    matches = sorted(
        [m for m in movies_with_runtime if m["runtimeMinutes"] <= limit_minutes],
        key=lambda m: (-m["runtimeMinutes"], m["title"]),
    )

    return {
        "source": source,
        "movieCount": len(movies),
        "limitMinutes": limit_minutes,
        "limitRuntime": format_runtime(limit_minutes),
        "shortest": {
            "title": shortest["title"],
            "year": shortest["year"],
            "runtime": format_runtime(shortest["runtimeMinutes"]),
        },
        "longest": {
            "title": longest["title"],
            "year": longest["year"],
            "runtime": format_runtime(longest["runtimeMinutes"]),
        },
        "movies": [
            {
                "title": movie["title"],
                "year": movie["year"],
                "runtime": format_runtime(movie["runtimeMinutes"]),
                "runtimeMinutes": movie["runtimeMinutes"],
                "plexUrl": movie["plexUrl"],
            }
            for movie in matches
        ],
    }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            self.send_text(INDEX_HTML, "text/html; charset=utf-8")
            return
        if parsed.path == "/api/movies":
            self.handle_movies(parsed)
            return
        if parsed.path == "/static/style.css":
            css_path = Path("/app/static/style.css")
            self.send_text(css_path.read_text(encoding="utf-8"), "text/css; charset=utf-8")
            return
        self.send_error(404)

    def handle_movies(self, parsed):
        query = urllib.parse.parse_qs(parsed.query)
        try:
            limit = parse_time_limit(query.get("time", ["120"])[0])
            payload = make_payload(limit)
            self.send_json(payload)
        except (ValueError, RuntimeError, urllib.error.URLError, ET.ParseError) as exc:
            self.send_json({"error": str(exc)}, status=400)

    def send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_text(self, text, content_type):
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Plex Movie Picker listening on port {PORT}")
    server.serve_forever()
