[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $FontPath,

    [string] $OutputDirectory,

    [switch] $NoInstall,

    [switch] $ShowMessage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:StatusPrefix = 'FUSION_FONT_REPAIR_JSON:'
$Script:FontRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Show-RepairMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('Information', 'Error', 'Warning')]
        [string] $Icon = 'Information'
    )

    if (-not $ShowMessage) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'Fusion Font Repair',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::$Icon
    ) | Out-Null
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-Argument {
    param([Parameter(Mandatory = $true)][string] $Value)
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Resolve-FFPython {
    if ($env:FUSION_FONTFORGE_FFPYTHON -and (Test-Path -LiteralPath $env:FUSION_FONTFORGE_FFPYTHON)) {
        return (Resolve-Path -LiteralPath $env:FUSION_FONTFORGE_FFPYTHON).Path
    }

    $candidates = @(
        'C:\Program Files\FontForgeBuilds\bin\ffpython.exe',
        'C:\Program Files (x86)\FontForgeBuilds\bin\ffpython.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'Could not find FontForge ffpython.exe. Install FontForge or set FUSION_FONTFORGE_FFPYTHON to the full ffpython.exe path.'
}

function Invoke-FontForgeWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FFPython,

        [Parameter(Mandatory = $true)]
        [string] $WorkerScript,

        [Parameter(Mandatory = $true)]
        [string[]] $WorkerArguments
    )

    $statusPrefix = 'FUSION_FONT_REPAIR_JSON:'
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $oldEncoding = $env:PYTHONIOENCODING
    $env:PYTHONIOENCODING = 'utf-8'
    try {
        $processArguments = @($WorkerScript) + $WorkerArguments
        $argumentString = ($processArguments | ForEach-Object { Quote-Argument $_ }) -join ' '
        $process = Start-Process `
            -FilePath $FFPython `
            -ArgumentList $argumentString `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru `
            -Wait

        $stdout = if ((Test-Path -LiteralPath $stdoutPath) -and (Get-Item -LiteralPath $stdoutPath).Length -gt 0) {
            Get-Content -LiteralPath $stdoutPath -Encoding UTF8
        }
        else {
            @()
        }
        $stderr = if ((Test-Path -LiteralPath $stderrPath) -and (Get-Item -LiteralPath $stderrPath).Length -gt 0) {
            Get-Content -LiteralPath $stderrPath -Encoding UTF8
        }
        else {
            @()
        }
        $rawOutput = New-Object System.Collections.Generic.List[string]
        foreach ($line in @($stdout)) {
            $rawOutput.Add($line.ToString())
        }
        foreach ($line in @($stderr)) {
            $rawOutput.Add($line.ToString())
        }
        $exitCode = $process.ExitCode
    }
    finally {
        $env:PYTHONIOENCODING = $oldEncoding
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }

    $jsonLine = $rawOutput | Where-Object { $_.StartsWith($statusPrefix, [StringComparison]::Ordinal) } | Select-Object -Last 1
    if (-not $jsonLine) {
        throw "FontForge did not return a machine-readable status.`n$($rawOutput -join [Environment]::NewLine)"
    }

    $payload = $jsonLine.Substring($statusPrefix.Length) | ConvertFrom-Json
    if ($exitCode -ne 0 -or -not $payload.ok) {
        $details = if ($payload.error) { $payload.error } else { "FontForge exited with code $exitCode." }
        $noise = $rawOutput | Where-Object { -not $_.StartsWith($statusPrefix, [StringComparison]::Ordinal) }
        if ($noise.Count -gt 0) {
            $details += [Environment]::NewLine + ($noise -join [Environment]::NewLine)
        }
        throw $details
    }

    return $payload
}

function Assert-SupportedFontFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo] $FontFile)

    $supported = @('.ttf', '.otf')
    if ($supported -notcontains $FontFile.Extension.ToLowerInvariant()) {
        throw "Unsupported font extension '$($FontFile.Extension)'. Supported extensions: .ttf, .otf."
    }
}

function Assert-NoInstalledDuplicate {
    param([Parameter(Mandatory = $true)] $Plan)

    $windowsFontsPath = Join-Path $env:WINDIR 'Fonts'
    $targetFontPath = Join-Path $windowsFontsPath $Plan.output_file_name
    if (Test-Path -LiteralPath $targetFontPath) {
        throw "A generated Fusion font file already exists: $targetFontPath"
    }

    if (-not (Test-Path -LiteralPath $Script:FontRegistryPath)) {
        return
    }

    $registryItem = Get-ItemProperty -LiteralPath $Script:FontRegistryPath
    $namePattern = [WildcardPattern]::Escape([string] $Plan.full_name) + ' (*'
    $matches = @(
        $registryItem.PSObject.Properties |
            Where-Object {
                $_.MemberType -eq 'NoteProperty' -and
                (
                    $_.Name -eq [string] $Plan.registry_name -or
                    $_.Name -like $namePattern -or
                    [string] $_.Value -ieq [string] $Plan.output_file_name
                )
            }
    )

    if ($matches.Count -gt 0) {
        $matchList = ($matches | ForEach-Object { "$($_.Name) = $($_.Value)" }) -join [Environment]::NewLine
        throw "A matching Fusion font is already installed. Duplicate policy is stop-on-duplicate.$([Environment]::NewLine)$matchList"
    }
}

