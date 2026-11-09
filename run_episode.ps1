<#
.SYNOPSIS
  Builds one full episode script (text only) for "SF Bay Area's Officially Artificial News".

.DESCRIPTION
  Pipeline: pull data -> facts store -> editor picks the top 3 world stories -> producer plans
  segments, mood and the calm-down trigger -> each anchor's model writes its lines -> fact check
  (code, not AI) with up to 2 rewrites per segment -> transcript and reports.

  Output goes to .\episodes\<date>\ : facts.json, editor.json, script.json, factcheck.json, transcript.txt

.PARAMETER DryRun
  No API keys or network needed. Uses fixtures\sample_facts.json (SYNTHETIC data) and a mock in place
  of the AI models, so you can test the plumbing. Never touches saved mood or logs.

.PARAMETER NoSave
  Real run, but does not update state\mood.json or logs\editor_log.jsonl (use while experimenting).

.PARAMETER FactsFile
  Use an existing facts.json instead of pulling data again.

.EXAMPLE
  .\run_episode.ps1 -DryRun
  .\run_episode.ps1 -NoSave
  .\run_episode.ps1
#>
param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [int]$Seed = 0,
    [switch]$DryRun,
    [switch]$NoSave,
    [string]$FactsFile
)

. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'data_pulls.ps1')
. (Join-Path $PSScriptRoot 'factcheck.ps1')
Import-Config
$script:UseMock = [bool]$DryRun
$cfg = $script:Config

# ----------------------------------------------------------------- helpers
function Get-Prompt([string]$Name) { Get-Content -LiteralPath (Join-Path $script:Root "prompts\$Name.txt") -Raw -Encoding UTF8 }

function Get-MoodLabel([int]$v) {
    if ($v -le -2) { return 'openly irritated with' }
    if ($v -eq -1) { return 'a bit wary of' }
    if ($v -eq 0) { return 'neutral toward' }
    if ($v -eq 1) { return 'friendly toward' }
    'genuinely fond of'
}

function Get-MoodDelta($Rng) { $r = $Rng.Next(0, 100); if ($r -lt 25) { return -1 }; if ($r -lt 75) { return 0 }; 1 }
function Limit-Mood([int]$v) { [math]::Max(-2, [math]::Min(2, $v)) }

function Get-SourceCredit($Refs) {
    $c = @()
    foreach ($id in @($Refs)) { if ($script:FactIndex.ContainsKey($id)) { $c += $script:FactIndex[$id].credit } }
    (@($c | Select-Object -Unique) -join '; ')
}

function New-MockLines($Facts, [string]$Anchor, [string]$Id) {
    $lines = @()
    # Test hook: set $env:OAN_MOCK_FAULT to a segment id to make the mock invent a number there (proves the retry and review path).
    if ($env:OAN_MOCK_FAULT -eq $Id) {
        return @(@{ text = 'The temperature will be 777 degrees.'; fact_refs = @(); claim_type = 'none'; emotion = 'flat'; intensity = 2; lower_third = '' })
    }
    if (@($Facts).Count -eq 0) {
        return @(@{ text = "DRY RUN mock line for $Id."; fact_refs = @(); claim_type = 'none'; emotion = 'flat'; intensity = 2; lower_third = '' })
    }
    $take = @($Facts | Select-Object -First 6); $i = 0
    foreach ($f in $take) {
        $i++
        $text = [string]$f.display
        $ct = 'none'; $int = 4
        if ($Id -eq 'hype') {
            if ($f.kind -eq 'independent_benchmark') { $ct = 'independent' }
            else { $ct = 'unverified_claim'; $text = "This is an unverified claim from a headline: $text" }
        }
        if ($Anchor -eq 'pat') { $int = 5; if ($i -eq $take.Count) { $int = 9 } }
        $lines += @{ text = $text; fact_refs = @($f.id); claim_type = $ct; emotion = 'flat'; intensity = $int; lower_third = '' }
    }
    $lines
}

