<#
.SYNOPSIS
  Checks your API keys and the free data sources one at a time, before a full run.

.EXAMPLE
  .\smoke_test.ps1 -Models      # one tiny call to each AI provider (costs a fraction of a cent)
  .\smoke_test.ps1 -Data        # one small call to each free data source
  .\smoke_test.ps1 -Models -Data
#>
param([switch]$Models, [switch]$Data)
. (Join-Path $PSScriptRoot 'lib.ps1')
. (Join-Path $PSScriptRoot 'data_pulls.ps1')
Import-Config
if (-not $Models -and -not $Data) { Write-Host 'Use -Models and/or -Data. See the header of this file.'; exit 0 }

if ($Models) {
    foreach ($role in @('russ', 'jenny', 'pat', 'editor')) {
        $m = $script:Config.models.$role
        try {
            $t = Invoke-Llm -Role $role -System 'Reply with only this JSON: {"ok": true}' -User 'Return the JSON now.' -MaxTokens 200
            Write-Host ("OK    {0,-7} {1} / {2}: {3}" -f $role, $m.provider, $m.model, ($t.Trim() -replace '\s+', ' ')) -ForegroundColor Green
        } catch { Write-Host ("FAIL  {0,-7} {1} / {2}: {3}" -f $role, $m.provider, $m.model, $_.Exception.Message) -ForegroundColor Red }
    }
}
if ($Data) {
    $raw = Join-Path $env:TEMP 'oan_smoke'
    $tests = @(
        @{ n = 'Warriors (ESPN adapter)'; f = { Get-WarriorsFacts $raw } },
        @{ n = 'Bay Area weather (NWS)';   f = { Get-BayAreaWeatherFacts } },
        @{ n = 'World weather (GDACS)';    f = { Get-WorldwideWeatherFacts } },
        @{ n = 'Hacker News + GDELT AI';   f = { Get-TechFacts } },
        @{ n = 'Artificial Analysis';      f = { Get-BenchmarkFacts $raw } }
    )
    foreach ($t in $tests) {
        $script:PullNotes.Clear()
        $r = @(& $t.f)
        $c = 'Green'; if ($r.Count -eq 0) { $c = 'Red' }
        Write-Host ("{0,-26} {1} facts" -f $t.n, $r.Count) -ForegroundColor $c
        if ($r.Count -gt 0) { Write-Host ("    e.g. " + $r[0].display) }
    }
    Write-Host 'GDELT world headlines are checked by a full run (they wait 6 seconds between 5 queries).'
}
