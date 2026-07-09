[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $FontPath,

    [string] $OutputDirectory,

    [switch] $NoInstall,

    [switch] $ShowMessage,

    [string] $RequestedFamilyName,

    [string] $RequestedStyleName,

    [string] $StatusFile,

    [switch] $DeferMessageToParent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:StatusPrefix = 'FUSION_FONT_REPAIR_JSON:'
$Script:FontRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
$Script:UserFontRegistryPath = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$Script:LogDirectory = Join-Path ([System.IO.Path]::GetTempPath()) 'FusionFontRepair'
$Script:LogPath = Join-Path $Script:LogDirectory 'FusionFontRepair.log'
$Script:ConfigFileName = 'fusion-font-repair.config.json'

function Write-RepairLog {
    param([Parameter(Mandatory = $true)][string] $Message)

    try {
        New-Item -ItemType Directory -Force -Path $Script:LogDirectory | Out-Null
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $Script:LogPath -Value "[$timestamp] $Message"
    }
    catch {
        # Logging should never block the repair workflow.
    }
}

function Show-RepairMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('Information', 'Error', 'Warning')]
        [string] $Icon = 'Information'
    )

    if (-not $ShowMessage -or $DeferMessageToParent) {
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

function Write-RepairStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('Information', 'Error', 'Warning')]
        [string] $Icon = 'Information',

        [int] $ExitCode = 0
    )

    if ([string]::IsNullOrWhiteSpace($StatusFile)) {
        return
    }

    try {
        $statusDirectory = Split-Path -Parent $StatusFile
        if ($statusDirectory) {
            New-Item -ItemType Directory -Force -Path $statusDirectory | Out-Null
        }

        [pscustomobject]@{
            message = $Message
            icon = $Icon
            exit_code = $ExitCode
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatusFile -Encoding UTF8
    }
    catch {
        Write-RepairLog "Could not write status file '$StatusFile': $($_.Exception.Message)"
    }
}

function Read-RepairStatus {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-RepairLog "Could not read status file '$Path': $($_.Exception.Message)"
        return $null
    }
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

function Resolve-ConfiguredFFPython {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $configPath = Join-Path $scriptDirectory $Script:ConfigFileName
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $configuredPath = $config.ffpython_path
        if (-not $configuredPath) {
            $configuredPath = $config.ffpython
        }

        if ($configuredPath -and (Test-Path -LiteralPath $configuredPath)) {
            return (Resolve-Path -LiteralPath $configuredPath).Path
        }

        Write-RepairLog "Configured FontForge path is missing or invalid: '$configuredPath'."
    }
    catch {
        Write-RepairLog "Could not read '$configPath': $($_.Exception.Message)"
    }

    return $null
}

