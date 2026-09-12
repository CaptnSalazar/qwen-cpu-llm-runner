[CmdletBinding()]
param(
    [ValidateSet("chat", "server", "download", "doctor")]
    [string]$Mode = "chat",

    [string]$Model,
    [string]$Prompt,
    [ValidateRange(256, 262144)]
    [int]$ContextSize = 0,
    [ValidateRange(0, 512)]
    [int]$Threads = 0,
    [string]$GpuLayers = "",
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,
    [string]$ListenAddress = "127.0.0.1",
    [string]$ModelUrl,
    [switch]$Force,
    [switch]$NoGpu,
    [switch]$NoReasoning,
    [switch]$VerifyModel,
    [switch]$SkipHashCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $ProjectRoot "config/models.json"
$ModelsDir = Join-Path $ProjectRoot "models"
$RuntimeDir = Join-Path $ProjectRoot "runtime"

function Write-Info([string]$Message) { Write-Host "[local-llm] $Message" -ForegroundColor Cyan }
function Stop-WithError([string]$Message) { throw "[local-llm] $Message" }

function Save-RemoteFile([string]$Uri, [string]$Destination) {
    # Direct streaming avoids a Windows PowerShell 5.1 path-length bug on long
    # signed redirects from large-file hosts such as GitHub and Hugging Face.
    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Add("User-Agent", "local-llm-runner")
        $client.DownloadFile($Uri, $Destination)
    } finally {
        $client.Dispose()
    }
}

function Get-LlamaBinary([string]$Name) {
    $candidates = @(
        (Join-Path $RuntimeDir "$Name.exe"),
        (Join-Path $RuntimeDir "bin/$Name.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Get-AutoThreads {
    $logical = [Environment]::ProcessorCount
    # Keep one logical core free so the workstation remains responsive.
    return [Math]::Max(1, $logical - 1)
}

function Get-ConfiguredGpuLayers([object]$Preset) {
    if ($NoGpu) { return "0" }
    if ($GpuLayers) {
        if ($GpuLayers -notmatch '^\d+$') { Stop-WithError "-GpuLayers must be a non-negative integer or be omitted." }
        return $GpuLayers
    }
    # llama.cpp safely falls back to CPU when the installed binary has no accelerator backend.
    # 999 means 'try to offload every transformer layer' on builds with CUDA/Vulkan/Metal.
    if ($Preset.gpu_layers -eq "auto") { return "999" }
    return [string]$Preset.gpu_layers
}

function Get-ModelConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-WithError "Configuration was not found: $ConfigPath" }
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $presetName = if ($Model) { $Model } else { $config.default_model }
    $preset = $config.models.PSObject.Properties[$presetName].Value
    if ($null -eq $preset) {
        $available = ($config.models.PSObject.Properties.Name -join ", ")
        Stop-WithError "Unknown model preset '$presetName'. Available presets: $available"
    }
    return @{ Name = $presetName; Preset = $preset }
}

function Test-ModelHash([string]$Path, [object]$Preset, [switch]$Required) {
    if ($SkipHashCheck -or [string]::IsNullOrWhiteSpace($Preset.sha256)) { return }
    if (-not $Required -and -not $VerifyModel) { return }
    Write-Info "Verifying SHA-256..."
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Preset.sha256.ToLowerInvariant()) {
        Stop-WithError "SHA-256 mismatch for '$Path'. Delete this file and download it again."
    }
}

function Get-ModelFile([object]$Details, [switch]$AllowDownload) {
    $preset = $Details.Preset
    $modelPath = Join-Path $ModelsDir $preset.file
    if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
        Test-ModelHash $modelPath $preset
        return (Resolve-Path -LiteralPath $modelPath).Path
    }
    if (-not $AllowDownload) {
        Stop-WithError "Model file is missing: $modelPath. Run '.\run.ps1 -Mode download -Model $($Details.Name)' first."
    }
    $downloadUrl = if ($ModelUrl) { $ModelUrl } else { $preset.url }
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) { Stop-WithError "No download URL is configured. Supply -ModelUrl for this model." }

    New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null
    $partialPath = "$modelPath.part"
    if (Test-Path -LiteralPath $partialPath) {
        if ($Force) { Remove-Item -LiteralPath $partialPath -Force }
        else { Stop-WithError "A partial download exists at '$partialPath'. Re-run with -Force to restart it." }
    }
    Write-Info "Downloading '$($Details.Name)' to $modelPath"
    Write-Info "This can take a while; the model weights remain entirely on this PC."
    try {
        # BITS is robust for large Windows downloads. WebClient is used when BITS
        # is unavailable because Invoke-WebRequest has a path-length bug on some redirects.
        Start-BitsTransfer -Source $downloadUrl -Destination $partialPath -DisplayName "Local LLM model: $($Details.Name)" -ErrorAction Stop
    } catch {
        Write-Info "BITS was unavailable; using a direct streaming download."
        Save-RemoteFile $downloadUrl $partialPath
    }
    Move-Item -LiteralPath $partialPath -Destination $modelPath
    Test-ModelHash $modelPath $preset -Required
    return (Resolve-Path -LiteralPath $modelPath).Path
}

