[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$archive = Join-Path $projectRoot "third_party\VB-CABLE\VBCABLE_Driver_Pack45.zip"
$expectedHash = "B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB"
$requiredEntries = @(
    "readme.txt",
    "VBCABLE_Setup_x64.exe",
    "vbMmeCable64_win10.inf",
    "vbaudio_cable64_win10.cat",
    "vbaudio_cable64_win10.sys"
)
$signedEntries = @{
    "VBCABLE_Setup_x64.exe" = "CN=BUREL VINCENT"
    "vbaudio_cable64_win10.cat" = "CN=Microsoft Windows Hardware Compatibility Publisher"
}

if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    throw "Official VB-CABLE archive is unavailable: $archive"
}
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
if ($actualHash -ne $expectedHash) {
    throw "Official VB-CABLE archive hash mismatch: $actualHash"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $entryNames = @($zip.Entries | ForEach-Object { $_.FullName })
    if ($entryNames.Count -ne 31) {
        throw "Official VB-CABLE archive entry count mismatch: $($entryNames.Count)"
    }
    foreach ($name in $entryNames) {
        if ([string]::IsNullOrWhiteSpace($name) -or
            [IO.Path]::IsPathRooted($name) -or
            $name.Contains("/") -or
            $name.Contains("\") -or
            $name -in @(".", "..")) {
            throw "Official VB-CABLE archive contains an unsafe entry: $name"
        }
    }
    foreach ($name in $requiredEntries) {
        if ($name -notin $entryNames) {
            throw "Official VB-CABLE archive is missing: $name"
        }
    }
    foreach ($name in $signedEntries.Keys) {
        $temporaryFile = Join-Path ([IO.Path]::GetTempPath()) `
            ("meno-vb-cable-{0}{1}" -f [guid]::NewGuid().ToString("N"), [IO.Path]::GetExtension($name))
        try {
            [IO.Compression.ZipFileExtensions]::ExtractToFile(
                $zip.GetEntry($name),
                $temporaryFile
            )
            $signature = Get-AuthenticodeSignature -LiteralPath $temporaryFile
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                throw "Official VB-CABLE signature is invalid: $name ($($signature.Status))"
            }
            if (-not $signature.SignerCertificate.Subject.StartsWith($signedEntries[$name])) {
                throw "Official VB-CABLE signer mismatch: $name"
            }
        } finally {
            Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    $zip.Dispose()
}

Write-Host "Official VB-CABLE archive verified: $actualHash"
$global:LASTEXITCODE = 0
