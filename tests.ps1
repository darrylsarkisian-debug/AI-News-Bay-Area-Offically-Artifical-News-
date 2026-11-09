<#
.SYNOPSIS
  Offline tests for the fact checker and helpers. No network, no API keys.
  Run:  .\tests.ps1
#>
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'factcheck.ps1')
Import-Config

$script:pass = 0; $script:fail = 0
function Assert([bool]$Cond, [string]$Name) {
    if ($Cond) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $Name" -ForegroundColor Red }
}
function Has-Code($Problems, [string]$Code, [string]$Level = 'FAIL') { @($Problems | Where-Object { $_.code -eq $Code -and $_.level -eq $Level }).Count -gt 0 }

# ---- fixture facts (synthetic)
$facts = @(
    (New-Fact -Id 'g.leader.PTS' -Kind 'player_leader' -Subject 'GS' -Value 31 -Display 'Player Alpha: 31 points' -Source 'ESPN'),
    (New-Fact -Id 'g.ft' -Kind 'player_leader' -Subject 'GS' -Value 100.0 -Display 'Player Alpha: 5 of 5 free throws (100.0%)' -Source 'ESPN'),
    (New-Fact -Id 'aa.1' -Kind 'independent_benchmark' -Subject 'Model One' -Value 71.2 -Display 'Artificial Analysis Intelligence Index, an independent benchmark: Model One scores 71.2' -Source 'Artificial Analysis'),
    (New-Fact -Id 'claim.1' -Kind 'unverified_claim' -Subject 'x.example' -Value 'headline' -Display 'Acme model beats rivals by 20 percent (x.example)' -Source 'GDELT')
)
Register-Facts $facts
$dn = @{ '2026' = $true; '11' = $true; '10' = $true }
$names = @($script:Config.name_allowlist)
function Line($text, $refs, $ct = 'none') { [pscustomobject]@{ text = $text; fact_refs = $refs; claim_type = $ct } }
function Check($text, $refs, $allowed, $seg = 'warriors', $ct = 'none') { Test-Line -Line (Line $text $refs $ct) -AllowedIds $allowed -SegmentId $seg -DateNumbers $dn -NameAllowlist $names }

# ---- numbers
Assert ((Get-NumberTokens 'He scored 1,031 and 83.30 and 100.0 points') -join ',' -eq '1031,83.3,100') 'number token normalization'
$p = Check 'Player Alpha dropped 31 points tonight.' @('g.leader.PTS') @('g.leader.PTS', 'g.ft')
Assert (-not (Has-Code $p 'number_not_in_facts')) 'number from cited fact passes'
$p = Check 'Player Alpha dropped 35 points tonight.' @('g.leader.PTS') @('g.leader.PTS', 'g.ft')
Assert (Has-Code $p 'number_not_in_facts') 'invented number fails'
$p = Check 'Player Alpha was perfect, 5 of 5, a flat 100 percent.' @('g.ft') @('g.ft')
Assert (-not (Has-Code $p 'number_not_in_facts')) '100.0 in fact matches 100 in text'
$p = Check 'That is 31 points, folks.' @() @('g.leader.PTS')
Assert (Has-Code $p 'number_not_in_facts') 'number with no cited fact fails'
$p = Check 'Good evening on November 10, 2026.' @() @()
Assert (-not (Has-Code $p 'number_not_in_facts')) 'date numbers allowed'

# ---- fact references
$p = Check 'Player Alpha dropped 31 points.' @('nope') @('g.leader.PTS')
Assert (Has-Code $p 'unknown_fact') 'unknown fact id fails'
$p = Check 'Player Alpha dropped 31 points.' @('g.leader.PTS') @('g.ft')
Assert (Has-Code $p 'fact_not_provided') 'fact id not given to the segment fails'
$p = Check '' @() @()
Assert (Has-Code $p 'empty') 'empty line fails'

