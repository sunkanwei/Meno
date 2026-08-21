param(
    [string]$SigningThumbprint = "",
    [string]$PackageCacheDirectory = "",
    [switch]$EmbedForClipboard
)

$ErrorActionPreference = "Stop"
$configuration = "Release"
$projectDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $projectDirectory "MenoVirtualMouse.vcxproj"
$output = Join-Path $projectDirectory "package"
$certificatePath = Join-Path $output "MenoVirtualMouse.cer"
$wdkVersion = "10.0.26100.6584"
$kitVersion = "10.0.26100.0"

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    throw "LOCALAPPDATA is unavailable"
}
if ([string]::IsNullOrWhiteSpace($PackageCacheDirectory)) {
    $packagesDirectory = Join-Path $env:LOCALAPPDATA "Meno\build-cache\wdk-nuget"
} else {
    $packagesDirectory = [IO.Path]::GetFullPath($PackageCacheDirectory)
}
$driverBuildRoot = Join-Path $env:LOCALAPPDATA "Meno\build-cache\driver\$configuration"
$buildOutput = Join-Path $driverBuildRoot "out"
$intermediateOutput = Join-Path $driverBuildRoot "obj"
New-Item -ItemType Directory -Force -Path $packagesDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $buildOutput | Out-Null
New-Item -ItemType Directory -Force -Path $intermediateOutput | Out-Null

$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer (vswhere.exe) was not found"
}
$visualStudio = & $vswhere -latest -products * `
    -requires Component.Microsoft.Windows.DriverKit `
    -property installationPath
if (-not $visualStudio) {
    throw "Visual Studio 2022 with the Windows Driver Kit component is required"
}
$msbuild = Join-Path $visualStudio "MSBuild\Current\Bin\amd64\MSBuild.exe"
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild was not found at $msbuild"
}

New-Item -ItemType Directory -Force -Path $output | Out-Null
$buildLog = Join-Path $output "native-build.log"
& $msbuild $project /t:Restore /p:RestorePackagesConfig=true `
    "/p:RestorePackagesPath=$packagesDirectory" `
    "/p:RestoreRepositoryPath=$packagesDirectory" `
    "/p:RestoreRepositoryPathOverride=$packagesDirectory" `
    "/p:MenoWdkPackagesDirectory=$packagesDirectory" /v:minimal
if ($LASTEXITCODE -ne 0) { throw "WDK NuGet restore failed" }

$wdkRoot = Join-Path $packagesDirectory "Microsoft.Windows.WDK.x64.$wdkVersion\c"
$sdkRoot = Join-Path $packagesDirectory "Microsoft.Windows.SDK.CPP.$wdkVersion\c"
$inf2cat = Join-Path $wdkRoot "bin\$kitVersion\x86\Inf2Cat.exe"
$infverif = Join-Path $wdkRoot "tools\$kitVersion\x64\InfVerif.exe"
$signtool = Join-Path $sdkRoot "bin\$kitVersion\x64\SignTool.exe"
foreach ($tool in @($inf2cat, $infverif, $signtool)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Required WDK tool was not found: $tool"
    }
}

