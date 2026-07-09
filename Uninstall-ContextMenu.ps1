[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('CurrentUser', 'AllUsers', 'Both')]
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

function Remove-ContextMenuTargets {
    param(
        [Parameter(Mandatory = $true)][string] $ClassesRoot,
        [Parameter(Mandatory = $true)][string] $ScopeLabel
    )

    $targets = Get-ContextMenuTargets -ClassesRoot $ClassesRoot
    foreach ($target in $targets) {
        $menuKey = $target.Key
        if (Test-Path -LiteralPath $menuKey) {
            if ($PSCmdlet.ShouldProcess("$ScopeLabel $($target.Label)", 'Remove Make Fusion Font context menu item')) {
                Remove-Item -LiteralPath $menuKey -Recurse -Force
            }
        }
    }
}

if (($Scope -eq 'AllUsers' -or $Scope -eq 'Both') -and -not (Test-IsAdministrator)) {
    throw 'Removing all-users context-menu entries requires administrator permission.'
}

if ($Scope -eq 'CurrentUser' -or $Scope -eq 'Both') {
    Remove-ContextMenuTargets -ClassesRoot 'HKCU:\Software\Classes' -ScopeLabel 'current-user'
}

if ($Scope -eq 'AllUsers' -or $Scope -eq 'Both') {
    Remove-ContextMenuTargets -ClassesRoot 'HKLM:\Software\Classes' -ScopeLabel 'all-users'
}

if ($WhatIfPreference) {
    Write-Host 'WhatIf complete. No context-menu registry entries were changed.'
}
else {
    Write-Host "Removed the Make Fusion Font right-click item for .ttf and .otf files. Scope: $Scope."
}