# ---- intent / character claims
$p = Check 'That was a dirty play by a thug.' @() @()
Assert (Has-Code $p 'intent_claim') 'character claim fails'
$p = Check 'He did it on purpose.' @() @()
Assert (Has-Code $p 'intent_claim') 'intent claim fails'
$p = Check 'Great night for the whole team.' @() @()
Assert (-not (Has-Code $p 'intent_claim')) 'clean line passes intent check'

# ---- spelled numbers and names (warnings)
$p = Check 'Player Alpha had twenty points.' @('g.leader.PTS') @('g.leader.PTS')
Assert (Has-Code $p 'spelled_number' 'WARN') 'spelled number warns'
$p = Check 'Then Kevin Garnett walked in.' @() @()
Assert (Has-Code $p 'name_not_in_facts' 'WARN') 'unknown name warns'
$p = Check 'Player Alpha led the way.' @('g.leader.PTS') @('g.leader.PTS')
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'name in cited fact passes'
$p = Check 'Big Russ here with Justice Jenny.' @() @()
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'anchor names allowed'

# ---- segment: word budget and hype rules
function Seg($id, $budget, $lines, $allowed) { [ordered]@{ id = $id; anchor = 'x'; episode_date = '2026-11-10'; word_budget = $budget; allowed_fact_ids = $allowed; lines = $lines } }
$ok = Test-Segment -Segment (Seg 'weather' 5 @((Line 'one two three four five six seven eight nine ten eleven twelve' @() )) @()) -Config $script:Config
Assert (Has-Code $ok 'over_budget') 'way over budget fails'

$h = Test-Segment -Segment (Seg 'hype' 200 @((Line 'Model One scores 71.2 on an independent benchmark from Artificial Analysis.' @('aa.1') 'independent')) @('aa.1')) -Config $script:Config
Assert (@($h | Where-Object { $_.level -eq 'FAIL' }).Count -eq 0) 'good independent hype line passes'
$h = Test-Segment -Segment (Seg 'hype' 200 @((Line 'Model One scores 71.2 on a benchmark.' @('aa.1') 'none')) @('aa.1')) -Config $script:Config
Assert (Has-Code $h 'hype_unlabeled') 'hype claim without a label fails'
$h = Test-Segment -Segment (Seg 'hype' 200 @((Line 'Model One scores 71.2, says Artificial Analysis.' @('aa.1') 'independent')) @('aa.1')) -Config $script:Config
Assert (Has-Code $h 'hype_not_said') 'independent label not said aloud fails'
$h = Test-Segment -Segment (Seg 'hype' 200 @((Line 'Acme beats rivals by 20 percent, an independent result.' @('claim.1') 'independent')) @('claim.1')) -Config $script:Config
Assert (Has-Code $h 'hype_false_independent') 'headline claim labeled independent fails'
$h = Test-Segment -Segment (Seg 'hype' 200 @((Line 'Acme claims it beats rivals by 20 percent. Unverified.' @('claim.1') 'unverified_claim')) @('claim.1')) -Config $script:Config
Assert (@($h | Where-Object { $_.level -eq 'FAIL' }).Count -eq 0) 'good unverified claim line passes'
$h = Test-Segment -Segment (Seg 'hype' 200 @((Line 'Model One scores 71.2, a claim.' @('aa.1') 'unverified_claim')) @('aa.1')) -Config $script:Config
Assert (Has-Code $h 'hype_mislabeled') 'independent fact labeled unverified fails'


# ---- names: no false alarms across sentence ends, acronyms, anchor names
$p = Check "That's all about AI. Let's go." @() @()
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'name does not run across a full stop'
$p = Check 'Pat is thrilled. Big Russ is not.' @() @()
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'Pat and Big Russ are allowed'
$p = Check 'Winds are light, 71 degrees Fahrenheit. Tonight is clear. The PM PST label is fine.' @() @()
Assert (-not (Has-Code $p 'number_not_in_facts' 'WARN') -and -not (Has-Code $p 'name_not_in_facts' 'WARN')) 'acronyms are not names'
$p = Check 'Your Warriors were loud.' @() @()
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'sentence-start word is forgiven'
$p = Check 'Player Alpha was great.' @('g.leader.PTS') @('g.leader.PTS')
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'sentence-start real name still passes'
$p = Check 'We saw Kevin Garnett tonight.' @() @()
Assert (Has-Code $p 'name_not_in_facts' 'WARN') 'unknown mid-sentence name still warns'


