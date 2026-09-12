[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    "run.ps1",
    "scripts/install-llama-cpp.ps1",
    "scripts/smoke-eval.ps1"
)

foreach ($script in $scripts) {
    $path = Join-Path $ProjectRoot $script
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -gt 0) {
        $parseErrors | ForEach-Object { Write-Error "${script}:$($_.Extent.StartLineNumber): $($_.Message)" }
        exit 1
    }
}

$configPath = Join-Path $ProjectRoot "config/models.json"
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$presets = @($config.models.PSObject.Properties)
if ($null -eq $config.models.PSObject.Properties[$config.default_model]) {
    throw "The default model '$($config.default_model)' is not defined."
}

foreach ($entry in $presets) {
    $preset = $entry.Value
    if ($preset.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid SHA-256 for model preset '$($entry.Name)'." }
    if ([string]::IsNullOrWhiteSpace($preset.url) -or $preset.url -notmatch '^https://') { throw "Model preset '$($entry.Name)' needs an HTTPS URL." }
    if ([int]$preset.context_size -lt 256) { throw "Model preset '$($entry.Name)' has an invalid context size." }
    if ([int]$preset.recommended_memory_gb -lt 1) { throw "Model preset '$($entry.Name)' needs a memory recommendation." }
}

Write-Host "Validation passed for $($scripts.Count) PowerShell scripts and $($presets.Count) model presets." -ForegroundColor Green
