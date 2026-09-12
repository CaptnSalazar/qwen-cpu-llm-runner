[CmdletBinding()]
param(
    [string]$BaseUrl = "http://127.0.0.1:8080",
    [string]$Model = "local-model",
    [ValidateRange(1, 10)]
    [int]$MaxTokens = 8,
    [switch]$SkipWarmup,
    [string]$OutputDirectory = "",
    [switch]$NoReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
$BaseUrl = $BaseUrl.TrimEnd("/")
$ChatEndpoint = "$BaseUrl/v1/chat/completions"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $ProjectRoot "benchmarks" }
$startedAt = Get-Date

function Invoke-StreamingChat([string]$Prompt) {
    $payload = @{
        model       = $Model
        messages    = @(@{ role = "user"; content = $Prompt })
        temperature = 0
        top_p       = 1
        max_tokens  = $MaxTokens
        stream      = $true
    } | ConvertTo-Json -Depth 5 -Compress

    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $ChatEndpoint)
    $request.Content = New-Object System.Net.Http.StringContent($payload, [System.Text.Encoding]::UTF8, "application/json")
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $firstTokenMs = $null
    $answer = New-Object System.Text.StringBuilder
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $detail = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Server returned HTTP $([int]$response.StatusCode): $detail"
        }

        $reader = New-Object System.IO.StreamReader($response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
        try {
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not $line.StartsWith("data: ")) { continue }
                $data = $line.Substring(6)
                if ($data -eq "[DONE]") { break }
                try { $event = $data | ConvertFrom-Json } catch { continue }
                if ($event.choices.Count -eq 0) { continue }
                $delta = $event.choices[0].delta
                # Some models emit a reasoning field; this test measures first visible answer text.
                $contentProperty = $delta.PSObject.Properties["content"]
                $content = if ($null -ne $contentProperty -and $null -ne $contentProperty.Value) { [string]$contentProperty.Value } else { "" }
                if ($content.Length -gt 0) {
                    if ($null -eq $firstTokenMs) { $firstTokenMs = $watch.Elapsed.TotalMilliseconds }
                    [void]$answer.Append($content)
                }
            }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $watch.Stop()
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }

    [pscustomobject]@{
        Text         = $answer.ToString().Trim()
        FirstTokenMs = if ($null -eq $firstTokenMs) { $null } else { [math]::Round($firstTokenMs, 0) }
        TotalMs      = [math]::Round($watch.Elapsed.TotalMilliseconds, 0)
    }
}

try {
    $health = Invoke-WebRequest -Uri "$BaseUrl/health" -UseBasicParsing -TimeoutSec 5
    if ($health.StatusCode -ne 200) { throw "Health endpoint returned HTTP $($health.StatusCode)." }
} catch {
    throw "Cannot reach llama.cpp at $BaseUrl. Start it with '.\run.ps1 -Mode server'. Details: $($_.Exception.Message)"
}

if (-not $SkipWarmup) {
    Write-Host "[eval] Warming up model..." -ForegroundColor Cyan
    [void](Invoke-StreamingChat "Reply with exactly OK. /no_think")
}

$cases = @(
    [pscustomobject]@{
        Id = "arithmetic"; Expected = "\b19\b"
        Prompt = "A shop has 3 boxes with 8 pens each and gives away 5 pens. How many pens remain? Answer with only the number. /no_think"
    },
    [pscustomobject]@{
        Id = "geography"; Expected = "\bcanberra\b"
        Prompt = "What is the capital city of Australia? Answer with only the city name. /no_think"
    },
    [pscustomobject]@{
        Id = "pattern"; Expected = "\b17\b"
        Prompt = "Find the next number: 2, 3, 5, 8, 12, ?. Answer with only the number. /no_think"
    }
)

Write-Host "[eval] Running $($cases.Count) short validation cases against $ChatEndpoint" -ForegroundColor Cyan
$results = foreach ($case in $cases) {
    try {
        $result = Invoke-StreamingChat $case.Prompt
        [pscustomobject]@{
            Case         = $case.Id
            Pass         = $result.Text -match $case.Expected
            FirstTokenMs = $result.FirstTokenMs
            TotalMs      = $result.TotalMs
            Output       = $result.Text
        }
    } catch {
        [pscustomobject]@{
            Case         = $case.Id
            Pass         = $false
            FirstTokenMs = $null
            TotalMs      = $null
            Output       = "ERROR: $($_.Exception.Message)"
        }
    }
}

$results | Format-Table -AutoSize -Wrap
$completed = @($results | Where-Object { $null -ne $_.TotalMs })
$passed = @($results | Where-Object Pass).Count
if ($completed.Count -gt 0) {
    $averageFirst = @($completed | Where-Object { $null -ne $_.FirstTokenMs } | ForEach-Object FirstTokenMs | Measure-Object -Average).Average
    $averageTotal = @($completed | ForEach-Object TotalMs | Measure-Object -Average).Average
    Write-Host ("[eval] Accuracy: {0}/{1} | avg first visible token: {2:N0} ms | avg total: {3:N0} ms" -f $passed, $results.Count, $averageFirst, $averageTotal) -ForegroundColor Green
    if (-not $NoReport) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        $report = [ordered]@{
            schema_version = 1
            started_at     = $startedAt.ToUniversalTime().ToString("o")
            finished_at    = (Get-Date).ToUniversalTime().ToString("o")
            endpoint       = $ChatEndpoint
            max_tokens     = $MaxTokens
            logical_cpus   = [Environment]::ProcessorCount
            os_version     = [Environment]::OSVersion.VersionString
            passed         = $passed
            total_cases    = $results.Count
            average_first_visible_token_ms = if ($null -eq $averageFirst) { $null } else { [math]::Round($averageFirst, 0) }
            average_total_ms = [math]::Round($averageTotal, 0)
            cases          = @($results)
        }
        $reportPath = Join-Path $OutputDirectory ("smoke-eval-{0}.json" -f $startedAt.ToString("yyyyMMdd-HHmmss"))
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
        Write-Host "[eval] Report: $reportPath" -ForegroundColor Cyan
    }
} else {
    Write-Host "[eval] No case completed. See errors above." -ForegroundColor Red
    exit 1
}

if ($passed -ne $results.Count) { exit 1 }
