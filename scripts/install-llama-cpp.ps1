[CmdletBinding()]
param(
    [ValidateSet("cpu", "cuda", "vulkan")]
    [string]$Backend = "cpu",
    [string]$Version = "latest",
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$RuntimeDir = Join-Path $ProjectRoot "runtime"
$ApiHeaders = @{ "User-Agent" = "local-llm-runner-installer"; "Accept" = "application/vnd.github+json" }

function Write-Info([string]$Message) { Write-Host "[local-llm] $Message" -ForegroundColor Cyan }
function Stop-WithError([string]$Message) { throw "[local-llm] $Message" }

function Save-RemoteFile([string]$Uri, [string]$Destination) {
    # WebClient streams directly to the destination. Unlike Invoke-WebRequest in
    # Windows PowerShell 5.1, it does not turn GitHub's long signed redirect URL
    # into a temporary file name, which can trigger PathTooLongException.
    $client = New-Object System.Net.WebClient
    try {
        $client.Headers.Add("User-Agent", "local-llm-runner-installer")
        $client.DownloadFile($Uri, $Destination)
    } finally {
        $client.Dispose()
    }
}

if ((Test-Path -LiteralPath $RuntimeDir) -and -not $Force) {
    $existing = Get-ChildItem -LiteralPath $RuntimeDir -Recurse -Filter "llama-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) { Stop-WithError "llama.cpp already appears to be installed at '$($existing.FullName)'. Re-run with -Force to replace it." }
}

$needles = switch ($Backend) {
    "cpu"    { @("win-cpu-x64.zip", "win-avx2-x64.zip") }
    "cuda"   { @("win-cuda", "win-cublas") }
    "vulkan" { @("win-vulkan-x64.zip", "win-vulkan") }
}

function Find-WindowsAsset([object]$Release) {
    foreach ($needle in $needles) {
        $match = @($Release.assets | Where-Object { $_.name -like "*$needle*" -and $_.name -like "*.zip" }) | Select-Object -First 1
        if ($match) { return $match }
    }
    return $null
}

Write-Info "Looking up a llama.cpp $Backend build..."
$release = $null
$asset = $null
if ($Version -eq "latest") {
    # The GitHub 'latest' release can be a source-only release. Search recent releases
    # for the newest one that actually contains the requested Windows binary.
    # Do not wrap this in @(): Windows PowerShell can turn the JSON array into
    # one nested item, making the selected release appear as every tag at once.
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=100" -Headers $ApiHeaders
    foreach ($candidate in $releases) {
        $candidateAsset = Find-WindowsAsset $candidate
        if ($candidateAsset) {
            $release = $candidate
            $asset = $candidateAsset
            break
        }
    }
} else {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Version" -Headers $ApiHeaders
    $asset = Find-WindowsAsset $release
}
if (-not $asset) {
    $versionText = if ($release) { $release.tag_name } else { "the recent release list" }
    Stop-WithError "Could not find a Windows $Backend build in $versionText. Try another backend or a specific upstream build tag."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "llmr"
$tempZip = Join-Path $tempRoot "runtime.zip"
$cudaRuntimeZip = Join-Path $tempRoot "cudart.zip"
$stageDir = Join-Path $tempRoot "extract"
try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
    if (Test-Path -LiteralPath $cudaRuntimeZip) { Remove-Item -LiteralPath $cudaRuntimeZip -Force }
    if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
    Write-Info "Downloading $($asset.name)..."
    Save-RemoteFile $asset.browser_download_url $tempZip
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    Expand-Archive -LiteralPath $tempZip -DestinationPath $stageDir -Force
    if ($Backend -eq "cuda") {
        # Current upstream Windows CUDA releases ship the CUDA runtime DLLs separately.
        # Merge them when they are present so end users do not need a toolkit installation.
        $cudaSuffix = $asset.name -replace '^llama-(?:b\d+-)?bin-', ''
        $cudaRuntimeAsset = @($release.assets | Where-Object { $_.name -eq "cudart-llama-bin-$cudaSuffix" }) | Select-Object -First 1
        if ($cudaRuntimeAsset) {
            Write-Info "Downloading bundled CUDA runtime DLLs..."
            Save-RemoteFile $cudaRuntimeAsset.browser_download_url $cudaRuntimeZip
            Expand-Archive -LiteralPath $cudaRuntimeZip -DestinationPath $stageDir -Force
        } else {
            Write-Info "No bundled CUDA runtime archive was published; using the CUDA runtime installed on this PC."
        }
    }
    $cli = Get-ChildItem -LiteralPath $stageDir -Recurse -Filter "llama-cli.exe" | Select-Object -First 1
    $server = Get-ChildItem -LiteralPath $stageDir -Recurse -Filter "llama-server.exe" | Select-Object -First 1
    if (-not $cli -or -not $server) { Stop-WithError "Downloaded archive did not contain llama-cli.exe and llama-server.exe." }
    if (Test-Path -LiteralPath $RuntimeDir) { Remove-Item -LiteralPath $RuntimeDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
    # Releases occasionally package CUDA runtime DLLs in a second directory.
    # Flatten files into one portable runtime directory so sibling DLL discovery works.
    Get-ChildItem -LiteralPath $stageDir -Recurse -File | Copy-Item -Destination $RuntimeDir -Force
    Write-Info "Installed $($release.tag_name) ($Backend) to $RuntimeDir"
    & (Join-Path $RuntimeDir "llama-cli.exe") "--version"
} finally {
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force }
    if (Test-Path -LiteralPath $cudaRuntimeZip) { Remove-Item -LiteralPath $cudaRuntimeZip -Force }
    if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
    if ((Test-Path -LiteralPath $tempRoot) -and -not (Get-ChildItem -LiteralPath $tempRoot -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $tempRoot -Force }
}
