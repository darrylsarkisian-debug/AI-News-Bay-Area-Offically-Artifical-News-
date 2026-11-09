# data_pulls.ps1 - one function per data source. Each returns an array of fact objects
# (see New-Fact in lib.ps1). A source that fails adds a note to $script:PullNotes and
# returns nothing; the episode continues without it. All sources here are free.
# Requires: . .\lib.ps1 and Import-Config before use.

$script:PullNotes = New-Object System.Collections.ArrayList

function Add-Note([string]$Text) { [void]$script:PullNotes.Add($Text); Write-Host "  note: $Text" -ForegroundColor Yellow }

# ------------------------------------------------------------ Warriors (ESPN via the Python adapter)
function Get-WarriorsFacts([string]$RawDir) {
    $py = Get-Command python -ErrorAction SilentlyContinue
    $pyArgs = @()
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue; $pyArgs = @('-3') }
    if (-not $py) { Add-Note 'Warriors: Python was not found (python or py). Skipping the Warriors segment.'; return @() }
    $out = Join-Path $RawDir 'warriors_facts.json'
    if (-not (Test-Path -LiteralPath $RawDir)) { New-Item -ItemType Directory -Path $RawDir -Force | Out-Null }
    $adapter = Join-Path $script:Root 'espn_adapter.py'
    # Windows PowerShell 5.1 turns native stderr text into terminating errors when ErrorActionPreference is Stop.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $log = & $py.Source @pyArgs $adapter --latest --out $out 2>&1 | Out-String; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $out)) {
        Add-Note "Warriors: the ESPN adapter failed. Skipping the Warriors segment. Details: $($log.Trim())"
        return @()
    }
    $d = Read-Json $out
    foreach ($flag in @($d.quality.flags)) { if ($flag) { Add-Note "Warriors data flag: $flag" } }
    $facts = @()
    foreach ($f in @($d.facts)) {
        $o = [ordered]@{}
        foreach ($p in $f.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o['credit'] = 'ESPN'
        $facts += [pscustomobject]$o
    }
    $facts
}

