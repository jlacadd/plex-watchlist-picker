<#
.SYNOPSIS
Returns Plex watchlist movies that fit within a supplied runtime limit.

.DESCRIPTION
Reads a Plex watchlist RSS feed, keeps movie items, enriches them with runtime
data from OMDb by IMDb ID, keeps a local runtime cache aligned to the current
RSS feed, and prints the movies that fit within the requested time sorted from
longest to shortest.

.EXAMPLE
.\Get-PlexWatchlistFits.ps1 -Hours 1.5 -OmdbApiKey $env:OMDB_API_KEY

.EXAMPLE
.\Get-PlexWatchlistFits.ps1 -Minutes 90 -RefreshCache

.EXAMPLE
.\Get-PlexWatchlistFits.ps1 -Hours 1.5 -ConfigPath .\plex-watchlist-config.json

.EXAMPLE
.\Get-PlexWatchlistFits.ps1
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter()]
    [string]$RssUrl,

    [Parameter(ParameterSetName = 'Hours')]
    [ValidateRange(0.01, 1000)]
    [double]$Hours,

    [Parameter(ParameterSetName = 'Minutes')]
    [ValidateRange(1, 60000)]
    [int]$Minutes,

    [Parameter()]
    [string]$OmdbApiKey,

    [Parameter()]
    [string]$PlexToken,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'data\plex-watchlist-config.json'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CachePath = (Join-Path $PSScriptRoot 'data\plex-watchlist-runtime-cache.json'),

    [Parameter()]
    [switch]$RefreshCache,

    [Parameter()]
    [switch]$IncludeUnknownRuntime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-PlexWatchlistConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Get-ConfigValue {
    param(
        [Parameter()]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Config) {
        return $null
    }

    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return [string]$property.Value
}

function Get-ObjectValue {
    param(
        [Parameter()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Save-PlexWatchlistConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [string]$RssUrl,

        [Parameter()]
        [string]$PlexToken,

        [Parameter()]
        [string]$OmdbApiKey
    )

    $configToSave = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($RssUrl)) {
        $configToSave.rssUrl = $RssUrl
    }

    if (-not [string]::IsNullOrWhiteSpace($PlexToken)) {
        $configToSave.plexToken = $PlexToken
    }

    if (-not [string]::IsNullOrWhiteSpace($OmdbApiKey)) {
        $configToSave.omdbApiKey = $OmdbApiKey
    }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $configToSave | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-ValidPlexRss {
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    [xml]$rss = $response.Content

    if ($null -eq $rss.rss -or $null -eq $rss.rss.channel) {
        throw 'The URL did not return a valid RSS feed.'
    }

    return $rss
}

function Test-OmdbApiKey {
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey
    )

    $uri = 'https://www.omdbapi.com/?apikey={0}&i=tt3896198&plot=short&r=json' -f [uri]::EscapeDataString($ApiKey)
    $response = Invoke-RestMethod -Uri $uri -Method Get

    if ($response.Response -eq 'False') {
        throw "OMDb rejected the API key: $($response.Error)"
    }
}

