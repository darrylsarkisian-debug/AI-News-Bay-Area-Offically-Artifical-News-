# factcheck.ps1 - deterministic fact check. No AI is involved: every check is plain code.
# Requires lib.ps1 (Register-Facts must have filled $script:FactIndex).
#
# A problem is a hashtable: @{ level = 'FAIL' | 'WARN'; code = '...'; message = '...' }
# FAIL means the segment must be regenerated; WARN is reported for the human reviewer.

function ConvertTo-NormNum([string]$s) {
    $s = $s.TrimEnd(',').Replace(',', '')
    if ($s -match '^\d+\.\d+$') { $s = $s.TrimEnd('0').TrimEnd('.') }
    $s
}

$script:WordNums = @{ two = '2'; three = '3'; four = '4'; five = '5'; six = '6'; seven = '7'; eight = '8'; nine = '9'; ten = '10'
    eleven = '11'; twelve = '12'; thirteen = '13'; fourteen = '14'; fifteen = '15'; sixteen = '16'; seventeen = '17'; eighteen = '18'; nineteen = '19'
    twenty = '20'; thirty = '30'; forty = '40'; fifty = '50'; sixty = '60'; seventy = '70'; eighty = '80'; ninety = '90' }

# Digit tokens, plus spelled-out numbers (two to ninety) converted to digits, so "two months" is checked like "2 months".
# ("one" is skipped: it is mostly a pronoun.)
function Get-NumberTokens([string]$Text) {
    $out = @()
    if (-not $Text) { return $out }
    foreach ($m in [regex]::Matches($Text, '(?<![\w.])\d[\d,]*(?:\.\d+)?')) { $out += (ConvertTo-NormNum $m.Value) }
    foreach ($m in [regex]::Matches($Text, '(?i)\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b')) {
        $out += $script:WordNums[$m.Value.ToLower()]
    }
    $out
}

function Get-FactNumberSet($Fact) {
    $set = @{}
    foreach ($t in (Get-NumberTokens ([string]$Fact.display))) { $set[$t] = $true }
    foreach ($t in (Get-NumberTokens ([string]$Fact.value))) { $set[$t] = $true }
    $set
}

$script:BannedIntent = '(?i)\b(dirty|cheap shot|thugs?|goons?|intentional(ly)?|on purpose|malicious(ly)?|deliberate(ly)?|trying to hurt|out to hurt)\b'
$script:BannedMocking = '(?i)\b(deaf|dumb|retard(ed)?|cripple[sd]?|midget|spaz|lunatic|psycho|blind as)\b'
$script:SpelledBig = '(?i)\b(eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|trillion)\b'


# True when the name is an anchor/show name from the allowlist, or when every word appears in the cited facts.
function Test-NameKnown([string]$Name, [string]$FactText, $Allow) {
    $rest = $Name
    foreach ($a in @($Allow | Sort-Object { $_.Length } -Descending)) {
        $rest = [regex]::Replace($rest, "(?i)(?<![A-Za-z])$([regex]::Escape($a))(?![A-Za-z])", ' ')
    }
    $words = @(($rest -replace "[’']s\b", '') -split '\s+' | Where-Object { $_ })
    if ($words.Count -lt 2) { return $true }          # nothing left, or a single leftover word: cannot judge
    foreach ($w in $words) { if (-not $FactText.Contains($w.ToLower())) { return $false } }
    $true
}

