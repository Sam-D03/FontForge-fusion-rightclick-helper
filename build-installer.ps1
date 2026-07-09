[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')]
    [string] $Version = '1.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSCommandPath
$installerScript = Join-Path $repoRoot 'installer\FusionFontForgeHelper.iss'
$distDirectory = Join-Path $repoRoot 'dist'
$vendorDirectory = Join-Path $repoRoot 'build\python-vendor'
$fontToolsVersion = '4.62.1'

function Resolve-InnoCompiler {
    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Inno Setup 6 compiler (ISCC.exe) was not found. Install it from https://jrsoftware.org/isinfo.php or with winget install JRSoftware.InnoSetup.'
}

function Resolve-Python {
    $commands = @('python.exe', 'py.exe')
    foreach ($commandName in $commands) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    throw 'Python was not found. Install Python 3 to build the installer because the build vendors fontTools.'
}

function Update-PythonVendor {
    $python = Resolve-Python
    Write-Host "Using Python for vendored dependencies: $python"
    Write-Host "Vendoring fontTools $fontToolsVersion..."

    if (Test-Path -LiteralPath $vendorDirectory) {
        Remove-Item -LiteralPath $vendorDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $vendorDirectory | Out-Null

    & $python -m pip install `
        --disable-pip-version-check `
        --no-warn-script-location `
        --target $vendorDirectory `
        "fonttools==$fontToolsVersion"

    if ($LASTEXITCODE -ne 0) {
        throw "pip failed while vendoring fontTools with exit code $LASTEXITCODE."
    }

    $fontToolsPackage = Join-Path $vendorDirectory 'fontTools'
    if (-not (Test-Path -LiteralPath $fontToolsPackage)) {
        throw "fontTools was not vendored into the expected folder: $fontToolsPackage"
    }

    Get-ChildItem -LiteralPath $vendorDirectory -Recurse -Directory -Filter '__pycache__' |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $vendorDirectory -Recurse -File |
        Where-Object { $_.Extension -in @('.pyc', '.pyo', '.pyd', '.c') } |
        Remove-Item -Force
    foreach ($unneededDirectory in @('bin', 'share')) {
        $path = Join-Path $vendorDirectory $unneededDirectory
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

if (-not (Test-Path -LiteralPath $installerScript)) {
    throw "Missing installer script: $installerScript"
}

New-Item -ItemType Directory -Force -Path $distDirectory | Out-Null
Update-PythonVendor

$iscc = Resolve-InnoCompiler
Write-Host "Using Inno Setup compiler: $iscc"
Write-Host "Building Fusion FontForge Helper installer v$Version..."

& $iscc "/DAppVersion=$Version" $installerScript
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler failed with exit code $LASTEXITCODE."
}

$installerPath = Join-Path $distDirectory "FusionFontForgeHelperSetup-$Version.exe"
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "Installer build completed but the expected output was not found: $installerPath"
}

$hash = Get-FileHash -LiteralPath $installerPath -Algorithm SHA256
$checksumPath = "$installerPath.sha256"
$checksumText = "$($hash.Hash) *$(Split-Path -Leaf $installerPath)"
Set-Content -LiteralPath $checksumPath -Value $checksumText -Encoding ASCII

Write-Host "Built installer: $installerPath"
Write-Host "Wrote checksum: $checksumPath"