function Resolve-PlexWatchlistSettings {
    param(
        [Parameter()]
        [string]$RssUrl,

        [Parameter()]
        [string]$OmdbApiKey,

        [Parameter()]
        [string]$PlexToken,

        [Parameter()]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($RssUrl)) {
        $RssUrl = Get-ConfigValue -Config $Config -Name 'rssUrl'
    }

    if ([string]::IsNullOrWhiteSpace($PlexToken)) {
        $PlexToken = Get-ConfigValue -Config $Config -Name 'plexToken'
    }

    if ([string]::IsNullOrWhiteSpace($OmdbApiKey)) {
        $OmdbApiKey = $env:OMDB_API_KEY
    }

    if ([string]::IsNullOrWhiteSpace($OmdbApiKey)) {
        $OmdbApiKey = Get-ConfigValue -Config $Config -Name 'omdbApiKey'
    }

    $configChanged = $false
    $rss = $null

    while ([string]::IsNullOrWhiteSpace($PlexToken) -and $null -eq $rss) {
        if ([string]::IsNullOrWhiteSpace($RssUrl)) {
            $RssUrl = Read-Host 'Enter your Plex watchlist RSS URL'
            $configChanged = $true
        }

        try {
            $rss = Get-ValidPlexRss -Url $RssUrl
        }
        catch {
            Write-Warning "Plex RSS feed did not work: $($_.Exception.Message)"
            $RssUrl = Read-Host 'Enter your Plex watchlist RSS URL'
            $configChanged = $true
        }
    }

    $requiresOmdbApiKey = [string]::IsNullOrWhiteSpace($PlexToken)
    $omdbKeyValid = -not $requiresOmdbApiKey
    while (-not $omdbKeyValid) {
        if ([string]::IsNullOrWhiteSpace($OmdbApiKey)) {
            $OmdbApiKey = Read-Host 'Enter your OMDb API key'
            $configChanged = $true
        }

        try {
            Test-OmdbApiKey -ApiKey $OmdbApiKey
            $omdbKeyValid = $true
        }
        catch {
            Write-Warning "OMDb API key did not work: $($_.Exception.Message)"
            $OmdbApiKey = Read-Host 'Enter your OMDb API key'
            $configChanged = $true
        }
    }

    $configuredRssUrl = Get-ConfigValue -Config $Config -Name 'rssUrl'
    $configuredPlexToken = Get-ConfigValue -Config $Config -Name 'plexToken'
    $configuredOmdbApiKey = Get-ConfigValue -Config $Config -Name 'omdbApiKey'
    if ($configuredRssUrl -ne $RssUrl -or $configuredPlexToken -ne $PlexToken -or $configuredOmdbApiKey -ne $OmdbApiKey) {
        $configChanged = $true
    }

    if ($configChanged) {
        Save-PlexWatchlistConfig -Path $ConfigPath -RssUrl $RssUrl -PlexToken $PlexToken -OmdbApiKey $OmdbApiKey
    }

    return [pscustomobject]@{
        RssUrl     = $RssUrl
        PlexToken  = $PlexToken
        OmdbApiKey = $OmdbApiKey
        Rss        = $rss
    }
}

function ConvertTo-TimeLimitMinutes {
    param(
        [Parameter(Mandatory)]
        [string]$InputText
    )

    $value = $InputText.Trim().ToLowerInvariant()

    if ($value -match '^(?<hours>\d+):(?<minutes>[0-5]?\d)$') {
        return ([int]$Matches.hours * 60) + [int]$Matches.minutes
    }

    if ($value -match '^(?<hours>\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours)$') {
        return [int][math]::Floor([double]$Matches.hours * 60)
    }

    if ($value -match '^(?<minutes>\d+)\s*(m|min|mins|minute|minutes)?$') {
        return [int]$Matches.minutes
    }

    throw "Could not understand '$InputText'. Try values like 90, 90m, 1.5h, or 1:30."
}

function Format-Runtime {
    param(
        [Parameter(Mandatory)]
        [int]$Minutes
    )

    return '{0}h {1:D2}m' -f [math]::Floor($Minutes / 60), ($Minutes % 60)
}

