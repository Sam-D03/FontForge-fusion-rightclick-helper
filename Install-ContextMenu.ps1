[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ContextMenuTargets {
    param([Parameter(Mandatory = $true)][string] $ClassesRoot)

    return @(
        @{
            Label = '.ttf normal files'
            Key = "$ClassesRoot\SystemFileAssociations\.ttf\shell\MakeFusionFont"
        },
        @{
            Label = '.otf normal files'
            Key = "$ClassesRoot\SystemFileAssociations\.otf\shell\MakeFusionFont"
        },
        @{
            Label = 'TrueType font class'
            Key = "$ClassesRoot\ttffile\shell\MakeFusionFont"
        },
        @{
            Label = 'OpenType font class'
            Key = "$ClassesRoot\otffile\shell\MakeFusionFont"
        },
        @{
            Label = 'all file types fallback for Windows Fonts shell'
            Key = "$ClassesRoot\*\shell\MakeFusionFont"
        }
    )
}

if ($Scope -eq 'AllUsers' -and -not (Test-IsAdministrator)) {
    throw 'All-users context-menu installation requires administrator permission.'
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
$repairScript = Join-Path $scriptDirectory 'Repair-FusionFont.ps1'
if (-not (Test-Path -LiteralPath $repairScript)) {
    throw "Missing repair script: $repairScript"
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$command = "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$repairScript`" `"%1`" -ShowMessage"
$classesRoot = if ($Scope -eq 'AllUsers') { 'HKLM:\Software\Classes' } else { 'HKCU:\Software\Classes' }
$targets = Get-ContextMenuTargets -ClassesRoot $classesRoot

foreach ($target in $targets) {
    $menuKey = $target.Key
    $commandKey = Join-Path $menuKey 'command'

    if ($PSCmdlet.ShouldProcess($target.Label, 'Install Make Fusion Font context menu item')) {
        New-Item -Path $menuKey -Force | Out-Null
        Set-Item -LiteralPath $menuKey -Value 'Make Fusion Font'
        New-ItemProperty -LiteralPath $menuKey -Name 'Icon' -Value "$env:SystemRoot\System32\shell32.dll,174" -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $menuKey -Name 'MultiSelectModel' -Value 'Single' -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $menuKey -Name 'NoWorkingDirectory' -Value '' -PropertyType String -Force | Out-Null

        New-Item -Path $commandKey -Force | Out-Null
        Set-Item -LiteralPath $commandKey -Value $command
    }
}

if ($WhatIfPreference) {
    Write-Host 'WhatIf complete. No context-menu registry entries were changed.'
}
else {
    Write-Host "Installed the Make Fusion Font right-click item for .ttf/.otf files, font file classes, and Windows Fonts shell fallback. Scope: $Scope."
    Write-Host 'On Windows 11 it may appear under "Show more options" depending on Explorer settings.'
}