function Resolve-FFPython {
    if ($env:FUSION_FONTFORGE_FFPYTHON -and (Test-Path -LiteralPath $env:FUSION_FONTFORGE_FFPYTHON)) {
        return (Resolve-Path -LiteralPath $env:FUSION_FONTFORGE_FFPYTHON).Path
    }

    $configuredFFPython = Resolve-ConfiguredFFPython
    if ($configuredFFPython) {
        return $configuredFFPython
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

    throw 'Could not find FontForge ffpython.exe. Install FontForge, set FUSION_FONTFORGE_FFPYTHON, or update fusion-font-repair.config.json with the full ffpython.exe path.'
}

function Get-FontRegistryCandidates {
    $registryPaths = @(
        @{
            Path = $Script:FontRegistryPath
            DefaultFolder = Join-Path $env:WINDIR 'Fonts'
        },
        @{
            Path = $Script:UserFontRegistryPath
            DefaultFolder = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
        }
    )

    foreach ($entry in $registryPaths) {
        if (-not (Test-Path -LiteralPath $entry.Path)) {
            continue
        }

        $registryItem = Get-ItemProperty -LiteralPath $entry.Path
        foreach ($property in $registryItem.PSObject.Properties) {
            if ($property.MemberType -ne 'NoteProperty') {
                continue
            }

            $displayName = ($property.Name -replace '\s+\((TrueType|OpenType|Type 1)\)$', '').Trim()
            $fontValue = [string] $property.Value
            if (-not $fontValue) {
                continue
            }

            $candidatePath = if ([System.IO.Path]::IsPathRooted($fontValue)) {
                $fontValue
            }
            else {
                Join-Path $entry.DefaultFolder $fontValue
            }

            [pscustomobject]@{
                DisplayName = $displayName
                RegistryName = $property.Name
                FontPath = $candidatePath
                DefaultFolder = $entry.DefaultFolder
            }
        }
    }
}

function Get-RequestedStyleFromDisplayName {
    param(
        [Parameter(Mandatory = $true)][string] $LookupName,
        [Parameter(Mandatory = $true)][string] $FamilyName
    )

    $lookup = ($LookupName -replace '\.(ttf|otf)$', '').Trim()
    $family = $FamilyName.Trim()
    if (-not $lookup -or -not $family) {
        return $null
    }

    if ($lookup.Equals($family, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $prefix = $family + ' '
    if ($lookup.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        $style = $lookup.Substring($prefix.Length).Trim()
        if ($style) {
            return $style
        }
    }

    return $null
}

function New-FontInputResolution {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo] $File,
        [string] $FamilyName,
        [string] $StyleName,
        [string] $FaceName
    )

    [pscustomobject]@{
        File = $File
        RequestedFamilyName = $FamilyName
        RequestedStyleName = $StyleName
        RequestedFaceName = $FaceName
    }
}

function Resolve-FontInputFile {
    param([Parameter(Mandatory = $true)][string] $InputPath)

    try {
        $item = Get-Item -LiteralPath $InputPath -ErrorAction Stop
        if ($item.PSIsContainer) {
            throw 'Expected exactly one font file, but a folder was provided.'
        }
        return New-FontInputResolution -File $item
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # Windows' virtual Fonts shell can pass display paths such as
        # C:\Windows\Fonts\Bahnschrift instead of the real bahnschrift.ttf file.
    }

    $lookupName = Split-Path -Leaf $InputPath
    if (-not $lookupName) {
        $lookupName = $InputPath
    }
    $lookupName = ($lookupName -replace '\.(ttf|otf)$', '').Trim()
    if (-not $lookupName) {
        throw "Font file not found: $InputPath"
    }

    $candidates = @(Get-FontRegistryCandidates | Where-Object {
            $_.DisplayName -ieq $lookupName -or
            $lookupName.StartsWith($_.DisplayName + ' ', [StringComparison]::OrdinalIgnoreCase) -or
            $_.RegistryName -like "$lookupName (*"
        })

    $existingCandidates = @($candidates | Where-Object { Test-Path -LiteralPath $_.FontPath })
    if ($existingCandidates.Count -eq 1) {
        Write-Host "Resolved Windows Fonts shell item '$InputPath' to '$($existingCandidates[0].FontPath)'."
        $styleName = Get-RequestedStyleFromDisplayName -LookupName $lookupName -FamilyName $existingCandidates[0].DisplayName
        return New-FontInputResolution `
            -File (Get-Item -LiteralPath $existingCandidates[0].FontPath -ErrorAction Stop) `
            -FamilyName $existingCandidates[0].DisplayName `
            -StyleName $styleName `
            -FaceName $lookupName
    }

    if ($existingCandidates.Count -gt 1) {
        $windowsFontsFolder = Join-Path $env:WINDIR 'Fonts'
        if ($InputPath.StartsWith($windowsFontsFolder, [StringComparison]::OrdinalIgnoreCase)) {
            $systemMatches = @($existingCandidates | Where-Object {
                    $_.FontPath.StartsWith($windowsFontsFolder, [StringComparison]::OrdinalIgnoreCase)
                })
            if ($systemMatches.Count -eq 1) {
                Write-Host "Resolved Windows Fonts shell item '$InputPath' to '$($systemMatches[0].FontPath)'."
                $styleName = Get-RequestedStyleFromDisplayName -LookupName $lookupName -FamilyName $systemMatches[0].DisplayName
                return New-FontInputResolution `
                    -File (Get-Item -LiteralPath $systemMatches[0].FontPath -ErrorAction Stop) `
                    -FamilyName $systemMatches[0].DisplayName `
                    -StyleName $styleName `
                    -FaceName $lookupName
            }
        }

        $exact = @($existingCandidates | Where-Object { $_.DisplayName -ieq $lookupName })
        if ($exact.Count -eq 1) {
            Write-Host "Resolved Windows Fonts shell item '$InputPath' to '$($exact[0].FontPath)'."
            $styleName = Get-RequestedStyleFromDisplayName -LookupName $lookupName -FamilyName $exact[0].DisplayName
            return New-FontInputResolution `
                -File (Get-Item -LiteralPath $exact[0].FontPath -ErrorAction Stop) `
                -FamilyName $exact[0].DisplayName `
                -StyleName $styleName `
                -FaceName $lookupName
        }

        $matches = ($existingCandidates | ForEach-Object { "$($_.DisplayName) -> $($_.FontPath)" }) -join [Environment]::NewLine
        throw "The Windows Fonts shell item '$InputPath' matched more than one installed font. Run the tool from the real .ttf/.otf file instead.$([Environment]::NewLine)$matches"
    }

    throw "Font file not found: $InputPath. If you launched this from C:\Windows\Fonts, try right-clicking the real .ttf/.otf file or run the command with the backing file path."
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
        $noise = @($rawOutput | Where-Object { -not $_.StartsWith($statusPrefix, [StringComparison]::Ordinal) })
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
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int AddFontResourceW(string lpFileName);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SendNotifyMessage(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, string dwItem2);
}
'@
    Add-Type -TypeDefinition $source -ErrorAction SilentlyContinue
    [FusionFontRepairNative]::AddFontResourceW($targetFontPath) | Out-Null
    [FusionFontRepairNative]::SendNotifyMessage([IntPtr] 0xffff, 0x001d, [UIntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    [FusionFontRepairNative]::SHChangeNotify(0x00002000, 0x0005, $targetFontPath, $null)
    [FusionFontRepairNative]::SHChangeNotify(0x08000000, 0x0000, $null, $null)

    return $targetFontPath
}

function Start-ElevatedSelf {
    param(
        [Parameter(Mandatory = $true)][string] $ResolvedFontPath,
        [string] $FamilyName,
        [string] $StyleName
    )

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childStatusFile = if ($StatusFile) {
        $StatusFile
    }
    else {
        $statusRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'FusionFontRepair'
        New-Item -ItemType Directory -Force -Path $statusRoot | Out-Null
        Join-Path $statusRoot ("status-{0}.json" -f [guid]::NewGuid().ToString('N'))
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $PSCommandPath,
        $ResolvedFontPath,
        '-StatusFile',
        $childStatusFile,
        '-DeferMessageToParent'
    )
    if ($OutputDirectory) {
        $arguments += @('-OutputDirectory', $OutputDirectory)
    }
    if ($FamilyName) {
        $arguments += @('-RequestedFamilyName', $FamilyName)
    }
    if ($StyleName) {
        $arguments += @('-RequestedStyleName', $StyleName)
    }
    if ($NoInstall) {
        $arguments += '-NoInstall'
    }
    if ($ShowMessage) {
        $arguments += '-ShowMessage'
    }

    $argumentString = ($arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentString -Verb RunAs -PassThru -Wait

    $status = Read-RepairStatus -Path $childStatusFile
    if ($status -and $ShowMessage) {
        $statusIcon = if ($status.icon) { [string] $status.icon } else { 'Information' }
        Show-RepairMessage -Message ([string] $status.message) -Icon $statusIcon
    }
    elseif ($ShowMessage -and $process.ExitCode -ne 0) {
        Show-RepairMessage -Message "Fusion Font Repair failed. Check the log:`n$Script:LogPath" -Icon Error
    }

    if (-not $StatusFile -and (Test-Path -LiteralPath $childStatusFile)) {
        Remove-Item -LiteralPath $childStatusFile -Force -ErrorAction SilentlyContinue
    }

    exit $process.ExitCode
}

$tempOutputDirectory = $null
$tempPreparationDirectory = $null
$generatedPath = $null

try {
    Write-RepairLog "Started. FontPath='$FontPath' NoInstall=$NoInstall OutputDirectory='$OutputDirectory' ShowMessage=$ShowMessage"
    if ([string]::IsNullOrWhiteSpace($FontPath)) {
        throw 'No font file was passed to the repair command. Try the command from a normal font file, or run Repair-FusionFont.ps1 with a .ttf/.otf path.'
    }

    $fontResolution = Resolve-FontInputFile -InputPath $FontPath
    $fontItem = $fontResolution.File
    if (-not $RequestedFamilyName -and $fontResolution.RequestedFamilyName) {
        $RequestedFamilyName = $fontResolution.RequestedFamilyName
    }
    if (-not $RequestedStyleName -and $fontResolution.RequestedStyleName) {
        $RequestedStyleName = $fontResolution.RequestedStyleName
    }

    Assert-SupportedFontFile -FontFile $fontItem
    Write-RepairLog "Resolved input to '$($fontItem.FullName)'."
    if ($RequestedFamilyName -or $RequestedStyleName) {
        Write-RepairLog "Requested face metadata. Family='$RequestedFamilyName' Style='$RequestedStyleName'."
    }

    if (-not $NoInstall -and -not (Test-IsAdministrator)) {
        Write-Host 'Administrator permission is required to install into C:\Windows\Fonts. Requesting elevation...'
        Start-ElevatedSelf -ResolvedFontPath $fontItem.FullName -FamilyName $RequestedFamilyName -StyleName $RequestedStyleName
    }

    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $workerScript = Join-Path $scriptDirectory 'fusion_font_repair.py'
    if (-not (Test-Path -LiteralPath $workerScript)) {
        throw "Missing worker script: $workerScript"
    }
    $preparerScript = Join-Path $scriptDirectory 'prepare_variable_instance.py'

    $ffPython = Resolve-FFPython
    Write-Host "Using FontForge Python: $ffPython"
    Write-Host "Reading font: $($fontItem.FullName)"

    $workerInputPath = $fontItem.FullName
    if ($RequestedStyleName) {
        if (-not (Test-Path -LiteralPath $preparerScript)) {
            throw "Missing variable-font preparer script: $preparerScript"
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'FusionFontRepair'
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        $tempPreparationDirectory = Join-Path $tempRoot ("prepare-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tempPreparationDirectory | Out-Null

        Write-Host "Preparing selected font style: $RequestedStyleName"
        $preparation = Invoke-FontForgeWorker -FFPython $ffPython -WorkerScript $preparerScript -WorkerArguments @(
            '--input', $fontItem.FullName,
            '--output-dir', $tempPreparationDirectory,
            '--style-name', $RequestedStyleName
        )
        if ($preparation.instantiated) {
            $workerInputPath = [string] $preparation.output_path
            Write-RepairLog "Prepared variable-font instance '$($preparation.matched_style)' at '$workerInputPath'."
        }
        elseif ($preparation.warning) {
            Write-RepairLog "Variable-font preparation warning: $($preparation.warning)"
        }
    }

    $workerBaseArguments = @('--input', $workerInputPath)
    if ($RequestedFamilyName) {
        $workerBaseArguments += @('--target-family', $RequestedFamilyName)
    }
    if ($RequestedStyleName) {
        $workerBaseArguments += @('--target-style', $RequestedStyleName)
    }

    $plan = Invoke-FontForgeWorker -FFPython $ffPython -WorkerScript $workerScript -WorkerArguments ($workerBaseArguments + @('--plan-only'))

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
    $result = Invoke-FontForgeWorker -FFPython $ffPython -WorkerScript $workerScript -WorkerArguments ($workerBaseArguments + @('--output-dir', $targetOutputDirectory))
    $generatedPath = $result.output_path

    if ($NoInstall) {
        $message = "Created repaired font:`n$generatedPath`n`nInternal font name:`n$($result.full_name)"
        Write-RepairLog "Success. Created '$($result.full_name)' at '$generatedPath' without installing."
        if ($tempPreparationDirectory -and (Test-Path -LiteralPath $tempPreparationDirectory)) {
            Remove-Item -LiteralPath $tempPreparationDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host $message
        Write-RepairStatus -Message $message -Icon Information -ExitCode 0
        Show-RepairMessage -Message $message -Icon Information
        exit 0
    }

    Write-Host 'Installing system-wide font...'
    $installedPath = Install-SystemFont -GeneratedFontPath $generatedPath -Plan $result

    if ($tempOutputDirectory -and (Test-Path -LiteralPath $tempOutputDirectory)) {
        Remove-Item -LiteralPath $tempOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($tempPreparationDirectory -and (Test-Path -LiteralPath $tempPreparationDirectory)) {
        Remove-Item -LiteralPath $tempPreparationDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    $message = "Installed repaired font:`n$($result.full_name)`n`nFile:`n$installedPath"
    Write-RepairLog "Success. Installed '$($result.full_name)' to '$installedPath'."
    Write-Host $message
    Write-RepairStatus -Message $message -Icon Information -ExitCode 0
    Show-RepairMessage -Message $message -Icon Information
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-RepairLog "Error: $message"
    if ($tempOutputDirectory -and (Test-Path -LiteralPath $tempOutputDirectory)) {
        Remove-Item -LiteralPath $tempOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($tempPreparationDirectory -and (Test-Path -LiteralPath $tempPreparationDirectory)) {
        Remove-Item -LiteralPath $tempPreparationDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Error $message
    Write-RepairStatus -Message $message -Icon Error -ExitCode 1
    Show-RepairMessage -Message $message -Icon Error
    exit 1
}
