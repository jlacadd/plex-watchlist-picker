# Plex Watchlist Runtime Picker

PowerShell helper for answering a very specific evening question: "What movie
from my Plex watchlist fits into the time I have?"

The script reads your Plex watchlist, filters to movies, caches runtimes
locally, and returns matching movies sorted from longest to shortest. When a
Plex token is configured, it uses Plex's authenticated watchlist API for the
full movie list. Without a token, it can fall back to the Plex RSS feed and use
OMDb for runtime lookup.

## Requirements

- PowerShell 7 or Windows PowerShell 5.1+
- A Plex token, recommended for the full watchlist
- A Plex watchlist RSS feed URL, optional fallback
- A free OMDb API key, required only for RSS fallback runtime lookup
- Internet access for the first run and for new watchlist items

## Setup

### 1. Get a Plex Token

The recommended setup uses Plex's authenticated watchlist API. This returns the
full movie watchlist and includes Plex runtime data directly.

To find your Plex token:

1. Open Plex Web.
2. Go to any movie or show.
3. Open the more/options menu.
4. Choose **Get Info**.
5. Click **View XML**.
6. Copy the value after `X-Plex-Token=` in the URL.

Treat this token like a password.

### 2. Enable Plex Watchlist RSS as a Fallback

In Plex, enable or copy your watchlist RSS feed URL. It should look similar to:

```text
https://rss.plex.tv/your-feed-id
```

The feed should contain RSS items with:

- `category` set to `movie` or `show`
- `guid` values like `imdb://tt0066999` for movies
- `link` values pointing to `watch.plex.tv`

The script only uses movie entries. Plex's RSS feed may return a limited window
of items, so the Plex token method is preferred when available.

### 3. Get a Free OMDb API Key

Request a free key from:

```text
https://www.omdbapi.com/apikey.aspx
```

Choose the free tier. OMDb will email your API key.

OMDb is mainly needed for RSS fallback mode, because the RSS feed includes IMDb
IDs but does not include runtime.

### 4. Create or Let the Script Create the Config File

The easiest setup is to run the script once:

```powershell
.\Get-PlexWatchlistFits.ps1
```

If required config values are missing, the script will prompt for them, validate
them, and save them to `data/plex-watchlist-config.json`. If `plexToken` is
present, the script uses the full Plex API watchlist. If not, it falls back to
RSS.

You can also create or edit `data/plex-watchlist-config.json` manually:

```json
{
  "rssUrl": "https://rss.plex.tv/your-feed-id",
  "plexToken": "your-plex-token",
  "omdbApiKey": "your-omdb-api-key"
}
```

To use a different feed temporarily, pass it at runtime:

```powershell
.\Get-PlexWatchlistFits.ps1 -RssUrl "https://rss.plex.tv/your-feed-id"
```

You can also use an environment variable for the OMDb key:

```powershell
$env:OMDB_API_KEY = "your-omdb-api-key"
```

If a supplied or configured RSS URL/API key does not work, the script will warn
you, ask for a replacement, and update the config file with the working values.
If the Plex API request fails but an RSS URL is configured, the script falls back
to RSS.

## Usage

Interactive mode:

```powershell
.\Get-PlexWatchlistFits.ps1
```

The script will refresh the local cache, print the shortest and longest movies
currently in your watchlist, then prompt for a time window.

Accepted time formats:

```text
90
90m
1.5h
1:30
```

Non-interactive examples:

```powershell
.\Get-PlexWatchlistFits.ps1 -Minutes 110
```

```powershell
.\Get-PlexWatchlistFits.ps1 -Hours 1.5
```

Force refresh cached metadata:

```powershell
.\Get-PlexWatchlistFits.ps1 -Hours 2 -RefreshCache
```

## Docker Web App

The `Dockerfile`, `docker-compose.yml`, and `webapp/` folder provide a small
browser-based version intended for a NAS.

Create this file on the NAS:

```text
getPlexWatchlistFits/data/plex-watchlist-config.json
```

With:

```json
{
  "plexToken": "your-plex-token"
}
```

Then from the `getPlexWatchlistFits` folder:

```powershell
docker compose up -d --build
```

Open:

```text
http://NAS-IP:8787
```

In Docker Manager, create a Project from `docker-compose.yml`, or create a
container with:

- Port: `8787:8787`
- Volume: `./data:/data`
- Restart policy: `unless-stopped`

The web app keeps its cache in:

```text
getPlexWatchlistFits/data/plex-watchlist-runtime-cache.json
```

## Cache Behavior

The script writes runtime metadata to:

```text
data/plex-watchlist-runtime-cache.json
```

On each run, it:

1. Fetches the current Plex watchlist through the Plex API when `plexToken` is configured.
2. Falls back to the Plex RSS feed when the API is not configured or fails.
3. Adds runtime data for new movie entries not already cached.
4. Marks cached entries missing from the current source as `InCurrentFeed = false`.
5. Updates `FirstSeenAt`, `LastSeenAt`, `WatchlistedAt`, and `PlexUrl` tracking fields.
6. Uses current watchlist movies plus cached runtime data to filter and sort by runtime.

Plex appears to return a limited RSS window, so the script does not delete cache
entries just because they are missing from one feed refresh. This avoids losing
runtime metadata for older watchlist items that may have fallen outside the RSS
window.

The cache and config files are intentionally ignored by git via `.gitignore`.

## Output

Example:

```text
Current movie watchlist (Plex API): 79 movies, 79 with cached runtimes.
Shortest: Normal (2026) - 1h 31m
Longest:  Gettysburg (1993) - 4h 14m

Runtime Title        Year MediaId                         PlexUrl
------- -----        ---- -------                         -------
1h 42m  Dirty Harry  1971 plex://movie/5d776829f541...    https://watch.plex.tv/movie/dirty-harry
1h 41m  Drive        2011 plex://movie/5d7768a6594...     https://watch.plex.tv/movie/drive-2011
```

## Files

- `Get-PlexWatchlistFits.ps1` - main script
- `data/plex-watchlist-config.json` - local Plex/OMDb config
- `data/plex-watchlist-runtime-cache.json` - local runtime cache
- `.gitignore` - keeps local config/cache files out of git
