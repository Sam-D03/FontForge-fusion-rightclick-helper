[CmdletBinding(SupportsShouldProcess = $true)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targets = @(
    @{
        Label = '.ttf normal files'
        Key = 'HKCU:\Software\Classes\SystemFileAssociations\.ttf\shell\MakeFusionFont'
    },
    @{
        Label = '.otf normal files'
        Key = 'HKCU:\Software\Classes\SystemFileAssociations\.otf\shell\MakeFusionFont'
    },
    @{
        Label = 'TrueType font class'
        Key = 'HKCU:\Software\Classes\ttffile\shell\MakeFusionFont'
    },
    @{
        Label = 'OpenType font class'
        Key = 'HKCU:\Software\Classes\otffile\shell\MakeFusionFont'
    }
)

foreach ($target in $targets) {
    $menuKey = $target.Key
    if (Test-Path -LiteralPath $menuKey) {
        if ($PSCmdlet.ShouldProcess($target.Label, 'Remove Make Fusion Font context menu item')) {
            Remove-Item -LiteralPath $menuKey -Recurse -Force
        }
    }
}

if ($WhatIfPreference) {
    Write-Host 'WhatIf complete. No context-menu registry entries were changed.'
}
else {
    Write-Host 'Removed the Make Fusion Font right-click item for .ttf and .otf files.'
}