& $msbuild $project /m /t:Rebuild `
    "/p:Configuration=$configuration" /p:Platform=x64 `
    "/p:MenoWdkPackagesDirectory=$packagesDirectory" `
    "/p:OutDir=$buildOutput\" "/p:IntDir=$intermediateOutput\" `
    /v:minimal /fl `
    "/flp:logfile=$buildLog;verbosity=diagnostic"
if ($LASTEXITCODE -ne 0) { throw "MenoVirtualMouse build failed" }

$driverBinary = Join-Path $buildOutput "MenoVirtualMouse.dll"
$driverInf = Join-Path $buildOutput "MenoVirtualMouse.inf"
foreach ($file in @($driverBinary, $driverInf)) {
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Expected build output was not produced: $file"
    }
}
if ((Select-String -LiteralPath $driverInf -Pattern '^DriverVer=08/11/2026,2\.3\.5\.0$').Count -ne 1) {
    throw "Built INF does not contain the fixed 2.3.5.0 DriverVer"
}

foreach ($name in @(
    "MenoVirtualMouse.dll",
    "MenoVirtualMouse.sys",
    "MenoVirtualMouse.inf",
    "MenoVirtualMouse.cat",
    "MenoVirtualMouse.cer",
    "SHA256SUMS.txt"
)) {
    $path = Join-Path $output $name
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}
Copy-Item -LiteralPath $driverBinary -Destination $output -Force
Copy-Item -LiteralPath $driverInf -Destination $output -Force

$packageInf = Join-Path $output "MenoVirtualMouse.inf"
$infVerificationLog = Join-Path $output "inf-verification.log"
$infResult = & $infverif /w /v $packageInf 2>&1
$infExitCode = $LASTEXITCODE
$infResult | Set-Content -LiteralPath $infVerificationLog -Encoding utf8
$infResult | Out-Host
if ($infExitCode -ne 0) {
    throw "InfVerif validation failed"
}

if ([string]::IsNullOrWhiteSpace($SigningThumbprint)) {
    $certificates = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object {
        $_.Subject -eq "CN=Meno Virtual Mouse Test" -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date) -and
        ($_.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.3")
    })
    if ($certificates.Count -ne 1) {
        throw "Exactly one valid CurrentUser test code-signing certificate named 'Meno Virtual Mouse Test' is required. Pass its thumbprint with -SigningThumbprint. The build never creates or exports a private key."
    }
    $certificate = $certificates[0]
} else {
    $normalizedThumbprint = ($SigningThumbprint -replace '\s', '').ToUpperInvariant()
    $certificate = Get-Item "Cert:\CurrentUser\My\$normalizedThumbprint" -ErrorAction Stop
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or
        -not ($certificate.EnhancedKeyUsageList.ObjectId -contains "1.3.6.1.5.5.7.3.3")) {
        throw "The selected signing certificate is expired, has no private key, or is not valid for code signing"
    }
}
$certificateThumbprint = $certificate.Thumbprint
Export-Certificate -Cert $certificate -FilePath $certificatePath -Force | Out-Null

$packageDll = Join-Path $output "MenoVirtualMouse.dll"
$packageCat = Join-Path $output "MenoVirtualMouse.cat"
& $signtool sign /fd SHA256 /sha1 $certificateThumbprint /s My $packageDll
if ($LASTEXITCODE -ne 0) { throw "UMDF driver binary signing failed" }
& $inf2cat "/driver:$output" /os:10_X64
if ($LASTEXITCODE -ne 0) { throw "Inf2Cat validation failed" }
& $signtool sign /fd SHA256 /sha1 $certificateThumbprint /s My $packageCat
if ($LASTEXITCODE -ne 0) { throw "Catalog signing failed" }

$verificationLog = Join-Path $output "signature-verification.log"
Set-Content -LiteralPath $verificationLog -Value "Meno Virtual Mouse signature verification"

function Test-MenoSignature {
    param([string[]]$Arguments)

    $result = & $signtool verify @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $result | Tee-Object -FilePath $verificationLog -Append | Out-Host
    if ($exitCode -ne 0) {
        throw "SignTool verification failed: $($Arguments -join ' '). If the failure is an untrusted root certificate, the selected test certificate has not been trusted on this machine: import package\MenoVirtualMouse.cer into the trusted root store once (installing the driver does this) and rebuild."
    }
}

Test-MenoSignature -Arguments @('/pa', '/v', $packageDll)
Test-MenoSignature -Arguments @('/pa', '/v', $packageCat)
Test-MenoSignature -Arguments @('/pa', '/v', '/c', $packageCat, $packageDll)
Test-MenoSignature -Arguments @('/pa', '/v', '/c', $packageCat, $packageInf)

if ($EmbedForClipboard) {
    $embeddedPackage = Join-Path $projectDirectory "..\MenoClipboard\assets\driver"
    New-Item -ItemType Directory -Force -Path $embeddedPackage | Out-Null
    $staleKernelDriver = Join-Path $embeddedPackage "MenoVirtualMouse.sys"
    if (Test-Path -LiteralPath $staleKernelDriver) {
        Remove-Item -LiteralPath $staleKernelDriver -Force
    }
    foreach ($name in @(
        "MenoVirtualMouse.dll",
        "MenoVirtualMouse.inf",
        "MenoVirtualMouse.cat",
        "MenoVirtualMouse.cer"
    )) {
        Copy-Item -LiteralPath (Join-Path $output $name) -Destination $embeddedPackage -Force
    }
    Write-Host "Meno Virtual Mouse package was embedded at $embeddedPackage"
}

Write-Host "Meno Virtual Mouse package is ready at $output"
$global:LASTEXITCODE = 0