function Invoke-Doctor {
    $details = Get-ModelConfig
    $cli = Get-LlamaBinary "llama-cli"
    $server = Get-LlamaBinary "llama-server"
    $modelPath = Join-Path $ModelsDir $details.Preset.file
    Write-Host "Local LLM Runner doctor" -ForegroundColor Green
    Write-Host "Preset:          $($details.Name)"
    Write-Host "Model present:   $(Test-Path -LiteralPath $modelPath) ($modelPath)"
    Write-Host "llama-cli:       $(if ($cli) { $cli } else { 'MISSING' })"
    Write-Host "llama-server:    $(if ($server) { $server } else { 'MISSING' })"
    Write-Host "Logical CPUs:    $([Environment]::ProcessorCount)"
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
    Write-Host "Display adapters: $(if ($gpu) { $gpu -join '; ' } else { 'not detected' })"
    if (-not $cli -or -not $server) {
        Write-Host "Install llama.cpp with .\scripts\install-llama-cpp.ps1" -ForegroundColor Yellow
    }
}

$details = Get-ModelConfig
if ($Mode -eq "doctor") { Invoke-Doctor; exit 0 }
if ($Mode -eq "download") { [void](Get-ModelFile $details -AllowDownload); Write-Info "Download complete."; exit 0 }

$modelPath = Get-ModelFile $details
$preset = $details.Preset
$effectiveContext = if ($ContextSize -gt 0) { $ContextSize } else { [int]$preset.context_size }
$effectiveThreads = if ($Threads -gt 0) { $Threads } elseif ([int]$preset.threads -gt 0) { [int]$preset.threads } else { Get-AutoThreads }
$effectiveGpuLayers = Get-ConfiguredGpuLayers $preset
$reasoningMode = if ($NoReasoning) { "off" } else { "auto" }
$commonArgs = @(
    "-m", $modelPath,
    "-c", "$effectiveContext",
    "-t", "$effectiveThreads",
    "-tb", "$effectiveThreads",
    "-ngl", "$effectiveGpuLayers",
    "--flash-attn", "auto",
    "--temp", "$($preset.temperature)",
    "--top-k", "$($preset.top_k)",
    "--top-p", "$($preset.top_p)",
    "--min-p", "$($preset.min_p)",
    "--presence-penalty", "$($preset.presence_penalty)",
    "--repeat-penalty", "$($preset.repeat_penalty)"
)
$commonArgs += @("--reasoning", $reasoningMode)

Write-Info "Preset: $($details.Name) | context: $effectiveContext | CPU threads: $effectiveThreads | GPU layers: $effectiveGpuLayers | reasoning: $reasoningMode"
if ($Mode -eq "server") {
    $binary = Get-LlamaBinary "llama-server"
    if (-not $binary) { Stop-WithError "llama-server was not found. Run '.\scripts\install-llama-cpp.ps1' or add it to PATH." }
    Write-Info "Starting local OpenAI-compatible API at http://${ListenAddress}:$Port"
    Write-Info "Press Ctrl+C to stop."
    & $binary @commonArgs "--host", $ListenAddress, "--port", "$Port", "--jinja"
    exit $LASTEXITCODE
}

$binary = Get-LlamaBinary "llama-cli"
if (-not $binary) { Stop-WithError "llama-cli was not found. Run '.\scripts\install-llama-cpp.ps1' or add it to PATH." }
if ($Prompt) {
    # Current llama.cpp infers chat formatting from the GGUF's Jinja template.
    # A predefined prompt runs non-interactively, making this suitable for scripts.
    & $binary @commonArgs "-p", $Prompt
} else {
    Write-Info "Starting an interactive chat. Press Ctrl+C to stop."
    # Recent llama.cpp releases enable template-based chat automatically; older
    # -cnv shorthand was removed upstream.
    & $binary @commonArgs
}
exit $LASTEXITCODE