# Writes one segment with one anchor's model, then fact-checks it; up to 2 rewrites.
function New-Segment {
    param([string]$Id, [string]$Anchor, [int]$Budget, [string]$Task, $Facts, [string]$Context = '')
    $Facts = @($Facts)
    $allowed = @($Facts | ForEach-Object { $_.id })
    $factJson = ConvertTo-Json -InputObject @($Facts | ForEach-Object { [ordered]@{ id = $_.id; kind = $_.kind; fact = $_.display } }) -Depth 4
    if ($Facts.Count -eq 0) { $factJson = '[]  (no facts for this segment: use no numbers and no names other than the anchors)' }
    $sys = (Get-Prompt 'shared_rules') + "`n`n" + (Get-Prompt $Anchor)
    $baseUser = "SEGMENT: $Id`nWORD BUDGET: $Budget words in total`n$Context`nTASK: $Task`n`nFACTS:`n$factJson`n`nReturn the JSON object only."
    $validate = {
        param($o)
        $p = @()
        if (-not $o.lines -or @($o.lines).Count -eq 0) { $p += 'The "lines" array is missing or empty.' }
        else { foreach ($l in @($o.lines)) { if (-not $l.text -or -not ([string]$l.text).Trim()) { $p += 'Every line needs non-empty "text".' } } }
        $p
    }
    $user = $baseUser; $seg = $null; $attempts = 0
    while ($true) {
        $attempts++
        if ($script:UseMock) { $raw = New-MockLines $Facts $Anchor $Id }
        else { $raw = @((Invoke-LlmJson -Role $Anchor -System $sys -User $user -Validate $validate).lines) }
        $lines = @()
        foreach ($l in $raw) {
            $refs = @($l.fact_refs | Where-Object { $_ })
            $ints = 3; try { $ints = [math]::Max(0, [math]::Min(10, [int]$l.intensity)) } catch { }
            $ct = [string]$l.claim_type; if (-not $ct) { $ct = 'none' }
            $lines += [ordered]@{
                speaker = $Anchor; text = ([string]$l.text).Trim(); fact_refs = $refs; claim_type = $ct
                emotion = [string]$l.emotion; intensity = $ints; lower_third = [string]$l.lower_third
                source_credit = (Get-SourceCredit $refs); pause_after_ms = 350
            }
        }
        $seg = [ordered]@{ id = $Id; anchor = $Anchor; episode_date = $Date; word_budget = $Budget; allowed_fact_ids = $allowed; lines = $lines }
        $probs = @(Test-Segment -Segment $seg -Config $cfg)
        $fails = @($probs | Where-Object { $_.level -eq 'FAIL' })
        if ($fails.Count -eq 0 -or $attempts -ge 3) { break }
        Write-Host "    fact check failed for $Id (attempt $attempts); asking $Anchor to rewrite" -ForegroundColor Yellow
        $user = $baseUser + "`n`nYOUR PREVIOUS ANSWER FAILED THE FACT CHECK. Rewrite the whole segment and fix every problem:`n- " + (($fails | ForEach-Object { $_.message }) -join "`n- ")
    }
    $status = 'PASS'
    if (@($probs | Where-Object { $_.level -eq 'FAIL' }).Count -gt 0) { $status = 'NEEDS_REVIEW' }
    elseif (@($probs | Where-Object { $_.level -eq 'WARN' }).Count -gt 0) { $status = 'PASS_WITH_WARNINGS' }
    $seg['check'] = [ordered]@{ status = $status; attempts = $attempts; problems = $probs }
    $seg
}