# ------------------------------------------------------------ Bay Area weather (National Weather Service)
function Get-BayAreaWeatherFacts {
    $h = @{ 'User-Agent' = $script:Config.user_agent; 'Accept' = 'application/geo+json' }
    $facts = @()
    $n = [int]$script:Config.weather_periods_per_city
    foreach ($pt in @($script:Config.weather_points)) {
        try {
            $lat = $pt.lat.ToString('0.0000', $script:Inv); $lon = $pt.lon.ToString('0.0000', $script:Inv)
            $p = ConvertFrom-Json (Invoke-Web -Uri "https://api.weather.gov/points/$lat,$lon" -Headers $h)
            $fcUrl = $p.properties.forecast
            $fc = ConvertFrom-Json (Invoke-Web -Uri $fcUrl -Headers $h)
            $i = 0
            foreach ($per in @($fc.properties.periods | Select-Object -First $n)) {
                $i++
                $unit = $per.temperatureUnit
                $disp = "$($pt.label) $($per.name): $($per.temperature) degrees $unit, $($per.shortForecast), wind $($per.windSpeed) $($per.windDirection)"
                $facts += New-Fact -Id ("nws.forecast.{0}.{1}" -f ($pt.label -replace '[^A-Za-z]', '').ToLower(), $i) -Kind 'weather_forecast' `
                    -Subject $pt.label -Value $per.temperature -Display $disp -Source 'National Weather Service' -Url $fcUrl -Credit 'National Weather Service'
            }
        } catch { Add-Note "Weather: $($pt.label) forecast failed: $($_.Exception.Message)" }
    }
    # Active alerts for San Francisco's point (alerts are issued by zone; one point is enough for a prototype)
    try {
        $pt = @($script:Config.weather_points)[0]
        $lat = $pt.lat.ToString('0.0000', $script:Inv); $lon = $pt.lon.ToString('0.0000', $script:Inv)
        $aUrl = "https://api.weather.gov/alerts/active?point=$lat,$lon"
        $a = ConvertFrom-Json (Invoke-Web -Uri $aUrl -Headers $h)
        $k = 0
        foreach ($feat in @($a.features)) {
            $k++
            $pr = $feat.properties
            $facts += New-Fact -Id "nws.alert.$k" -Kind 'weather_alert' -Subject 'Bay Area' -Value $pr.event `
                -Display "National Weather Service alert for the San Francisco area: $($pr.event). $($pr.headline)" `
                -Source 'National Weather Service' -Url $aUrl -Credit 'National Weather Service'
        }
        if ($k -eq 0) {
            $facts += New-Fact -Id 'nws.alert.none' -Kind 'weather_alert' -Subject 'Bay Area' -Value 'none' `
                -Display 'The National Weather Service lists no active alerts for the San Francisco area right now' `
                -Source 'National Weather Service' -Url $aUrl -Credit 'National Weather Service'
        }
    } catch { Add-Note "Weather: alerts lookup failed: $($_.Exception.Message)" }
    $facts
}

# ------------------------------------------------------------ Worldwide weather events (GDACS)
function Get-WorldwideWeatherFacts {
    $from = (Get-Date).AddDays(-[int]$script:Config.gdacs_days_back).ToString('yyyy-MM-dd')
    $to = (Get-Date).ToString('yyyy-MM-dd')
    $url = "https://www.gdacs.org/gdacsapi/api/events/geteventlist/SEARCH?eventlist=$($script:Config.gdacs_event_types)&fromdate=$from&todate=$to&alertlevel=orange;red"
    $credit = 'Global Disaster Alert and Coordination System, GDACS'
    try {
        $txt = Invoke-Web -Uri $url
        # GDACS can answer 200 with an empty body when nothing matches. Treat that as "no events", never as a parse error.
        $feats = @()
        if ($txt -and $txt.Trim()) { $r = ConvertFrom-Json $txt; $feats = @($r.features | Where-Object { $_ }) }
        $facts = @(); $k = 0
        foreach ($feat in $feats) {
            $p = $feat.properties
            if (-not $p -or -not $p.eventtype -or -not $p.eventid) { continue }   # unexpected shape: never make an empty fact
            $k++
            $type = switch ($p.eventtype) { 'TC' { 'tropical cyclone' } 'FL' { 'flood' } default { [string]$p.eventtype } }
            $sev = ''
            if ($p.PSObject.Properties.Name -contains 'severitydata' -and $p.severitydata -and $p.severitydata.severitytext) { $sev = ". $($p.severitydata.severitytext)" }
            $nm = $p.name; if (-not $nm) { $nm = "unnamed $type" }
            $facts += New-Fact -Id ("gdacs.{0}.{1}" -f $p.eventtype, $p.eventid) -Kind 'worldwide_weather_event' -Subject $p.country -Value $p.alertlevel `
                -Display "GDACS rates a $type, $nm, affecting $($p.country) at alert level $($p.alertlevel)$sev" -Source 'GDACS' -Url $url -Credit $credit
        }
        if ($k -eq 0 -and $feats.Count -gt 0) {
            Add-Note 'Worldwide weather (GDACS): the response had events but not in the expected shape, so it was ignored.'
            return @()
        }
        if ($k -eq 0) {
            $facts += New-Fact -Id 'gdacs.none' -Kind 'worldwide_weather_event' -Subject 'World' -Value 'none' `
                -Display "GDACS lists no orange or red cyclone or flood alerts in the last $($script:Config.gdacs_days_back) days" -Source 'GDACS' -Url $url -Credit $credit
        }
        $facts | Select-Object -First 6
    } catch { Add-Note "Worldwide weather (GDACS) failed: $($_.Exception.Message)"; @() }
}

# ------------------------------------------------------------ News headlines (GDELT DOC 2.0)
# GDELT returns headline, link, outlet and date only (no article text). It asks for one request every
# 5 seconds, so we wait between queries. Credit GDELT when publishing.
function Invoke-Gdelt([string]$Query, [int]$Max) {
    $q = [uri]::EscapeDataString($Query)
    $u = "https://api.gdeltproject.org/api/v2/doc/doc?query=$q&mode=artlist&maxrecords=$Max&format=json&timespan=24h&sort=hybridrel"
    # GDELT answers 429 when requests come faster than one per 5 seconds (and sometimes when its servers are busy).
    # Wait it out: up to 4 tries, 12 seconds apart.
    for ($try = 0; $try -lt 4; $try++) {
        try {
            $txt = Invoke-Web -Uri $u -Retries 0 -TimeoutSec 45
            try { $r = ConvertFrom-Json $txt; return @($r.articles) } catch { Start-Sleep -Seconds 6 }
        } catch {
            if ($_.Exception.Message -like '*status 429*' -and $try -lt 3) { Start-Sleep -Seconds 12; continue }
            throw
        }
    }
    @()
}

function ConvertTo-GdeltFact($a, [string]$Kind) {
    $title = ([string]$a.title).Trim()
    # GDELT titles come tokenized ("$1 . 25 Trillion", "24 %", "28 , 000"); put the punctuation back.
    $title = $title -replace '(\d) \. (\d)', '$1.$2' -replace '(\d) , (\d{3})', '$1,$2' -replace '(\d) %', '$1%' -replace '(\d) - (\d)', '$1-$2' -replace ' ([,;:.!?])', '$1' -replace " ' s\b", "'s" -replace '\s{2,}', ' '
    New-Fact -Id ("gdelt.{0}" -f (Get-Sha8 ([string]$a.url))) -Kind $Kind -Subject $a.domain -Value $title `
        -Display "$title ($($a.domain))" -Source 'GDELT' -Url $a.url -Credit "$($a.domain), via GDELT"
}

function Get-WorldNewsCandidates {
    $facts = @{}
    $i = 0
    $fails = 0
    foreach ($q in @($script:Config.gdelt_world_queries)) {
        if ($fails -ge 3) { Add-Note 'World news: GDELT failed three times in a row, so the remaining queries are skipped.'; break }
        if ($i -gt 0) { Start-Sleep -Seconds ([int]$script:Config.gdelt_spacing_seconds) }
        $i++
        Write-Host "  world news query $i ..."
        try {
            foreach ($a in (Invoke-Gdelt $q ([int]$script:Config.gdelt_records_per_query))) {
                if (-not $a.title -or -not $a.url) { continue }
                $f = ConvertTo-GdeltFact $a 'news_candidate'
                $key = ($f.value.ToLower() -replace '[^a-z0-9 ]', '')
                if (-not $facts.ContainsKey($key)) { $facts[$key] = $f }
            }
            $fails = 0
        } catch { $fails++; Add-Note "World news query $i failed: $($_.Exception.Message)" }
    }
    $all = @($facts.Values)
    if ($all.Count -eq 0) { Add-Note 'World news: no headlines came back from GDELT. Skipping the world stories segment.' }
    $all
}

# ------------------------------------------------------------ Tech and AI (Hacker News + GDELT AI headlines + Artificial Analysis)
function Get-TechFacts {
    $facts = @()
    try {
        $hn = ConvertFrom-Json (Invoke-Web -Uri 'https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=50')
        $re = $script:Config.hn_keywords_regex
        foreach ($h in @($hn.hits)) {
            if (-not $h.title -or $h.title -notmatch "(?i)$re") { continue }
            $link = $h.url; if (-not $link) { $link = "https://news.ycombinator.com/item?id=$($h.objectID)" }
            $hk = 'tech_signal'; if ($h.title -match "(?i)$($script:Config.hype_claim_regex)") { $hk = 'unverified_claim' }
            $facts += New-Fact -Id "hn.$($h.objectID)" -Kind $hk -Subject 'Hacker News' -Value $h.title `
                -Display "Hacker News front page: $($h.title) ($($h.points) points, $($h.num_comments) comments)" `
                -Source 'Hacker News' -Url $link -Credit 'Hacker News'
        }
    } catch { Add-Note "Tech: Hacker News failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds ([int]$script:Config.gdelt_spacing_seconds)
    try {
        foreach ($a in (Invoke-Gdelt $script:Config.gdelt_ai_query 25)) {
            if (-not $a.title -or -not $a.url) { continue }
            # The GDELT query is loose; keep only headlines that are really about AI.
            if (([string]$a.title) -notmatch $script:Config.ai_title_regex) { continue }
            $kind = 'ai_news_candidate'
            if (([string]$a.title) -match "(?i)$($script:Config.hype_claim_regex)") { $kind = 'unverified_claim' }
            $f = ConvertTo-GdeltFact $a $kind
            if (-not ($facts | Where-Object { $_.value -eq $f.value })) { $facts += $f }
        }
    } catch { Add-Note "Tech: GDELT AI headlines failed: $($_.Exception.Message)" }
    $facts
}

function Get-BenchmarkFacts([string]$CacheDir) {
    $name = $script:Config.key_env.artificial_analysis
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        Add-Note "Hype: no $name set, so there are no independent benchmark numbers today. Hype will use unverified headline claims only."
        return @()
    }
    # The free tier is rate limited (the docs I found disagree on how tightly), so cache one pull per day.
    $cache = Join-Path $CacheDir ("artificial_analysis_{0}.json" -f (Get-Date -Format 'yyyyMMdd'))
    $url = 'https://artificialanalysis.ai/api/v2/language/models/free'
    try {
        if (Test-Path -LiteralPath $cache) { $r = Read-Json $cache }
        else {
            $txt = Invoke-Web -Uri $url -Headers @{ 'x-api-key' = [Environment]::GetEnvironmentVariable($name) }
            if (-not (Test-Path -LiteralPath $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
            [IO.File]::WriteAllText($cache, $txt, (New-Object Text.UTF8Encoding($false)))
            $r = ConvertFrom-Json $txt
        }
        $rows = @($r.data); if ($rows.Count -eq 0 -and $r -is [array]) { $rows = @($r) }
        $scored = @()
        foreach ($m in $rows) {
            $idx = $null
            if ($m.evaluations -and $m.evaluations.PSObject.Properties.Name -contains 'artificial_analysis_intelligence_index') { $idx = $m.evaluations.artificial_analysis_intelligence_index }
            if ($null -ne $idx) { $scored += [pscustomobject]@{ name = $m.name; creator = $m.model_creator.name; idx = [double]$idx } }
        }
        if ($scored.Count -eq 0) { Add-Note 'Hype: Artificial Analysis response had no intelligence index values (response shape may have changed).'; return @() }
        $facts = @(); $rank = 0
        foreach ($s in ($scored | Sort-Object idx -Descending | Select-Object -First 5)) {
            $rank++
            $facts += New-Fact -Id ("aa.intelligence.{0}" -f $rank) -Kind 'independent_benchmark' -Subject $s.name -Value $s.idx `
                -Display "Artificial Analysis Intelligence Index, an independent benchmark: $($s.name) from $($s.creator) scores $(Format-Num $s.idx), ranked number $rank in this list" `
                -Source 'Artificial Analysis' -Url 'https://artificialanalysis.ai/' -Credit 'Artificial Analysis (independent)'
        }
        $facts
    } catch { Add-Note "Hype: Artificial Analysis failed: $($_.Exception.Message)"; @() }
}
