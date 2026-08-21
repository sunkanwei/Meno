[CmdletBinding()]
param(
    [string]$SigningThumbprint = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$driverDirectory = Join-Path $projectRoot "MenoVirtualMouse"
$applicationDirectory = Join-Path $projectRoot "MenoClipboard"
$distDirectory = Join-Path $projectRoot "dist"
$notices = Join-Path $projectRoot "THIRD_PARTY_NOTICES.md"

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw "LOCALAPPDATA is unavailable"
}

$cargo = (Get-Command cargo.exe -ErrorAction Stop).Source

& (Join-Path $projectRoot "verify-windows.ps1")
if ($LASTEXITCODE -ne 0) { throw "Windows verification failed" }

$driverParameters = @{ EmbedForClipboard = $true }
if (-not [string]::IsNullOrWhiteSpace($SigningThumbprint)) {
    $driverParameters.SigningThumbprint = $SigningThumbprint
}
& (Join-Path $driverDirectory "build-driver.ps1") @driverParameters
if ($LASTEXITCODE -ne 0) { throw "Meno Virtual Mouse build failed" }

$cargoTarget = Join-Path $env:LOCALAPPDATA "Meno\build-cache\cargo-target"
New-Item -ItemType Directory -Force -Path $cargoTarget | Out-Null
$previousCargoTarget = $env:CARGO_TARGET_DIR
$env:CARGO_TARGET_DIR = $cargoTarget
try {
    Push-Location $applicationDirectory
    try {
        & $cargo build --locked --release --bins
        if ($LASTEXITCODE -ne 0) { throw "Rust Release build failed" }
    } finally {
        Pop-Location
    }
} finally {
    $env:CARGO_TARGET_DIR = $previousCargoTarget
}

$driverPackage = Join-Path $driverDirectory "package"
$applicationFiles = @("MenoClipboard.exe", "MenoHidProbe.exe")
$driverFiles = @(
    "MenoVirtualMouse.dll",
    "MenoVirtualMouse.inf",
    "MenoVirtualMouse.cat",
    "MenoVirtualMouse.cer"
)
foreach ($name in $applicationFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $cargoTarget "release\$name"))) {
        throw "Application output was not produced: $name"
    }
}
foreach ($name in $driverFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $driverPackage $name))) {
        throw "Driver output was not produced: $name"
    }
}
if (-not (Test-Path -LiteralPath $notices -PathType Leaf)) {
    throw "THIRD_PARTY_NOTICES.md is unavailable"
}
if (Test-Path -LiteralPath (Join-Path $driverPackage "MenoVirtualMouse.sys")) {
    throw "Stale kernel driver found in the UMDF 2 package"
}

if (Test-Path -LiteralPath $distDirectory) {
    $distItem = Get-Item -LiteralPath $distDirectory -Force
    if (($distItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to replace a dist directory that is a reparse point"
    }
    Remove-Item -LiteralPath $distDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $distDirectory | Out-Null
foreach ($name in $applicationFiles) {
    Copy-Item -LiteralPath (Join-Path $cargoTarget "release\$name") -Destination $distDirectory
}
foreach ($name in $driverFiles) {
    Copy-Item -LiteralPath (Join-Path $driverPackage $name) -Destination $distDirectory
}
Copy-Item -LiteralPath $notices -Destination $distDirectory

$checksumNames = $applicationFiles + $driverFiles + @("THIRD_PARTY_NOTICES.md")
$checksumLines = foreach ($name in $checksumNames) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $distDirectory $name)).Hash
    "$hash *$name"
}
Set-Content -LiteralPath (Join-Path $distDirectory "SHA256SUMS.txt") `
    -Value $checksumLines -Encoding ascii

Write-Host "Personal Release is ready at $distDirectory"
$checksumLines | ForEach-Object { Write-Host $_ }
$global:LASTEXITCODE = 0
