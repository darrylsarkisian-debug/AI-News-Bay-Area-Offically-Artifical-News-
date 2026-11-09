# lib.ps1 - shared helpers for the prototype. Dot-source it: . .\lib.ps1
# Works on Windows PowerShell 5.1 and PowerShell 7. API keys come from environment
# variables only (see config.json "key_env"); nothing secret is ever written to disk.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$script:Root = $PSScriptRoot
$script:Inv  = [Globalization.CultureInfo]::InvariantCulture
$script:UseMock = $false
$script:Config = $null
$script:FactIndex = @{}

function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Json($Obj, [string]$Path, [int]$Depth = 20) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Obj -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Add-JsonLine($Obj, [string]$Path) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = ConvertTo-Json -InputObject $Obj -Depth 10 -Compress
    [IO.File]::AppendAllText($Path, $line + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Import-Config {
    $script:Config = Read-Json (Join-Path $script:Root 'config.json')
}

function Format-Num($x, [string]$Fmt = '0.#') { ([double]$x).ToString($Fmt, $script:Inv) }

function Get-WordCount([string]$Text) {
    if (-not $Text) { return 0 }
    @($Text -split '\s+' | Where-Object { $_ }).Count
}

function Get-Sha8([string]$Text) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    (($b | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
}

# ---------------------------------------------------------------- facts
function New-Fact {
    param([string]$Id, [string]$Kind, [string]$Subject, $Value, [string]$Display,
          [string]$Source, [string]$Url, [string]$Credit, [hashtable]$Extra = @{})
    $c = $Credit; if (-not $c) { $c = $Source }
    $o = [ordered]@{
        id = $Id; kind = $Kind; subject = $Subject; value = $Value; display = $Display
        source = $Source; credit = $c; url = $Url
        retrieved_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    [pscustomobject]$o
}

function Register-Facts($Facts) {
    foreach ($f in @($Facts)) {
        if ($script:FactIndex.ContainsKey($f.id)) { throw "Duplicate fact id: $($f.id)" }
        $script:FactIndex[$f.id] = $f
    }
}

# ---------------------------------------------------------------- HTTP
function Get-ErrorBody($ErrRecord) {
    try {
        if ($ErrRecord.ErrorDetails -and $ErrRecord.ErrorDetails.Message) { return $ErrRecord.ErrorDetails.Message }
        $resp = $ErrRecord.Exception.Response
        if ($resp -and ($resp | Get-Member -Name GetResponseStream -ErrorAction SilentlyContinue)) {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            return $sr.ReadToEnd()
        }
    } catch { }
    return ''
}

# Returns the response body as a UTF-8 string. Retries transient errors (429, 5xx, network).
function Invoke-Web {
    param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'GET', [hashtable]$Headers = @{},
          [string]$Body, [int]$Retries = 2, [int]$TimeoutSec = 90)
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            $p = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = $TimeoutSec; UseBasicParsing = $true }
            if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body); $p.ContentType = 'application/json; charset=utf-8' }
            $r = Invoke-WebRequest @p
            return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            $status = $null
            try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
            $transient = (-not $status) -or ($status -eq 429) -or ($status -ge 500)
            if ($i -lt $Retries -and $transient) { Start-Sleep -Seconds (3 * ($i + 1)); continue }
            $detail = Get-ErrorBody $_
            if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
            throw "HTTP failure for $Uri (status $status): $($_.Exception.Message) $detail"
        }
    }
}

# ---------------------------------------------------------------- LLM
function Get-ApiKey([string]$Provider) {
    $name = $script:Config.key_env.$Provider
    $v = [Environment]::GetEnvironmentVariable($name)
    if (-not $v) { throw "Missing environment variable $name (needed for provider '$Provider'). Set it in this PowerShell window, e.g.  `$env:$name = '...'" }
    $v
}

function ConvertFrom-LlmJson([string]$Text) {
    $t = $Text.Trim()
    if ($t -match '(?s)```(?:json)?\s*(.*?)```') { $t = $Matches[1].Trim() }
    $s = $t.IndexOf('{'); $e = $t.LastIndexOf('}')
    if ($s -lt 0 -or $e -le $s) { throw 'No JSON object found in model output.' }
    ConvertFrom-Json $t.Substring($s, $e - $s + 1)
}