function Test-Line {
    param($Line, [string[]]$AllowedIds, [string]$SegmentId, [hashtable]$DateNumbers, [string[]]$NameAllowlist)
    $problems = @()
    $text = [string]$Line.text
    if (-not $text.Trim()) { return @(@{ level = 'FAIL'; code = 'empty'; message = 'A line has no text.' }) }

    $refs = @($Line.fact_refs | Where-Object { $_ })
    $factsCited = @()
    foreach ($id in $refs) {
        if (-not $script:FactIndex.ContainsKey($id)) { $problems += @{ level = 'FAIL'; code = 'unknown_fact'; message = "Cites a fact id that does not exist: $id" }; continue }
        if ($AllowedIds -notcontains $id) { $problems += @{ level = 'FAIL'; code = 'fact_not_provided'; message = "Cites fact $id, which was not provided for this segment." }; continue }
        $factsCited += $script:FactIndex[$id]
    }

    # Numbers: every digit token must appear in a cited fact (or be today's date).
    $allowed = @{}
    foreach ($f in $factsCited) { foreach ($k in (Get-FactNumberSet $f).Keys) { $allowed[$k] = $true } }
    foreach ($tok in (Get-NumberTokens $text)) {
        if (-not $allowed.ContainsKey($tok) -and -not $DateNumbers.ContainsKey($tok)) {
            $problems += @{ level = 'FAIL'; code = 'number_not_in_facts'; message = "The number $tok is not in any fact cited by this line: `"$text`"" }
        }
    }
    $factsLower = (($factsCited | ForEach-Object { "$($_.display) $($_.value)" }) -join ' ').ToLower()
    foreach ($bm in [regex]::Matches($text, $script:SpelledBig)) {
        if (-not $factsLower.Contains($bm.Value.ToLower())) {
            $problems += @{ level = 'WARN'; code = 'spelled_number'; message = "A spelled-out number cannot be machine checked; use digits: `"$text`"" }
            break
        }
    }

    # Mocking language about disability or people is never allowed in the anchors' chat.
    if ($SegmentId -like 'react_*' -and $text -match $script:BannedMocking) {
        $problems += @{ level = 'FAIL'; code = 'demeaning'; message = "Do not joke about disability, illness or people's bodies ($($Matches[0])): `"$text`"" }
    }

    # Character / intent claims are never allowed.
    if ($text -match $script:BannedIntent) {
        $problems += @{ level = 'FAIL'; code = 'intent_claim'; message = "Wording that claims intent or character is not allowed ($($Matches[0])): `"$text`"" }
    }

    # Names: capitalized multi-word names should appear in a cited fact (warning only).
    # Checked one sentence at a time, so a name never runs across a full stop. Words must be Capitalized
    # (not ALL CAPS acronyms). The first word of a sentence is forgiven: "Your Warriors" is not a name.
    $factText = (($factsCited | ForEach-Object { "$($_.display) $($_.value) $($_.subject)" }) -join ' ').ToLower()
    foreach ($sentence in @([regex]::Split($text, '(?<=[.!?:;])\s+'))) {
        foreach ($m in [regex]::Matches($sentence, "(?<![A-Za-z])[A-Z][a-z][A-Za-z'-]*(?:\s+[A-Z][a-z][A-Za-z'-]*)+")) {
            $nm = $m.Value
            $ok = Test-NameKnown $nm $factText $NameAllowlist
            if (-not $ok -and $m.Index -eq 0) { $ok = Test-NameKnown ($nm -replace '^\S+\s+', '') $factText $NameAllowlist }
            if (-not $ok) { $problems += @{ level = 'WARN'; code = 'name_not_in_facts'; message = "The name `"$nm`" is not in the cited facts." } }
        }
    }

    # Lines with no facts may not carry numbers (already enforced above) and need no further checks.
    $problems
}

function Test-Segment {
    param($Segment, $Config)
    $problems = @()
    $d = [datetime]::ParseExact($Segment.episode_date, 'yyyy-MM-dd', $script:Inv)
    $dateNums = @{}
    foreach ($t in @($d.Year.ToString(), $d.Month.ToString(), $d.Day.ToString())) { $dateNums[$t] = $true }

    $words = 0
    foreach ($line in @($Segment.lines)) {
        $words += Get-WordCount $line.text
        $problems += @(Test-Line -Line $line -AllowedIds @($Segment.allowed_fact_ids) -SegmentId $Segment.id -DateNumbers $dateNums -NameAllowlist @($Config.name_allowlist))
    }

    if ($words -gt [math]::Ceiling($Segment.word_budget * 1.5)) {
        $problems += @{ level = 'FAIL'; code = 'over_budget'; message = "Segment has $words words; the budget is $($Segment.word_budget) (limit $([math]::Ceiling($Segment.word_budget * 1.5)))." }
    } elseif ($Segment.word_budget -ge 100 -and $words -lt [math]::Floor($Segment.word_budget * 0.55)) {
        $problems += @{ level = 'WARN'; code = 'under_length'; message = "Segment has only $words words; the budget is $($Segment.word_budget)." }
    } elseif ($words -gt [math]::Ceiling($Segment.word_budget * 1.25)) {
        $problems += @{ level = 'WARN'; code = 'near_budget'; message = "Segment has $words words; the budget is $($Segment.word_budget)." }
    }

    # Who powers each anchor: the cold open must say it, and any segment that touches the anchor's own maker must disclose it.
    $engines = $Config.anchor_engines
    if ($engines) {
        if ($Segment.id -like 'cold_open_*' -and $engines.PSObject.Properties.Name -contains [string]$Segment.anchor) {
            $mk = [string]$engines.($Segment.anchor).maker_regex
            if (-not (@($Segment.lines) | Where-Object { $_.text -match $mk })) {
                $problems += @{ level = 'FAIL'; code = 'identity_missing'; message = "In the cold open, $($engines.($Segment.anchor).name) must say which AI model powers them ($($engines.($Segment.anchor).label))." }
            }
        }
        $spk = @(@($Segment.lines) | ForEach-Object { if ($_.speaker) { $_.speaker } else { $Segment.anchor } } | Select-Object -Unique)
        foreach ($sp in $spk) {
            if ($engines.PSObject.Properties.Name -notcontains [string]$sp) { continue }
            $mk = [string]$engines.$sp.maker_regex
            $mine = @(@($Segment.lines) | Where-Object { $_.speaker -eq $sp -or (-not $_.speaker -and $Segment.anchor -eq $sp) })
            $touches = $false
            foreach ($l in $mine) {
                if ($l.text -match $mk) { $touches = $true }
                foreach ($id in @($l.fact_refs)) { if ($id -and $script:FactIndex.ContainsKey($id) -and $script:FactIndex[$id].kind -ne 'anchor_identity' -and ("$($script:FactIndex[$id].display) $($script:FactIndex[$id].value)" -match $mk)) { $touches = $true } }
            }
            $factsTouch = $false
            foreach ($l in $mine) { foreach ($id in @($l.fact_refs)) { if ($id -and $script:FactIndex.ContainsKey($id) -and $script:FactIndex[$id].kind -ne 'anchor_identity' -and ("$($script:FactIndex[$id].display) $($script:FactIndex[$id].value)" -match $mk)) { $factsTouch = $true } } }
            if (-not $factsTouch -and $Segment.id -notlike 'cold_open_*' -and ($mine | Where-Object { $_.text -match $mk })) {
                $problems += @{ level = 'FAIL'; code = 'engine_repeat'; message = "$($engines.$sp.name) mentioned their own engine ($($engines.$sp.label)) where nothing is about their maker. Say it only in the cold open and when the story is about your maker; remove it here." }
            }
            if ($touches -and -not ($mine | Where-Object { $_.text -match [string]$Config.disclosure_regex })) {
                $problems += @{ level = 'FAIL'; code = 'disclosure_missing'; message = "$($engines.$sp.name) is covering something about their own maker ($($engines.$sp.label)) and must say a short disclosure line, for example: ""Full disclosure, I run on $($engines.$sp.label)""." }
            }
        }
    }

    # Calling Out the Hype: every claim must be labeled, said aloud, and sourced.
    if ($Segment.id -eq 'hype') {
        $labeled = 0
        foreach ($line in @($Segment.lines)) {
            $refs = @($line.fact_refs | Where-Object { $_ })
            $hasNum = (@(Get-NumberTokens ([string]$line.text)).Count -gt 0)
            $ct = [string]$line.claim_type
            if (($refs.Count -gt 0 -or $hasNum) -and $ct -ne 'independent' -and $ct -ne 'unverified_claim') {
                $problems += @{ level = 'FAIL'; code = 'hype_unlabeled'; message = "A claim line must set claim_type to independent or unverified_claim: `"$($line.text)`"" }
                continue
            }
            if ($ct -eq 'independent' -or $ct -eq 'unverified_claim') { $labeled++ }
            $kinds = @($refs | ForEach-Object { if ($script:FactIndex.ContainsKey($_)) { $script:FactIndex[$_].kind } })
            if ($ct -eq 'independent') {
                if ($kinds.Count -eq 0 -or ($kinds | Where-Object { $_ -ne 'independent_benchmark' })) {
                    $problems += @{ level = 'FAIL'; code = 'hype_false_independent'; message = "A line is labeled independent but cites a fact that is not an independent benchmark: `"$($line.text)`"" }
                }
                if ($line.text -notmatch '(?i)independent') {
                    $problems += @{ level = 'FAIL'; code = 'hype_not_said'; message = "The line must say the word independent out loud: `"$($line.text)`"" }
                }
            }
            if ($ct -eq 'unverified_claim') {
                if ($kinds | Where-Object { $_ -eq 'independent_benchmark' }) {
                    $problems += @{ level = 'FAIL'; code = 'hype_mislabeled'; message = "An independent benchmark fact is labeled as an unverified claim: `"$($line.text)`"" }
                }
                if ($line.text -notmatch '(?i)(unverified|not independent|independently|claims?|claimed|according to|reported)') {
                    $problems += @{ level = 'FAIL'; code = 'hype_not_said'; message = "The line must say out loud that this is an unverified or reported claim: `"$($line.text)`"" }
                }
            }
        }
        if ($labeled -eq 0 -and @($Segment.allowed_fact_ids).Count -gt 0) { $problems += @{ level = 'WARN'; code = 'hype_empty'; message = 'No line in the Hype segment carries a labeled claim.' } }
    }
    $problems
}