function Get-TimeLimitMinutes {
    if ($PSCmdlet.ParameterSetName -eq 'Hours') {
        return [int][math]::Floor($Hours * 60)
    }

    if ($PSCmdlet.ParameterSetName -eq 'Minutes') {
        return $Minutes
    }

    while ($true) {
        $inputText = Read-Host 'How much time do you have? Examples: 90, 90m, 1.5h, 1:30'

        try {
            $parsedMinutes = ConvertTo-TimeLimitMinutes -InputText $inputText
            if ($parsedMinutes -gt 0) {
                return $parsedMinutes
            }

            Write-Warning 'Please enter a time greater than zero.'
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Read-RuntimeCache {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $cache = @{}
    $json = $raw | ConvertFrom-Json

    foreach ($property in $json.PSObject.Properties) {
        $runtimeMinutes = Get-ObjectValue -Object $property.Value -Name 'RuntimeMinutes'

        $cache[$property.Name] = [pscustomobject]@{
            Title          = [string](Get-ObjectValue -Object $property.Value -Name 'Title')
            Year           = [string](Get-ObjectValue -Object $property.Value -Name 'Year')
            RuntimeMinutes = if ($null -ne $runtimeMinutes) { [int]$runtimeMinutes } else { $null }
            Source         = [string](Get-ObjectValue -Object $property.Value -Name 'Source')
            UpdatedAt      = [string](Get-ObjectValue -Object $property.Value -Name 'UpdatedAt')
            InCurrentFeed  = [bool](Get-ObjectValue -Object $property.Value -Name 'InCurrentFeed')
            FirstSeenAt    = [string](Get-ObjectValue -Object $property.Value -Name 'FirstSeenAt')
            LastSeenAt     = [string](Get-ObjectValue -Object $property.Value -Name 'LastSeenAt')
            WatchlistedAt  = [string](Get-ObjectValue -Object $property.Value -Name 'WatchlistedAt')
            PlexUrl        = [string](Get-ObjectValue -Object $property.Value -Name 'PlexUrl')
        }
    }

    return $cache
}

function Save-RuntimeCache {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Cache,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $orderedCache = [ordered]@{}
    foreach ($key in ($Cache.Keys | Sort-Object)) {
        $orderedCache[$key] = $Cache[$key]
    }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }

    $orderedCache | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-ImdbId {
    param(
        [Parameter(Mandatory)]
        [object]$Item
    )

    $guid = if ($Item.guid.'#text') { [string]$Item.guid.'#text' } else { [string]$Item.guid }
    if ($guid -match '^imdb://(?<id>tt\d+)$') {
        return $Matches.id
    }

    return $null
}

function Split-MovieTitleYear {
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    if ($Title -match '^(?<title>.+)\s+\((?<year>\d{4})\)$') {
        return [pscustomobject]@{
            Title = $Matches.title
            Year  = $Matches.year
        }
    }

    return [pscustomobject]@{
        Title = $Title
        Year  = $null
    }
}

function Get-OmdbRuntime {
    param(
        [Parameter(Mandatory)]
        [string]$ImdbId,

        [Parameter(Mandatory)]
        [string]$ApiKey
    )

    $uri = 'https://www.omdbapi.com/?apikey={0}&i={1}&plot=short&r=json' -f [uri]::EscapeDataString($ApiKey), [uri]::EscapeDataString($ImdbId)
    $response = Invoke-RestMethod -Uri $uri -Method Get

    if ($response.Response -eq 'False') {
        throw "OMDb lookup failed for ${ImdbId}: $($response.Error)"
    }

    $runtimeMinutes = $null
    if ($response.Runtime -match '(?<minutes>\d+)\s+min') {
        $runtimeMinutes = [int]$Matches.minutes
    }

    return [pscustomobject]@{
        Title          = [string]$response.Title
        Year           = [string]$response.Year
        RuntimeMinutes = $runtimeMinutes
        Source         = 'OMDb'
        UpdatedAt      = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-PlexApiWatchlistMovies {
    param(
        [Parameter(Mandatory)]
        [string]$PlexToken
    )

    $containerStart = 0
    $containerSize = 100
    $movies = @()
    $totalSize = $null
    $uri = 'https://discover.provider.plex.tv/library/sections/watchlist/all?includeCollections=1&includeExternalMedia=1&type=1&sort=watchlistedAt:desc'

    do {
        $headers = @{
            'X-Plex-Token' = $PlexToken
            'X-Plex-Container-Start' = [string]$containerStart
            'X-Plex-Container-Size' = [string]$containerSize
        }

        $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        [xml]$data = $response.Content

        if ($null -eq $data.MediaContainer) {
            throw 'The Plex API did not return a valid MediaContainer.'
        }

        $totalSize = [int]$data.MediaContainer.totalSize
        foreach ($item in @($data.MediaContainer.Video)) {
            if ([string]$item.type -ne 'movie') {
                continue
            }

            $duration = Get-ObjectValue -Object $item -Name 'duration'
            $durationMinutes = $null
            if ($duration) {
                $durationMinutes = [int][math]::Ceiling(([double]$duration) / 60000)
            }

            $guid = Get-ObjectValue -Object $item -Name 'guid'
            $ratingKey = Get-ObjectValue -Object $item -Name 'ratingKey'
            $title = Get-ObjectValue -Object $item -Name 'title'
            $year = Get-ObjectValue -Object $item -Name 'year'
            $publicPagesUrl = Get-ObjectValue -Object $item -Name 'publicPagesURL'
            $watchlistedAtValue = Get-ObjectValue -Object $item -Name 'watchlistedAt'

            $cacheId = if ($guid) { [string]$guid } else { [string]$ratingKey }
            $watchlistedAt = if ($watchlistedAtValue) {
                [DateTimeOffset]::FromUnixTimeSeconds([int64]$watchlistedAtValue).UtcDateTime
            }
            else {
                [datetime]::UtcNow
            }

            [pscustomobject]@{
                CacheId        = $cacheId
                MediaId        = $cacheId
                RssTitle       = '{0} ({1})' -f [string]$title, [string]$year
                Title          = [string]$title
                Year           = [string]$year
                PlexUrl        = [string]$publicPagesUrl
                WatchlistedAt  = $watchlistedAt
                RuntimeMinutes = $durationMinutes
                MetadataSource = 'Plex'
            }
        }

        $movies += @($data.MediaContainer.Video | ForEach-Object {
            # Items are emitted above through the foreach block.
        })
        $containerStart += $containerSize
    } while ($containerStart -lt $totalSize)
}

function Get-RssWatchlistMovies {
    param(
        [Parameter(Mandatory)]
        [xml]$Rss
    )

    foreach ($item in $Rss.rss.channel.item) {
        if ([string]$item.category -ne 'movie') {
            continue
        }

        $imdbId = Get-ImdbId -Item $item
        if (-not $imdbId) {
            Write-Warning "Skipping '$($item.title)' because it does not have an IMDb guid."
            continue
        }

        $titleParts = Split-MovieTitleYear -Title ([string]$item.title)

        [pscustomobject]@{
            CacheId        = $imdbId
            MediaId        = $imdbId
            RssTitle       = [string]$item.title
            Title          = $titleParts.Title
            Year           = $titleParts.Year
            PlexUrl        = [string]$item.link
            WatchlistedAt  = [datetime]$item.pubDate
            RuntimeMinutes = $null
            MetadataSource = 'OMDb'
        }
    }
}

function New-RuntimeCacheEntry {
    param(
        [Parameter(Mandatory)]
        [object]$Metadata,

        [Parameter(Mandatory)]
        [object]$Movie,

        [Parameter()]
        [object]$ExistingEntry,

        [Parameter(Mandatory)]
        [string]$SeenAt
    )

    $firstSeenAt = Get-ObjectValue -Object $ExistingEntry -Name 'FirstSeenAt'
    if ([string]::IsNullOrWhiteSpace($firstSeenAt)) {
        $firstSeenAt = $SeenAt
    }

    return [pscustomobject]@{
        Title          = if ($Metadata.Title) { [string]$Metadata.Title } else { [string]$Movie.Title }
        Year           = if ($Metadata.Year) { [string]$Metadata.Year } else { [string]$Movie.Year }
        RuntimeMinutes = $Metadata.RuntimeMinutes
        Source         = if ($Metadata.Source) { [string]$Metadata.Source } else { 'RSS' }
        UpdatedAt      = if ($Metadata.UpdatedAt) { [string]$Metadata.UpdatedAt } else { $SeenAt }
        InCurrentFeed  = $true
        FirstSeenAt    = $firstSeenAt
        LastSeenAt     = $SeenAt
        WatchlistedAt  = $Movie.WatchlistedAt.ToUniversalTime().ToString('o')
        PlexUrl        = [string]$Movie.PlexUrl
    }
}

$config = Read-PlexWatchlistConfig -Path $ConfigPath
$settings = Resolve-PlexWatchlistSettings -RssUrl $RssUrl -OmdbApiKey $OmdbApiKey -PlexToken $PlexToken -Config $config -ConfigPath $ConfigPath
$RssUrl = $settings.RssUrl
$PlexToken = $settings.PlexToken
$OmdbApiKey = $settings.OmdbApiKey

$cache = Read-RuntimeCache -Path $CachePath
$cacheChanged = $false
$runStartedAt = (Get-Date).ToUniversalTime().ToString('o')

$watchlistSource = 'RSS'
if (-not [string]::IsNullOrWhiteSpace($PlexToken)) {
    try {
        $feedMovies = @(Get-PlexApiWatchlistMovies -PlexToken $PlexToken)
        $watchlistSource = 'Plex API'
    }
    catch {
        Write-Warning "Plex API watchlist lookup failed: $($_.Exception.Message)"
        if ($null -eq $settings.Rss) {
            $settings.Rss = Get-ValidPlexRss -Url $RssUrl
        }
        $feedMovies = @(Get-RssWatchlistMovies -Rss $settings.Rss)
    }
}
else {
    $feedMovies = @(Get-RssWatchlistMovies -Rss $settings.Rss)
}

$feedMovieIds = @($feedMovies | ForEach-Object { $_.CacheId })
$feedMovieIdSet = @{}
foreach ($cacheId in $feedMovieIds) {
    $feedMovieIdSet[$cacheId] = $true
}

foreach ($cachedImdbId in @($cache.Keys)) {
    if (-not $feedMovieIdSet.ContainsKey($cachedImdbId)) {
        if ($cache[$cachedImdbId].InCurrentFeed -ne $false) {
            $cache[$cachedImdbId].InCurrentFeed = $false
            $cacheChanged = $true
        }
    }
}

foreach ($movie in $feedMovies) {
    $hasCachedRuntime = $cache.ContainsKey($movie.CacheId) -and $null -ne $cache[$movie.CacheId].RuntimeMinutes
    $canLookupRuntime = -not [string]::IsNullOrWhiteSpace($OmdbApiKey)
    $hasPlexRuntime = $movie.MetadataSource -eq 'Plex' -and $null -ne $movie.RuntimeMinutes
    $canLookupOmdbRuntime = $movie.MetadataSource -eq 'OMDb' -and $canLookupRuntime
    $shouldLookupRuntime = -not $hasPlexRuntime -and ($RefreshCache -or -not $cache.ContainsKey($movie.CacheId) -or (-not $hasCachedRuntime -and $canLookupOmdbRuntime))

    $metadata = if ($hasPlexRuntime) {
        [pscustomobject]@{
            Title          = $movie.Title
            Year           = $movie.Year
            RuntimeMinutes = $movie.RuntimeMinutes
            Source         = 'Plex'
            UpdatedAt      = $runStartedAt
        }
    }
    elseif ($cache.ContainsKey($movie.CacheId)) { $cache[$movie.CacheId] } else { $null }

    if ($shouldLookupRuntime) {
        if (-not $canLookupOmdbRuntime) {
            Write-Warning "No cached runtime for '$($movie.RssTitle)' ($($movie.MediaId)), and no OMDb API key was provided."
            $metadata = [pscustomobject]@{
                Title          = $movie.Title
                Year           = $movie.Year
                RuntimeMinutes = $null
                Source         = 'RSS'
                UpdatedAt      = (Get-Date).ToUniversalTime().ToString('o')
            }
        }
        else {
            try {
                $metadata = Get-OmdbRuntime -ImdbId $movie.MediaId -ApiKey $OmdbApiKey
                Start-Sleep -Milliseconds 150
            }
            catch {
                Write-Warning $_.Exception.Message
                $metadata = [pscustomobject]@{
                    Title          = $movie.Title
                    Year           = $movie.Year
                    RuntimeMinutes = $null
                    Source         = 'RSS'
                    UpdatedAt      = (Get-Date).ToUniversalTime().ToString('o')
                }
            }
        }
    }

    if ($null -eq $metadata) {
        $metadata = [pscustomobject]@{
            Title          = $movie.Title
            Year           = $movie.Year
            RuntimeMinutes = $null
            Source         = $movie.MetadataSource
            UpdatedAt      = $runStartedAt
        }
    }

    $existingEntry = if ($cache.ContainsKey($movie.CacheId)) { $cache[$movie.CacheId] } else { $null }
    $cache[$movie.CacheId] = New-RuntimeCacheEntry -Metadata $metadata -Movie $movie -ExistingEntry $existingEntry -SeenAt $runStartedAt
    $cacheChanged = $true
}

if ($cacheChanged) {
    Save-RuntimeCache -Cache $cache -Path $CachePath
}

$movies = foreach ($movie in $feedMovies) {
    $cached = if ($cache.ContainsKey($movie.CacheId)) {
        $cache[$movie.CacheId]
    }
    else {
        [pscustomobject]@{
            Title          = $movie.Title
            Year           = $movie.Year
            RuntimeMinutes = $null
            Source         = 'RSS'
            UpdatedAt      = $null
        }
    }

    [pscustomobject]@{
        RuntimeMinutes = $cached.RuntimeMinutes
        Runtime        = if ($null -ne $cached.RuntimeMinutes) { Format-Runtime -Minutes $cached.RuntimeMinutes } else { 'unknown' }
        Title          = if ($cached.Title) { $cached.Title } else { $movie.Title }
        Year           = if ($cached.Year) { $cached.Year } else { $movie.Year }
        MediaId        = $movie.MediaId
        PlexUrl        = $movie.PlexUrl
        WatchlistedAt  = $movie.WatchlistedAt
        Source         = $cached.Source
        InCurrentFeed  = $cached.InCurrentFeed
    }
}

$moviesWithRuntime = @($movies | Where-Object { $null -ne $_.RuntimeMinutes })
if ($moviesWithRuntime.Count -gt 0) {
    $shortest = $moviesWithRuntime | Sort-Object RuntimeMinutes, Title | Select-Object -First 1
    $longest = $moviesWithRuntime | Sort-Object @{ Expression = 'RuntimeMinutes'; Descending = $true }, Title | Select-Object -First 1

    Write-Host ''
    Write-Host "Current movie watchlist ($watchlistSource): $($feedMovies.Count) movies, $($moviesWithRuntime.Count) with cached runtimes."
    Write-Host "Shortest: $($shortest.Title) ($($shortest.Year)) - $($shortest.Runtime)"
    Write-Host "Longest:  $($longest.Title) ($($longest.Year)) - $($longest.Runtime)"
    Write-Host ''
}
else {
    Write-Host ''
    Write-Host "Current movie watchlist: $($feedMovies.Count) movies, but none have cached runtimes yet."
    Write-Host ''
}

$limitMinutes = Get-TimeLimitMinutes

$results = $movies |
    Where-Object {
        ($null -ne $_.RuntimeMinutes -and $_.RuntimeMinutes -le $limitMinutes) -or
        ($IncludeUnknownRuntime -and $null -eq $_.RuntimeMinutes)
    } |
    Sort-Object @{ Expression = 'RuntimeMinutes'; Descending = $true }, Title

if (@($results).Count -eq 0) {
    Write-Host ''
    Write-Host "No movies fit within $(Format-Runtime -Minutes $limitMinutes)."

    if ($moviesWithRuntime.Count -gt 0) {
        Write-Host "Shortest available movie is $($shortest.Title) ($($shortest.Year)) at $($shortest.Runtime)."
    }

    Write-Host ''
}
else {
    $results |
        Select-Object Runtime, Title, Year, MediaId, PlexUrl |
        Format-Table -AutoSize
}