# Returns the model's text. $Role is a key under config.models (russ, jenny, pat, editor).
function Invoke-Llm {
    param([Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$System,
          [Parameter(Mandatory)][string]$User, [int]$MaxTokens = 4000)
    $m = $script:Config.models.$Role
    if (-not $m) { throw "No model configured for role '$Role'" }
    $key = Get-ApiKey $m.provider
    switch ($m.provider) {
        'anthropic' {
            $body = ConvertTo-Json -Depth 10 -Compress -InputObject @{
                model = $m.model; max_tokens = $MaxTokens; system = $System
                messages = @(@{ role = 'user'; content = $User })
            }
            $h = @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01' }
            $r = ConvertFrom-Json (Invoke-Web -Uri 'https://api.anthropic.com/v1/messages' -Method POST -Headers $h -Body $body)
            return (@($r.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n")
        }
        'openai' {
            $body = ConvertTo-Json -Depth 10 -Compress -InputObject @{
                model = $m.model; instructions = $System; input = $User; max_output_tokens = $MaxTokens
                text = @{ format = @{ type = 'json_object' } }
            }
            $h = @{ 'Authorization' = "Bearer $key" }
            $r = ConvertFrom-Json (Invoke-Web -Uri 'https://api.openai.com/v1/responses' -Method POST -Headers $h -Body $body)
            if ($r.PSObject.Properties.Name -contains 'output_text' -and $r.output_text) { return [string]$r.output_text }
            $parts = @()
            foreach ($item in @($r.output)) {
                if ($item.type -eq 'message') {
                    foreach ($c in @($item.content)) { if ($c.type -eq 'output_text') { $parts += $c.text } }
                }
            }
            if ($parts.Count -eq 0) { throw 'OpenAI response contained no output text.' }
            return ($parts -join "`n")
        }
        'gemini' {
            $body = ConvertTo-Json -Depth 10 -Compress -InputObject @{
                systemInstruction = @{ parts = @(@{ text = $System }) }
                contents = @(@{ role = 'user'; parts = @(@{ text = $User }) })
                generationConfig = @{ responseMimeType = 'application/json'; maxOutputTokens = $MaxTokens }
            }
            $h = @{ 'x-goog-api-key' = $key }
            $uri = "https://generativelanguage.googleapis.com/v1beta/models/$($m.model):generateContent"
            $r = ConvertFrom-Json (Invoke-Web -Uri $uri -Method POST -Headers $h -Body $body)
            $parts = @()
            foreach ($p in @($r.candidates[0].content.parts)) {
                if ($p.PSObject.Properties.Name -contains 'text' -and -not ($p.PSObject.Properties.Name -contains 'thought' -and $p.thought)) { $parts += $p.text }
            }
            if ($parts.Count -eq 0) { throw 'Gemini response contained no text.' }
            return ($parts -join "`n")
        }
        default { throw "Unknown provider '$($m.provider)' for role '$Role'" }
    }
}

# Calls the model, parses JSON, runs $Validate (returns an array of problem strings, empty = ok).
# On problems it asks the model once or twice to fix them.
function Invoke-LlmJson {
    param([string]$Role, [string]$System, [string]$User, [scriptblock]$Validate, [int]$Attempts = 3)
    $prompt = $User; $lastProblems = @()
    for ($a = 1; $a -le $Attempts; $a++) {
        try {
            $obj = ConvertFrom-LlmJson (Invoke-Llm -Role $Role -System $System -User $prompt)
            $problems = @(& $Validate $obj)
            if ($problems.Count -eq 0) { return $obj }
            $lastProblems = $problems
        } catch {
            if ($_.Exception.Message -like 'HTTP failure*' -or $_.Exception.Message -like 'Missing environment*') { throw }
            $lastProblems = @("Output was not valid JSON for the requested shape: $($_.Exception.Message)")
        }
        $prompt = $User + "`n`nYOUR PREVIOUS ANSWER HAD THESE PROBLEMS. Fix them and return only the corrected JSON object:`n- " + ($lastProblems -join "`n- ")
    }
    throw "Model '$Role' did not return a valid answer after $Attempts attempts: $($lastProblems -join '; ')"
}