function Install-SystemFont {
    param(
        [Parameter(Mandatory = $true)]
        [string] $GeneratedFontPath,

        [Parameter(Mandatory = $true)]
        $Plan
    )

    $windowsFontsPath = Join-Path $env:WINDIR 'Fonts'
    $targetFontPath = Join-Path $windowsFontsPath $Plan.output_file_name

    Copy-Item -LiteralPath $GeneratedFontPath -Destination $targetFontPath -ErrorAction Stop
    New-ItemProperty -LiteralPath $Script:FontRegistryPath -Name $Plan.registry_name -Value $Plan.output_file_name -PropertyType String -ErrorAction Stop | Out-Null

    $source = @'
using System;
using System.Runtime.InteropServices;

public static class FusionFontRepairNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SendNotifyMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
}
'@
    Add-Type -TypeDefinition $source -ErrorAction SilentlyContinue
    [FusionFontRepairNative]::SendNotifyMessage([IntPtr] 0xffff, 0x001d, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null

    return $targetFontPath
}

function Start-ElevatedSelf {
    param([Parameter(Mandatory = $true)][string] $ResolvedFontPath)

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $PSCommandPath,
        $ResolvedFontPath
    )
    if ($OutputDirectory) {
        $arguments += @('-OutputDirectory', $OutputDirectory)
    }
    if ($NoInstall) {
        $arguments += '-NoInstall'
    }
    if ($ShowMessage) {
        $arguments += '-ShowMessage'
    }

    $argumentString = ($arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentString -Verb RunAs -PassThru -Wait
    exit $process.ExitCode
}

$tempOutputDirectory = $null
$generatedPath = $null

try {
    $fontItem = Get-Item -LiteralPath $FontPath -ErrorAction Stop
    if ($fontItem.PSIsContainer) {
        throw 'Expected exactly one font file, but a folder was provided.'
    }

    Assert-SupportedFontFile -FontFile $fontItem

    if (-not $NoInstall -and -not (Test-IsAdministrator)) {
        Write-Host 'Administrator permission is required to install into C:\Windows\Fonts. Requesting elevation...'
        Start-ElevatedSelf -ResolvedFontPath $fontItem.FullName
    }

    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $workerScript = Join-Path $scriptDirectory 'fusion_font_repair.py'
    if (-not (Test-Path -LiteralPath $workerScript)) {
        throw "Missing worker script: $workerScript"
    }

    $ffPython = Resolve-FFPython
    Write-Host "Using FontForge Python: $ffPython"
    Write-Host "Reading font: $($fontItem.FullName)"

    $plan = Invoke-FontForgeWorker -FFPython $ffPython -WorkerScript $workerScript -WorkerArguments @(
        '--input', $fontItem.FullName,
        '--plan-only'
    )

    if (-not $NoInstall) {
        Assert-NoInstalledDuplicate -Plan $plan
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'FusionFontRepair'
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        $tempOutputDirectory = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempOutputDirectory | Out-Null
        $targetOutputDirectory = $tempOutputDirectory
    }
    elseif ($OutputDirectory) {
        $targetOutputDirectory = (New-Item -ItemType Directory -Force -Path $OutputDirectory).FullName
    }
    else {
        $targetOutputDirectory = $fontItem.DirectoryName
    }

    Write-Host "Creating repaired font: $($plan.full_name)"
    $result = Invoke-FontForgeWorker -FFPython $ffPython -WorkerScript $workerScript -WorkerArguments @(
        '--input', $fontItem.FullName,
        '--output-dir', $targetOutputDirectory
    )
    $generatedPath = $result.output_path

    if ($NoInstall) {
        $message = "Created repaired font:`n$generatedPath`n`nInternal font name:`n$($result.full_name)"
        Write-Host $message
        Show-RepairMessage -Message $message -Icon Information
        exit 0
    }

    Write-Host 'Installing system-wide font...'
    $installedPath = Install-SystemFont -GeneratedFontPath $generatedPath -Plan $result

    if ($tempOutputDirectory -and (Test-Path -LiteralPath $tempOutputDirectory)) {
        Remove-Item -LiteralPath $tempOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $message = "Installed repaired font:`n$($result.full_name)`n`nFile:`n$installedPath"
    Write-Host $message
    Show-RepairMessage -Message $message -Icon Information
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Error $message
    Show-RepairMessage -Message $message -Icon Error
    exit 1
}