# A short on-air back and forth between Big Russ and Pat. Each line is a separate call to that anchor's own
# model (so Russ stays Claude and Pat stays Gemini). Opinions and reactions are allowed; facts are not invented:
# every line is fact-checked on its own and rewritten up to 2 times.
function New-Exchange {
    param([string]$Id, [string]$Starter, [int]$Budget, [string]$Topic, $Facts)
    $Facts = @($Facts)
    $allowed = @($Facts | ForEach-Object { $_.id })
    $factJson = ConvertTo-Json -InputObject @($Facts | ForEach-Object { [ordered]@{ id = $_.id; kind = $_.kind; fact = $_.display } }) -Depth 4
    if ($Facts.Count -eq 0) { $factJson = '[]  (no facts: use no numbers and no names other than the anchors)' }
    $perTurn = [int]$cfg.roundtable_words_per_turn
    $turns = [math]::Max(4, [int][math]::Round($Budget / [double]$perTurn))
    $sys0 = (Get-Prompt 'shared_rules') + "`n`n"
    $d = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $script:Inv)
    $dateNums = @{}; foreach ($t in @($d.Year.ToString(), $d.Month.ToString(), $d.Day.ToString())) { $dateNums[$t] = $true }
    $validate = {
        param($o)
        $p = @(); $l = @($o.lines)
        if ($l.Count -ne 1) { $p += 'Return exactly one line in "lines".' }
        else {
            $n = Get-WordCount ([string]$l[0].text)
            if ($n -lt 8) { $p += 'The line is too short: write 20 to 45 words.' }
            if ($n -gt 75) { $p += 'The line is too long: write 20 to 45 words.' }
        }
        $p
    }
    $lines = @(); $speaker = $Starter; $maxAttempts = 1
    for ($t = 1; $t -le $turns; $t++) {
        $other = 'russ'; if ($speaker -eq 'russ') { $other = 'pat' }
        $myName = 'Pat'; $otherName = 'Big Russ'; $mood = [int]$state.pat_to_russ
        if ($speaker -eq 'russ') { $myName = 'Big Russ'; $otherName = 'Pat'; $mood = [int]$state.russ_to_pat }
        $convo = (@($lines | ForEach-Object { "$($_.speaker.ToUpper()): $($_.text)" }) -join "`n")
        if (-not $convo) { $convo = '(nothing yet: you speak first)' }
        $pos = 'React directly to what was just said, add your own take, and do not repeat a point already made.'
        if ($t -eq 1) { $pos = 'Open the chat with your own reaction to the items.' }
        elseif ($t -eq $turns) { $pos = 'This is the last line of the chat: land it with a natural button. Do not say goodbye; the show goes on.' }
        $baseUser = "SEGMENT: $Id (a short back and forth between Big Russ and Pat)`nYou are $myName talking to $otherName. Your current feeling toward ${otherName}: $(Get-MoodLabel $mood).`nTOPIC: $Topic`nLINE $t OF $turns. $pos`nThis call overrides the word budget rule: your whole answer is ONE line of 20 to 45 words.`n`nFACTS you may refer to:`n$factJson`n`nCONVERSATION SO FAR:`n$convo`n`nReturn the JSON object only."
        $sys = $sys0 + (Get-Prompt $speaker) + "`n`n" + (Get-Prompt 'roundtable')
        $user = $baseUser; $attempts = 0; $line = $null
        while ($true) {
            $attempts++
            if ($script:UseMock) {
                $raw = [pscustomobject]@{ text = "DRY RUN mock reaction from $speaker, turn $(if ($t -gt 1) { 'later' } else { 'first' })."; fact_refs = @(); claim_type = 'none'; emotion = 'flat'; intensity = 3; lower_third = '' }
                if ($env:OAN_MOCK_FAULT -eq $Id -and $t -eq 2 -and $attempts -eq 1) { $raw.text = 'It will be 777 degrees out there.' }
            } else { $raw = @((Invoke-LlmJson -Role $speaker -System $sys -User $user -Validate $validate).lines)[0] }
            $refs = @($raw.fact_refs | Where-Object { $_ })
            $ints = 3; try { $ints = [math]::Max(0, [math]::Min(10, [int]$raw.intensity)) } catch { }
            $line = [ordered]@{
                speaker = $speaker; text = ([string]$raw.text).Trim(); fact_refs = $refs; claim_type = 'none'
                emotion = [string]$raw.emotion; intensity = $ints; lower_third = [string]$raw.lower_third
                source_credit = (Get-SourceCredit $refs); pause_after_ms = 250
            }
            $pr = @(Test-Line -Line ([pscustomobject]$line) -AllowedIds $allowed -SegmentId $Id -DateNumbers $dateNums -NameAllowlist @($cfg.name_allowlist))
            $fl = @($pr | Where-Object { $_.level -eq 'FAIL' })
            $mkx = [string]$cfg.anchor_engines.$speaker.maker_regex
            $touch = ($line.text -match $mkx)
            foreach ($rid in $refs) { if ($script:FactIndex.ContainsKey($rid) -and $script:FactIndex[$rid].kind -ne 'anchor_identity' -and ("$($script:FactIndex[$rid].display)" -match $mkx)) { $touch = $true } }
            $already = @($lines | Where-Object { $_.speaker -eq $speaker -and $_.text -match [string]$cfg.disclosure_regex }).Count -gt 0
            if ($touch -and -not $already -and $line.text -notmatch [string]$cfg.disclosure_regex) {
                $fl += @{ level = 'FAIL'; code = 'disclosure_missing'; message = "You are talking about your own maker ($($cfg.anchor_engines.$speaker.label)). Start with a short disclosure, for example: ""Full disclosure, I run on $($cfg.anchor_engines.$speaker.label)""." }
            }
            $factTouch = $false
            foreach ($rid in $refs) { if ($script:FactIndex.ContainsKey($rid) -and $script:FactIndex[$rid].kind -ne 'anchor_identity' -and ("$($script:FactIndex[$rid].display)" -match $mkx)) { $factTouch = $true } }
            if (-not $factTouch -and $line.text -match $mkx) {
                $fl += @{ level = 'FAIL'; code = 'engine_repeat'; message = "Do not mention your own engine here: nothing in this line is about your maker. Remove it." }
            }
            if ($fl.Count -eq 0 -or $attempts -ge 3) { break }
            Write-Host "    fact check failed for $Id line $t (attempt $attempts); asking $speaker to rewrite" -ForegroundColor Yellow
            $user = $baseUser + "`n`nYOUR PREVIOUS LINE FAILED THE FACT CHECK. Write a new line and fix every problem. Opinions are fine; facts must come only from FACTS and be cited in fact_refs:`n- " + (($fl | ForEach-Object { $_.message }) -join "`n- ")
        }
        $maxAttempts = [math]::Max($maxAttempts, $attempts)
        $lines += $line
        $speaker = $other
    }
    $seg = [ordered]@{ id = $Id; anchor = 'russ+pat'; episode_date = $Date; word_budget = $Budget; allowed_fact_ids = $allowed; lines = $lines }
    $probs = @(Test-Segment -Segment $seg -Config $cfg)
    $status = 'PASS'
    if (@($probs | Where-Object { $_.level -eq 'FAIL' }).Count -gt 0) { $status = 'NEEDS_REVIEW' }
    elseif (@($probs | Where-Object { $_.level -eq 'WARN' }).Count -gt 0) { $status = 'PASS_WITH_WARNINGS' }
    $seg['check'] = [ordered]@{ status = $status; attempts = $maxAttempts; problems = $probs }
    $seg
}