# ---- possessives, show title, demeaning words
$p = Check "Welcome to SF Bay Area's Officially Artificial News." @() @()
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'show title with possessive is allowed'
$p = Check "Add Player Alpha's work to that." @('g.leader.PTS') @('g.leader.PTS')
Assert (-not (Has-Code $p 'name_not_in_facts' 'WARN')) 'possessive of a known name passes'
$p = Check 'Save that volume for somebody who is deaf.' @() @() 'react_sports'
Assert (Has-Code $p 'demeaning') 'disability joke fails in chat segments'
$p = Check 'A school for the deaf opened.' @() @() 'world'
Assert (-not (Has-Code $p 'demeaning')) 'news lines are not affected by the chat word filter'


# ---- engines: identity in cold open, disclosure when the story is about the anchor's maker
Register-Facts @(
    (New-Fact -Id 'hn.claude' -Kind 'tech_signal' -Subject 'Hacker News' -Value 'Claude gets an update' -Display 'Hacker News front page: Claude gets an update (289 points)' -Source 'Hacker News'),
    (New-Fact -Id 'hn.other' -Kind 'tech_signal' -Subject 'Hacker News' -Value 'A GPU primer' -Display 'Hacker News front page: A GPU primer (11 points)' -Source 'Hacker News'),
    (New-Fact -Id 'anchor.russ' -Kind 'anchor_identity' -Subject 'Big Russ' -Value 'Claude, made by Anthropic' -Display 'Big Russ is powered by Claude, made by Anthropic.' -Source 'Show setup')
)
function RLine($text, $refs, $spk = 'russ') { [ordered]@{ speaker = $spk; text = $text; fact_refs = $refs; claim_type = 'none' } }
function RSeg($id, $anchor, $lines, $allowed) { [ordered]@{ id = $id; anchor = $anchor; episode_date = '2026-11-10'; word_budget = 99; allowed_fact_ids = $allowed; lines = $lines } }
$e = Test-Segment -Segment (RSeg 'cold_open_russ' 'russ' @((RLine "I'm Big Russ. Tech is next." @('hn.other'))) @('hn.other', 'anchor.russ')) -Config $script:Config
Assert (Has-Code $e 'identity_missing') 'cold open without the engine fails'
$e = Test-Segment -Segment (RSeg 'cold_open_russ' 'russ' @((RLine "I'm Big Russ, powered by Claude, made by Anthropic. Tech is next." @('anchor.russ', 'hn.other'))) @('hn.other', 'anchor.russ')) -Config $script:Config
Assert (-not (Has-Code $e 'identity_missing') -and -not (Has-Code $e 'disclosure_missing')) 'cold open with the engine passes'
$e = Test-Segment -Segment (RSeg 'tech' 'russ' @((RLine 'A post says Claude gets an update. It has 289 points.' @('hn.claude'))) @('hn.claude')) -Config $script:Config
Assert (Has-Code $e 'disclosure_missing') 'story about own maker without disclosure fails'
$e = Test-Segment -Segment (RSeg 'tech' 'russ' @((RLine 'Full disclosure, I run on Claude. A post says Claude gets an update. It has 289 points.' @('hn.claude'))) @('hn.claude')) -Config $script:Config
Assert (-not (Has-Code $e 'disclosure_missing')) 'story about own maker with disclosure passes'
$e = Test-Segment -Segment (RSeg 'tech' 'russ' @((RLine 'A GPU primer trended. It has 11 points.' @('hn.other'))) @('hn.other')) -Config $script:Config
Assert (-not (Has-Code $e 'disclosure_missing')) 'unrelated story needs no disclosure'
$e = Test-Segment -Segment (RSeg 'react_news' 'russ+pat' @((RLine 'Claude got an update and I will wait for the receipts.' @('hn.claude') 'pat')) @('hn.claude')) -Config $script:Config
Assert (-not (Has-Code $e 'disclosure_missing')) 'Pat talking about Claude owes no disclosure'


