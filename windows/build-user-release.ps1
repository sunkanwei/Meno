[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot ".."))
$buildRoot = Join-Path $repositoryRoot "build\windows"
$applicationDirectory = Join-Path $projectRoot "MenoClipboard"
$manifest = Join-Path $applicationDirectory "Cargo.toml"
$distDirectory = Join-Path $buildRoot "dist"
$notices = Join-Path $repositoryRoot "THIRD_PARTY_NOTICES.md"
if (-not (Test-Path -LiteralPath $distDirectory -PathType Container)) {
    throw "Existing dist package is unavailable; run the full release build first"
}
$distItem = Get-Item -LiteralPath $distDirectory -Force
if (($distItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to update a dist directory that is a reparse point"
}
if (-not (Test-Path -LiteralPath $notices -PathType Leaf)) {
    throw "THIRD_PARTY_NOTICES.md is unavailable"
}

$preservedFiles = @(
    "MenoHidProbe.exe",
    "MenoVirtualMouse.dll",
    "MenoVirtualMouse.inf",
    "MenoVirtualMouse.cat",
    "MenoVirtualMouse.cer"
)
foreach ($name in $preservedFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $distDirectory $name) -PathType Leaf)) {
        throw "Existing packaged artifact is unavailable: $name"
    }
}

& (Join-Path $projectRoot "verify-windows.ps1")
if ($LASTEXITCODE -ne 0) { throw "Windows verification failed" }

$cargo = (Get-Command cargo.exe -ErrorAction Stop).Source
$cargoTarget = Join-Path $buildRoot "cargo-target"
New-Item -ItemType Directory -Force -Path $cargoTarget | Out-Null
$previousCargoTarget = $env:CARGO_TARGET_DIR
$previousDriverAssetDirectory = $env:MENO_DRIVER_ASSET_DIR
$env:CARGO_TARGET_DIR = $cargoTarget
$env:MENO_DRIVER_ASSET_DIR = $distDirectory
try {
    & $cargo build --manifest-path $manifest --locked --release --bin MenoClipboard
    if ($LASTEXITCODE -ne 0) { throw "Rust user-mode Release build failed" }
} finally {
    $env:CARGO_TARGET_DIR = $previousCargoTarget
    $env:MENO_DRIVER_ASSET_DIR = $previousDriverAssetDirectory
}

$releaseExe = Join-Path $cargoTarget "release\MenoClipboard.exe"
if (-not (Test-Path -LiteralPath $releaseExe -PathType Leaf)) {
    throw "Application output was not produced: MenoClipboard.exe"
}
Copy-Item -LiteralPath $releaseExe -Destination $distDirectory -Force
Copy-Item -LiteralPath $notices -Destination $distDirectory -Force

$checksumNames = @("MenoClipboard.exe") + $preservedFiles + @("THIRD_PARTY_NOTICES.md")
$checksumLines = foreach ($name in $checksumNames) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $distDirectory $name)).Hash
    "$hash *$name"
}
Set-Content -LiteralPath (Join-Path $distDirectory "SHA256SUMS.txt") `
    -Value $checksumLines -Encoding ascii

Write-Host "Windows user-mode Release is ready at $distDirectory"
$checksumLines | ForEach-Object { Write-Host $_ }
$global:LASTEXITCODE = 0