function Select-Facts($All, [string]$Kind) { @($All | Where-Object { $_.kind -eq $Kind }) }

# ----------------------------------------------------------------- run folder, state
$runName = $Date; if ($DryRun) { $runName = "$Date-dryrun" }
$runDir = Join-Path $script:Root "episodes\$runName"
$rawDir = Join-Path $runDir 'raw'
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null
$statePath = Join-Path $script:Root 'state\mood.json'
$save = (-not $DryRun) -and (-not $NoSave)

$state = [pscustomobject]@{ episode_count = 0; russ_to_pat = 0; pat_to_russ = 0; last_calm_down_episode = -99 }
if (Test-Path -LiteralPath $statePath) { $state = Read-Json $statePath }
if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 1000000 }
$rng = New-Object System.Random($Seed)
$episodeNumber = [int]$state.episode_count + 1
Write-Host "Episode $Date  (seed $Seed, episode number $episodeNumber, dry run: $DryRun)" -ForegroundColor Cyan

Push-Location $script:Root
try {
    # ------------------------------------------------------------- 1. data
    Write-Host '1/6 Gathering facts...' -ForegroundColor Cyan
    $all = @()
    if ($FactsFile) { $all = @((Read-Json $FactsFile).facts) }
    elseif ($DryRun) { $all = @((Read-Json (Join-Path $script:Root 'fixtures\sample_facts.json')).facts); Add-Note 'DRY RUN: using SYNTHETIC fixture facts and a mock instead of the AI models.' }
    else {
        $all += @(Get-WarriorsFacts $rawDir)
        $all += @(Get-BayAreaWeatherFacts)
        $all += @(Get-WorldwideWeatherFacts)
        $all += @(Get-WorldNewsCandidates)
        $all += @(Get-TechFacts)
        $all += @(Get-BenchmarkFacts (Join-Path $script:Root 'state\cache'))
    }
    $seen = @{}; $facts = @()
    foreach ($f in $all) { if (-not $seen.ContainsKey($f.id)) { $seen[$f.id] = $true; $facts += $f } }
    foreach ($k in @('russ', 'jenny', 'pat')) {
        $e = $cfg.anchor_engines.$k
        $facts += New-Fact -Id "anchor.$k" -Kind 'anchor_identity' -Subject $e.name -Value $e.label -Display "$($e.name) is powered by $($e.label)." -Source 'Show setup' -Credit $e.label
    }
    Register-Facts $facts
    Write-Json ([ordered]@{ episode_date = $Date; notes = @($script:PullNotes); facts = $facts }) (Join-Path $runDir 'facts.json')
    Write-Host "    $($facts.Count) facts"

    # ------------------------------------------------------------- 2. editor
    Write-Host '2/6 Editor step: choosing the top 3 world stories...' -ForegroundColor Cyan
    $cands = @(Select-Facts $facts 'news_candidate' | Select-Object -First 80)
    $picks = @()
    if ($cands.Count -ge 3) {
        $candText = ($cands | ForEach-Object { "$($_.id) | $($_.display)" }) -join "`n"
        $edUser = "Today is $Date. Candidate headlines (id | headline (outlet)):`n$candText"
        if ($DryRun) {
            $ed = [pscustomobject]@{ top3 = @(1..3 | ForEach-Object { [pscustomobject]@{ rank = $_; fact_id = $cands[$_ - 1].id; reason = 'DRY RUN mock reason.' } }) }
        } else {
            $idsOk = @($cands | ForEach-Object { $_.id })
            $edValidate = {
                param($o)
                $p = @(); $t = @($o.top3)
                if ($t.Count -ne 3) { $p += 'top3 must contain exactly 3 items.' }
                else {
                    $ids = @($t | ForEach-Object { $_.fact_id })
                    if (@($ids | Select-Object -Unique).Count -ne 3) { $p += 'The 3 fact_ids must be different.' }
                    foreach ($i in $ids) { if ($idsOk -notcontains $i) { $p += "fact_id $i is not in the candidate list." } }
                    foreach ($x in $t) { if (-not $x.reason -or @(([string]$x.reason) -split '\s+').Count -gt 40) { $p += 'Each reason must be one sentence of 40 words or fewer.' } }
                }
                $p
            }.GetNewClosure()
            $ed = Invoke-LlmJson -Role 'editor' -System (Get-Prompt 'editor') -User $edUser -Validate $edValidate
        }
        $picks = @($ed.top3 | Sort-Object { [int]$_.rank })
        $edLog = [ordered]@{ date = $Date; model = $cfg.models.editor.model; dry_run = [bool]$DryRun; candidates = $cands.Count
                             picks = @($picks | ForEach-Object { [ordered]@{ rank = [int]$_.rank; fact_id = $_.fact_id; headline = $script:FactIndex[$_.fact_id].value; reason = $_.reason } }) }
        Write-Json $edLog (Join-Path $runDir 'editor.json')
        if ($save) { Add-JsonLine $edLog (Join-Path $script:Root 'logs\editor_log.jsonl') }
    } else { Add-Note 'Editor: fewer than 3 world headlines, so the world stories segment is skipped.' }

    # ------------------------------------------------------------- 3. segments
    Write-Host '3/6 Writing segments...' -ForegroundColor Cyan
    $B = $cfg.budgets
    $segs = @{}   # id -> segment
    $skipped = @()

    # Tech
    $techFacts = @(@(Select-Facts $facts 'tech_signal' | Select-Object -First 8) + @(Select-Facts $facts 'unverified_claim' | Where-Object { $_.source -eq 'Hacker News' } | Select-Object -First 4) + @(Select-Facts $facts 'ai_news_candidate' | Select-Object -First 8))
    if ($techFacts.Count -gt 0) {
        Write-Host '    tech (Russ)'
        $segs['tech'] = New-Segment -Id 'tech' -Anchor 'russ' -Budget $B.tech -Facts $techFacts -Context 'Your usual voice. Open with a clipped welcome to the tech and AI segment.' `
            -Task 'Present the day in tech and AI. Report every item in the facts that is really about AI or tech (up to 6), each in two sentences. If there are fewer than 3, say it is a quiet day instead of padding. These are headlines and Hacker News front page items, not verified reports: say what they say and no more. For Hacker News items say they are trending there.'
    } else { $skipped += 'tech (no tech facts)' }

    # Hype
    $hypeFacts = @(@(Select-Facts $facts 'independent_benchmark') + @(Select-Facts $facts 'unverified_claim' | Select-Object -First 4))
    if ($hypeFacts.Count -gt 0) {
        Write-Host '    hype (Russ)'
        $segs['hype'] = New-Segment -Id 'hype' -Anchor 'russ' -Budget $B.hype -Facts $hypeFacts -Context 'This is your signature segment, Calling Out the Hype. Say the segment name once.' `
            -Task 'Go through the claims. For each claim line, say the source and say out loud whether it is independent (kind independent_benchmark) or an unverified claim from a headline. Set claim_type to match. Be skeptical in tone, not in fact: do not say a claim is false, say it is not independently verified. Do not call any company liars.'
    } else {
        Write-Host '    hype (Russ): no claims today, short segment'
        $segs['hype'] = New-Segment -Id 'hype' -Anchor 'russ' -Budget $B.hype_empty -Facts @() -Context 'This is your signature segment, Calling Out the Hype. Say the segment name once.' `
            -Task 'There is no AI claim worth calling out today. Say so plainly in two or three short lines, and say what you look for: independent measurements versus unverified claims from a company or a headline. No facts, no numbers, no outside names.'
    }

    # World
    if ($picks.Count -eq 3) {
        Write-Host '    world (Jenny)'
        $worldFacts = @($picks | ForEach-Object { $script:FactIndex[$_.fact_id] })
        $rankNote = (@($picks | ForEach-Object { "Story $($_.rank) is fact $($_.fact_id)" }) -join '; ')
        $segs['world'] = New-Segment -Id 'world' -Anchor 'jenny' -Budget $B.world -Facts $worldFacts -Context 'Open with a short, steady welcome to the top world stories.' `
            -Task "Present the top 3 world stories in rank order. $rankNote. Two or three sentences per story, only what each headline supports, naming the outlet that reported it."
    } else { $skipped += 'world (editor step not possible)' }

    # Weather
    $wxFacts = @(@(Select-Facts $facts 'weather_forecast') + @(Select-Facts $facts 'weather_alert') + @(Select-Facts $facts 'worldwide_weather_event'))
    if ($wxFacts.Count -gt 0) {
        Write-Host '    weather (Jenny)'
        $segs['weather'] = New-Segment -Id 'weather' -Anchor 'jenny' -Budget $B.weather -Facts $wxFacts -Context 'Calm, practical. No welcome needed.' `
            -Task 'Give the Bay Area weather first: summarize San Francisco, Oakland and San Jose from the forecast facts. Then any active alert. Then worldwide events, using only the GDACS facts provided; if the only worldwide fact says there are none, say so in one sentence.'
    } else { $skipped += 'weather (no weather facts)' }

    # Warriors
    $wFacts = @($facts | Where-Object { $_.id -match '\.score\.|\.winner$|\.margin$|\.record\.GS$|\.leader\.GS\.(PTS|REB|STL|BLK|FTPCT)$' })
    if (@($wFacts | Where-Object { $_.id -match '\.leader\.GS\.' }).Count -gt 0) {
        Write-Host '    warriors (Pat)'
        $segs['warriors'] = New-Segment -Id 'warriors' -Anchor 'pat' -Budget $B.warriors -Facts $wFacts -Context ("Your current feeling toward Big Russ: " + (Get-MoodLabel ([int]$state.pat_to_russ)) + ' him.') `
            -Task 'Celebrate, with real enthusiasm, who had a good game for the Warriors in the latest game. Start with the final result. Then, in this order and only if a fact exists for it: most points, most rebounds, most steals, most blocks, best free throw percentage (say the minimum of 5 attempts). Name every tied player.'
    } else { $skipped += 'warriors (no game stats)' }

    # Reactions: Russ and Pat talk about the day's news, weather and sports. Opinion only, no new facts.
    function Get-CitedIds($Seg) { $ids = @(); if ($Seg) { foreach ($l in @($Seg.lines)) { foreach ($r in @($l.fact_refs)) { if ($r -and $ids -notcontains $r) { $ids += $r } } } }; $ids }
    $newsIds = @()
    foreach ($pair in @(@('world', 3), @('tech', 4), @('hype', 2))) {
        if ($segs.ContainsKey($pair[0])) { $newsIds += @(Get-CitedIds $segs[$pair[0]] | Select-Object -First $pair[1]) }
    }
    $newsIds = @($newsIds | Select-Object -Unique)
    if ($newsIds.Count -gt 0) {
        Write-Host '    react to the news (Russ and Pat)'
        $segs['react_news'] = New-Exchange -Id 'react_news' -Starter 'russ' -Budget $B.react_news -Facts @($newsIds | ForEach-Object { $script:FactIndex[$_] }) `
            -Topic "React to the tech, AI and world headlines that were just reported. Russ and Pat see it differently because of their temperaments (Russ is skeptical, thrifty and wary of big promises; Pat is generous and people-first). Talk about the stories and what they mean for ordinary people, not about parties, candidates or politicians. Never joke about deaths, war, disasters or suffering; keep jokes for tech, hype and each other. Next up in the show is the weather, so do not tease anything else."
    }
    if ($wxFacts.Count -gt 0) {
        Write-Host '    react to the weather (Russ and Pat)'
        $segs['react_weather'] = New-Exchange -Id 'react_weather' -Starter 'pat' -Budget $B.react_weather -Facts @($wxFacts | Select-Object -First 14) `
            -Topic "React to today's Bay Area weather, the local alerts and the worldwide alert check. Light, local and a little funny, but any alert is treated seriously (practical advice only, no new facts). Next up in the show is the Warriors game."
    }
    if ($segs.ContainsKey('warriors')) {
        Write-Host '    react to the Warriors (Russ and Pat)'
        $segs['react_sports'] = New-Exchange -Id 'react_sports' -Starter 'pat' -Budget $B.react_sports -Facts $wFacts `
            -Topic "React to the Warriors game and the standouts Pat just celebrated. Pat is thrilled. Russ is the dry fan who still respects what he is seeing. This is the last chat before the sign-off, so do not say on to the next story and do not tease more news. No complaints about opponents or officials, no claims about any player's character or intent."
    }

    # ------------------------------------------------------------- 4. producer: calm down, teases, sign-off
    Write-Host '4/6 Producer: calm-down trigger, teases, sign-off...' -ForegroundColor Cyan
    $maxPat = 0
    if ($segs.ContainsKey('warriors')) { $maxPat = (@($segs['warriors'].lines | ForEach-Object { [int]$_.intensity }) | Measure-Object -Maximum).Maximum }
    $cd = $cfg.calm_down
    $cooldownOk = (($episodeNumber - [int]$state.last_calm_down_episode) -ge [int]$cd.cooldown_episodes)
    $calm = ($maxPat -ge [int]$cd.intensity_threshold) -and ($cooldownOk -or $maxPat -ge [int]$cd.always_fire_at)
    Write-Host "    Pat's peak intensity: $maxPat  ->  calm-down fires: $calm"

    function Get-CitedFacts($Seg, [int]$N) {
        $ids = @(); foreach ($l in @($Seg.lines)) { foreach ($r in @($l.fact_refs)) { if ($r -and $ids -notcontains $r) { $ids += $r } } }
        @($ids | Select-Object -First $N | ForEach-Object { $script:FactIndex[$_] })
    }
    $teaseSeg = @()
    $teasePlan = @(
        @{ key = 'tech'; anchor = 'russ'; hello = "Open with a very short welcome to ""SF Bay Area's Officially Artificial News"", then tease." },
        @{ key = 'world'; anchor = 'jenny'; hello = 'Tease only.' },
        @{ key = 'warriors'; anchor = 'pat'; hello = 'Tease only, with energy.' }
    )
    foreach ($t in $teasePlan) {
        if (-not $segs.ContainsKey($t.key)) { continue }
        $cf = Get-CitedFacts $segs[$t.key] 2
        if ($cf.Count -eq 0) { continue }
        $cf = @($script:FactIndex["anchor.$($t.anchor)"]) + @($cf)
        $teaseSeg += New-Segment -Id "cold_open_$($t.anchor)" -Anchor $t.anchor -Budget $B.tease -Facts $cf -Context $t.hello `
            -Task "Write one short spoken passage of at most 3 sentences. First say who you are and which AI model powers you, using the fact anchor.$($t.anchor) (for example: I'm $($cfg.anchor_engines.($t.anchor).name), powered by $($cfg.anchor_engines.($t.anchor).label)). Then tease your upcoming segment in a natural spoken sentence, using only the other facts provided. If you use a score, say who beat whom. Cite every fact you use."
    }

    $moodR = [int]$state.russ_to_pat; $moodP = [int]$state.pat_to_russ
    $beatPool = @{
        warm    = @('Russ admits, in his gruff way, that the show is better with Pat on it.', 'Russ and Pat find one small thing about the day they agree on.', 'Russ offers Pat a rare, short compliment.')
        neutral = @('A short, friendly bit of back and forth about how loud the show got.', 'Russ teases Pat about how much Pat loves basketball.', 'Pat teases Russ about being a grump.')
        tense   = @('Russ is short with Pat, and Pat bristles but stays professional.', 'Pat gently pokes at Russ''s skepticism and Russ is not amused.', 'They disagree about something small and leave it unresolved.')
    }
    $tone = 'neutral'; if (($moodR + $moodP) -ge 2) { $tone = 'warm' } elseif (($moodR + $moodP) -le -2) { $tone = 'tense' }
    $beat = $beatPool[$tone][$rng.Next(0, 3)]
    $calmText = ''; if ($calm) { $calmText = "Pat's Warriors segment was extremely loud. Russ tells Pat to calm down: this is the moment the viewers wait for." }

    $so1 = New-Segment -Id 'signoff_open' -Anchor 'russ' -Budget $B.signoff_open -Facts @() `
        -Context ("Your current feeling toward Pat: " + (Get-MoodLabel $moodR) + ' Pat.') `
        -Task "Close the show. Russ thanks the viewers and turns to Pat. Beat for tonight: $beat $calmText No facts, no numbers, no outside names."
    $so2 = New-Segment -Id 'signoff_reply' -Anchor 'pat' -Budget $B.signoff_reply -Facts @() `
        -Context ("Your current feeling toward Big Russ: " + (Get-MoodLabel $moodP) + ' him.') `
        -Task ("Pat answers Russ's closing line, in character: " + (($so1.lines | ForEach-Object { $_.text }) -join ' ') + " Beat for tonight: $beat $calmText No facts, no numbers, no outside names.")
    $so3 = New-Segment -Id 'signoff_close' -Anchor 'russ' -Budget $B.signoff_close -Facts @() `
        -Task ("Russ gives the very last short line of the show. His own earlier closing line was: " + (($so1.lines | ForEach-Object { $_.text }) -join ' ') + " Pat then replied: " + (($so2.lines | ForEach-Object { $_.text }) -join ' ') + ' No facts, no numbers, no outside names.')

    # ------------------------------------------------------------- 5. assemble
    Write-Host '5/6 Assembling script...' -ForegroundColor Cyan
    $coldLines = @(); $coldChecks = @()
    foreach ($ts in $teaseSeg) { $coldLines += @($ts.lines); $coldChecks += $ts }
    $order = @()
    if ($coldLines.Count -gt 0) {
        $order += [ordered]@{ id = 'cold_open'; anchor = 'all'; lines = $coldLines; sub = $coldChecks; word_budget = ($B.tease * $coldChecks.Count) }
    }
    foreach ($k in @('tech', 'hype', 'world', 'react_news', 'weather', 'react_weather', 'warriors', 'react_sports')) { if ($segs.ContainsKey($k)) { $order += $segs[$k] } }
    $so = @($so1, $so2, $so3)
    $order += [ordered]@{ id = 'signoff'; anchor = 'russ+pat'; lines = @($so1.lines + $so2.lines + $so3.lines); sub = $so; word_budget = ($B.signoff_open + $B.signoff_reply + $B.signoff_close) }

    $report = @(); $worst = 'PASS'; $totalWords = 0
    foreach ($s in $order) {
        $subs = @($s); if ($s.Contains('sub')) { $subs = @($s['sub']) }
        $probs = @(); $att = 0; $st = 'PASS'
        foreach ($x in $subs) {
            $probs += @($x.check.problems); $att = [math]::Max($att, $x.check.attempts)
            if ($x.check.status -eq 'NEEDS_REVIEW') { $st = 'NEEDS_REVIEW' } elseif ($x.check.status -eq 'PASS_WITH_WARNINGS' -and $st -eq 'PASS') { $st = 'PASS_WITH_WARNINGS' }
        }
        $words = 0; foreach ($l in @($s.lines)) { $words += Get-WordCount $l.text }
        $totalWords += $words
        $report += [ordered]@{ segment = $s.id; anchor = $s.anchor; words = $words; word_budget = $s.word_budget; attempts = $att; status = $st; problems = $probs }
        if ($st -eq 'NEEDS_REVIEW') { $worst = 'NEEDS_REVIEW' } elseif ($st -eq 'PASS_WITH_WARNINGS' -and $worst -eq 'PASS') { $worst = 'PASS_WITH_WARNINGS' }
        # segment-end pause
        if (@($s.lines).Count -gt 0) { @($s.lines)[-1].pause_after_ms = 900 }
    }
    $seconds = [math]::Round($totalWords / ($cfg.words_per_minute / 60.0)) + 10 + 12
    $runtime = '{0}:{1:00}' -f [math]::Floor($seconds / 60), ($seconds % 60)

    # mood for tomorrow
    $moodOutR = Limit-Mood ($moodR + (Get-MoodDelta $rng))
    $moodOutP = Limit-Mood ($moodP + (Get-MoodDelta $rng))
    if ($calm) { $moodOutP = Limit-Mood ($moodOutP - 1) }   # being told to calm down on air stings a little

    $out = [ordered]@{
        episode_date = $Date; episode_number = $episodeNumber; seed = $Seed; dry_run = [bool]$DryRun
        models = $cfg.models; mood_in = [ordered]@{ russ_to_pat = $moodR; pat_to_russ = $moodP }
        mood_out = [ordered]@{ russ_to_pat = $moodOutR; pat_to_russ = $moodOutP }
        calm_down = [ordered]@{ fired = $calm; pat_peak_intensity = $maxPat; banter_beat = $beat }
        estimated_runtime = $runtime; total_words = $totalWords; fact_check_status = $worst
        skipped_segments = $skipped; pull_notes = @($script:PullNotes)
        segments = @($order | ForEach-Object { $c = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -ne 'sub') { $c[$k] = $_[$k] } }; $c })
    }
    Write-Json $out (Join-Path $runDir 'script.json')
    Write-Json ([ordered]@{ episode_date = $Date; status = $worst; segments = $report }) (Join-Path $runDir 'factcheck.json')

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("SF BAY AREA'S OFFICIALLY ARTIFICIAL NEWS - $Date  (episode $episodeNumber, seed $Seed)")
    [void]$sb.AppendLine("Estimated runtime $runtime ($totalWords words)  |  fact check: $worst")
    if ($DryRun) { [void]$sb.AppendLine('*** DRY RUN: synthetic data, mock anchors ***') }
    [void]$sb.AppendLine('')
    foreach ($s in $order) {
        [void]$sb.AppendLine("=== $($s.id.ToUpper()) ===")
        foreach ($l in @($s.lines)) {
            [void]$sb.AppendLine(("{0}: {1}" -f $l.speaker.ToUpper(), $l.text))
            if ($l.source_credit) { [void]$sb.AppendLine("    [on screen] source: $($l.source_credit)") }
            if ($l.lower_third) { [void]$sb.AppendLine("    [on screen] caption: $($l.lower_third)") }
        }
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('=== FACT CHECK ===')
    foreach ($r in $report) {
        [void]$sb.AppendLine(("{0,-14} {1,-20} {2} words (budget {3}), attempts {4}" -f $r.segment, $r.status, $r.words, $r.word_budget, $r.attempts))
        foreach ($p in @($r.problems)) { [void]$sb.AppendLine("    $($p.level): $($p.message)") }
    }
    if ($skipped.Count -gt 0) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("Skipped segments: $($skipped -join '; ')") }
    foreach ($n in @($script:PullNotes)) { [void]$sb.AppendLine("Note: $n") }
    [IO.File]::WriteAllText((Join-Path $runDir 'transcript.txt'), $sb.ToString(), (New-Object Text.UTF8Encoding($false)))

    # ------------------------------------------------------------- 6. save state
    if ($save) {
        $newState = [ordered]@{ episode_count = $episodeNumber; russ_to_pat = $moodOutR; pat_to_russ = $moodOutP
                                last_calm_down_episode = $(if ($calm) { $episodeNumber } else { [int]$state.last_calm_down_episode }) }
        Write-Json $newState $statePath
    }
    Write-Host '6/6 Done.' -ForegroundColor Cyan
    Write-Host "Fact check: $worst   |   estimated runtime $runtime   |   $totalWords words"
    Write-Host "Read it:  $(Join-Path $runDir 'transcript.txt')"
    if (-not $save) { Write-Host '(Mood and editor log were NOT updated: dry run or -NoSave.)' }
}
finally { Pop-Location }
