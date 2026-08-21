[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot ".."))
$buildRoot = Join-Path $repositoryRoot "build\windows"
$manifest = Join-Path $projectRoot "MenoClipboard\Cargo.toml"
$agentManifest = Join-Path $projectRoot "WindowsAgent\Cargo.toml"

& (Join-Path $projectRoot "verify-vb-cable.ps1")
if ($LASTEXITCODE -ne 0) { throw "VB-CABLE package verification failed" }

$cargo = (Get-Command cargo.exe -ErrorAction Stop).Source
$cargoTarget = Join-Path $buildRoot "cargo-target"
New-Item -ItemType Directory -Force -Path $cargoTarget | Out-Null
$previousCargoTarget = $env:CARGO_TARGET_DIR
$previousDriverAssetDirectory = $env:MENO_DRIVER_ASSET_DIR
$env:CARGO_TARGET_DIR = $cargoTarget
$env:MENO_DRIVER_ASSET_DIR = $null
try {
    & $cargo fmt --manifest-path $manifest --all -- --check
    if ($LASTEXITCODE -ne 0) { throw "Rust formatting check failed" }

    & $cargo fmt --manifest-path $agentManifest --all -- --check
    if ($LASTEXITCODE -ne 0) { throw "Windows Agent formatting check failed" }

    & $cargo clippy --manifest-path $manifest --locked --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw "Rust Clippy check failed" }

    & $cargo test --manifest-path $manifest --locked --all-targets
    if ($LASTEXITCODE -ne 0) { throw "Rust tests failed" }

    & $cargo clippy --manifest-path $agentManifest --locked --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw "Windows Agent Clippy check failed" }

    & $cargo test --manifest-path $agentManifest --locked --all-targets
    if ($LASTEXITCODE -ne 0) { throw "Windows Agent tests failed" }

    & $cargo metadata --manifest-path $manifest --locked --offline --format-version 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Locked offline dependency metadata check failed" }

    & $cargo metadata --manifest-path $agentManifest --locked --offline --format-version 1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Windows Agent locked offline metadata check failed" }
} finally {
    $env:CARGO_TARGET_DIR = $previousCargoTarget
    $env:MENO_DRIVER_ASSET_DIR = $previousDriverAssetDirectory
}

Write-Host "Windows user-mode verification passed."
$global:LASTEXITCODE = 0