# ---- spelled numbers are checked like digits
Register-Facts @((New-Fact -Id 'bs.1' -Kind 'news_candidate' -Subject 'x' -Value 'China extends suspension of 24 % tariff on US imports for two months (business-standard.com)' -Display 'China extends suspension of 24 % tariff on US imports for two months (business-standard.com)' -Source 'GDELT'))
$p = Check 'China paused the tariff for two months.' @('bs.1') @('bs.1')
Assert (-not (Has-Code $p 'number_not_in_facts')) 'spelled number found in the cited fact passes'
$p = Check 'China paused the tariff for six months.' @('bs.1') @('bs.1')
Assert (Has-Code $p 'number_not_in_facts') 'spelled number not in the fact fails'
$p = Check 'Four guys had steals.' @('g.leader.PTS') @('g.leader.PTS')
Assert (Has-Code $p 'number_not_in_facts') 'spelled count not in facts fails'
$p = Check 'The valuation hit a trillion.' @() @()
Assert (Has-Code $p 'spelled_number' 'WARN') 'trillion warns'


# ---- engine only where it belongs; big-number warning only when the fact does not already say it
$e = Test-Segment -Segment (RSeg 'tech' 'russ' @((RLine "I'm Big Russ, an AI running on Claude. A GPU primer trended." @('hn.other'))) @('hn.other')) -Config $script:Config
Assert (Has-Code $e 'engine_repeat') 'engine mention outside the cold open and without a maker story fails'
$e = Test-Segment -Segment (RSeg 'tech' 'russ' @((RLine 'Full disclosure, I run on Claude. A post says Claude gets an update.' @('hn.claude'))) @('hn.claude')) -Config $script:Config
Assert (-not (Has-Code $e 'engine_repeat')) 'engine mention is fine when the story is about the maker'
Register-Facts @((New-Fact -Id 'pym.1' -Kind 'ai_news_candidate' -Subject 'x' -Value 'OpenAI Valuation Hits $1.25 Trillion' -Display 'OpenAI Valuation Hits $1.25 Trillion (pymnts.com)' -Source 'GDELT'))
$p = Check 'Valuation hits 1.25 trillion dollars.' @('pym.1') @('pym.1')
Assert (-not (Has-Code $p 'spelled_number' 'WARN')) 'trillion in the cited fact does not warn'

# ---- length
$u = Test-Segment -Segment (Seg 'tech' 340 @((Line 'one two three four five six seven eight nine ten' @() )) @()) -Config $script:Config
Assert (Has-Code $u 'under_length' 'WARN') 'very short long-budget segment warns'
$u = Test-Segment -Segment (Seg 'cold_open_x' 33 @((Line 'one two three four five six seven eight nine ten' @() )) @()) -Config $script:Config
Assert (-not (Has-Code $u 'under_length' 'WARN')) 'short budgets never warn under_length'

# ---- helpers
Assert ((ConvertFrom-LlmJson "Sure!`n``````json`n{`"lines`":[{`"text`":`"hi`"}]}`n```````n").lines[0].text -eq 'hi') 'JSON extracted from a code fence'
Assert ((Get-WordCount "  one  two`nthree ") -eq 3) 'word count'
Assert ((Get-Sha8 'abc').Length -eq 8) 'sha8 length'
$thrown = $false; try { Register-Facts @($facts[0]) } catch { $thrown = $true }
Assert $thrown 'duplicate fact id is rejected'

Write-Host ("{0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
